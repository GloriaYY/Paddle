// Copyright (c) 2024 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once

#include <optional>

#include "paddle/cinn/adt/adt.h"
#include "paddle/cinn/frontend/cluster_ops/common_utils.h"
#include "paddle/cinn/frontend/cluster_ops/shardable_axes_utils.h"

namespace cinn::frontend::cluster_ops {

class ShardableAxesProvider {
 public:
  ~ShardableAxesProvider() = default;

  virtual ShardableAxesSignature MakeShardableAxesSignature4Op(
      const pir::Operation* op) = 0;

 protected:
  ShardableAxesProvider() = default;
};

std::shared_ptr<ShardableAxesProvider> MakeDefaultShardableAxesProvider(
    const pir::ShapeConstraintIRAnalysis* shape_analysis);

int GetOutputShardableAxesResultIdx(const pir::Operation* op);

}  // namespace cinn::frontend::cluster_ops
