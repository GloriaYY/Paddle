/* Copyright (c) 2016 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include "paddle/fluid/operators/lookup_table_op.h"
#include "paddle/fluid/framework/op_registry.h"
#include "paddle/phi/backends/gpu/gpu_primitives.h"
#include "paddle/phi/common/float16.h"
#include "paddle/phi/common/memory_utils.h"
#include "paddle/phi/kernels/funcs/eigen/common.h"

namespace paddle {
namespace operators {

template <typename T,
          int BlockDimX,
          int BlockDimY,
          int GridDimX,
          bool PaddingFlag>
__global__ void LookupTable(T *output,
                            const T *table,
                            const int64_t *ids,
                            const int64_t N,
                            const int64_t K,
                            const int64_t D,
                            const int64_t padding_idx) {
  int idx = threadIdx.x;
  int idy = blockIdx.x + threadIdx.y * GridDimX;

  while (idy < K) {
    int64_t id = ids[idy];
    PADDLE_ENFORCE(
        id >= 0,
        "Variable value (input) of OP(fluid.layers.embedding) "
        "expected >= 0 and < %ld, but got %ld. Please check input value.",
        N,
        id);
    PADDLE_ENFORCE(
        id < N,
        "Variable value (input) of OP(fluid.layers.embedding) "
        "expected >= 0 and < %ld, but got %ld. Please check input value.",
        N,
        id);
    T *out = output + idy * D;
    const T *tab = table + id * D;
    for (int i = idx; i < D; i += BlockDimX) {
      if (PaddingFlag) {
        if (id == padding_idx)
          out[i] = static_cast<T>(0);
        else
          out[i] = tab[i];
      } else {
        out[i] = tab[i];
      }
    }
    idy += BlockDimY * GridDimX;
  }
}

template <typename T, int BlockDimX, int BlockDimY, int GridDimX>
__global__ void LookupTableGrad(T *table,
                                const T *output,
                                const int64_t *ids,
                                const int64_t N,
                                const int64_t K,
                                const int64_t D) {
  int idx = threadIdx.x;
  int idy = blockIdx.x + threadIdx.y * GridDimX;

  while (idy < K) {
    int64_t id = ids[idy];
    PADDLE_ENFORCE(
        id >= 0,
        "Variable value (input) of OP(fluid.layers.embedding) "
        "expected >= 0 and < %ld, but got %ld. Please check input value.",
        N,
        id);
    PADDLE_ENFORCE(
        id < N,
        "Variable value (input) of OP(fluid.layers.embedding) "
        "expected >= 0 and < %ld, but got %ld. Please check input value.",
        N,
        id);
    const T *out = output + idy * D;
    T *tab = table + id * D;
    for (int i = idx; i < D; i += BlockDimX) {
      phi::CudaAtomicAdd(&tab[i], out[i]);
    }
    idy += BlockDimY * GridDimX;
  }
}

template <typename T>
class LookupTableCUDAKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &context) const override {
    auto *table_t = context.Input<phi::DenseTensor>("W");
    auto *ids_t = context.Input<phi::DenseTensor>("Ids");
    auto *output_t = context.Output<phi::DenseTensor>("Out");
    int64_t padding_idx = context.Attr<int64_t>("padding_idx");

    auto id_name = context.InputNames("Ids").front();
    auto out_name = context.OutputNames("Out").front();

    size_t N = table_t->dims()[0];
    size_t D = table_t->dims()[1];
    size_t K = ids_t->numel();

    auto *ids = ids_t->data<int64_t>();
    auto *table = table_t->data<T>();
    auto *output = output_t->mutable_data<T>(context.GetPlace());

#ifdef PADDLE_WITH_HIP
    dim3 threads(64, 4);
#else
    dim3 threads(128, 8);
#endif  // PADDLE_WITH_HIP
    dim3 grids(8, 1);
#ifdef PADDLE_WITH_HIP
    if (padding_idx == -1)
      LookupTable<T, 64, 4, 8, false>
          <<<grids, threads, 0, context.cuda_device_context().stream()>>>(
              output, table, ids, N, K, D, padding_idx);
    else
      LookupTable<T, 64, 4, 8, true>
          <<<grids, threads, 0, context.cuda_device_context().stream()>>>(
              output, table, ids, N, K, D, padding_idx);
#else
    if (padding_idx == -1)
      LookupTable<T, 128, 8, 8, false>
          <<<grids, threads, 0, context.cuda_device_context().stream()>>>(
              output, table, ids, N, K, D, padding_idx);
    else
      LookupTable<T, 128, 8, 8, true>
          <<<grids, threads, 0, context.cuda_device_context().stream()>>>(
              output, table, ids, N, K, D, padding_idx);
#endif  // PADDLE_WITH_HIP
  }
};

template <typename T>
class LookupTableGradCUDAKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &context) const override {
    auto &dev_ctx = context.template device_context<phi::GPUContext>();
    bool is_sparse = context.Attr<bool>("is_sparse");

    // Since paddings are not trainable and fixed in forward, the gradient of
    // paddings makes no sense and we don't deal with it in backward.
    if (is_sparse) {
      auto *ids = context.Input<phi::DenseTensor>("Ids");
      auto *table = context.Input<phi::DenseTensor>("W");
      auto *d_output =
          context.Input<phi::DenseTensor>(framework::GradVarName("Out"));
      auto *d_table =
          context.Output<phi::SelectedRows>(framework::GradVarName("W"));

      auto *ids_data = ids->data<int64_t>();
      int64_t ids_num = ids->numel();

      auto stream = dev_ctx.stream();
      // copy GPU memory to CPU pinned memory
      phi::Vector<int64_t> new_rows;
      new_rows.resize(ids_num);
      auto gpu_place = context.GetPlace();

      // TODO(yuyang18): Strange code here.
      phi::MixVector<int64_t> mixv_new_rows(&new_rows);
      phi::memory_utils::Copy(gpu_place,
                              mixv_new_rows.CUDAMutableData(context.GetPlace()),
                              gpu_place,
                              ids_data,
                              ids_num * sizeof(int64_t),
                              stream);
      mixv_new_rows.CopyToCPU();
      d_table->set_rows(new_rows);

      auto *d_table_value = d_table->mutable_value();
      d_table_value->Resize({ids_num, table->dims()[1]});
      d_table_value->mutable_data<T>(context.GetPlace());

      auto *d_table_data = d_table_value->data<T>();
      auto *d_output_data = d_output->data<T>();
      auto d_output_dims = d_output->dims();
      auto d_output_dims_2d =
          common::flatten_to_2d(d_output_dims, d_output_dims.size() - 1);
      PADDLE_ENFORCE_EQ(d_table_value->dims(),
                        d_output_dims_2d,
                        phi::errors::InvalidArgument(
                            "ShapeError: The shape of lookup_table@Grad and "
                            "output@Grad should be same. "
                            "But received lookup_table@Grad's shape = [%s], "
                            "output@Grad's shape = [%s].",
                            d_table_value->dims(),
                            d_output_dims_2d));
      phi::memory_utils::Copy(gpu_place,
                              d_table_data,
                              gpu_place,
                              d_output_data,
                              d_output->numel() * sizeof(T),
                              stream);

    } else {
      auto ids_t = context.Input<phi::DenseTensor>("Ids");
      auto d_output_t =
          context.Input<phi::DenseTensor>(framework::GradVarName("Out"));
      auto d_table_t =
          context.Output<phi::DenseTensor>(framework::GradVarName("W"));

      int N = d_table_t->dims()[0];
      int D = d_table_t->dims()[1];
      int K = ids_t->numel();
      const int64_t *ids = ids_t->data<int64_t>();
      const T *d_output = d_output_t->data<T>();
      T *d_table = d_table_t->mutable_data<T>(context.GetPlace());

      auto t = phi::EigenVector<T>::Flatten(*d_table_t);
      t.device(*dev_ctx.eigen_device()) = t.constant(static_cast<T>(0));

#ifdef PADDLE_WITH_HIP
      dim3 threads(64, 4);
#else
      dim3 threads(128, 8);
#endif  // PADDLE_WITH_HIP
      dim3 grids(8, 1);

#ifdef PADDLE_WITH_HIP
      LookupTableGrad<T, 64, 4, 8><<<grids, threads, 0, dev_ctx.stream()>>>(
          d_table, d_output, ids, N, K, D);
#else
      LookupTableGrad<T, 128, 8, 8><<<grids, threads, 0, dev_ctx.stream()>>>(
          d_table, d_output, ids, N, K, D);
#endif  // PADDLE_WITH_HIP
    }
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
namespace plat = paddle::platform;
REGISTER_OP_CUDA_KERNEL(lookup_table,
                        ops::LookupTableCUDAKernel<float>,
                        ops::LookupTableCUDAKernel<double>,
                        ops::LookupTableCUDAKernel<phi::dtype::float16>,
                        ops::LookupTableCUDAKernel<int8_t>,
                        ops::LookupTableCUDAKernel<int16_t>);
REGISTER_OP_CUDA_KERNEL(lookup_table_grad,
                        ops::LookupTableGradCUDAKernel<float>,
                        ops::LookupTableGradCUDAKernel<double>,
                        ops::LookupTableGradCUDAKernel<phi::dtype::float16>);
