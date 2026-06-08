# 模型导出数据文件说明

本文档面向后续负责可视化的同学，说明 `outputs/model_results` 目录中各类导出文件的含义、字段解释和推荐使用方式。

## 文件命名规则

模型运行后，结果文件统一保存在：

```text
outputs/model_results
```

文件名格式通常为：

```text
{file_type}_{grid_size}m_{scenario_id}.csv
```

例如：

```text
routes_200m_20210512_pm_peak.csv
vehicle_actions_200m_20210512_pm_peak.csv
shortage_service_200m_20210512_pm_peak.csv
```

其中：

| 部分 | 含义 |
|---|---|
| `file_type` | 输出文件类型，例如 `routes`、`vehicle_actions` |
| `200m` | 网格粒度，由 `cfg.grid_size_m` 决定 |
| `20210512_pm_peak` | 场景编号，由 `cfg.scenario_id` 决定 |

## 推荐可视化读取顺序

建议优先读取以下文件：

1. `summary_*.csv`：判断本次求解是否成功。
2. `node_copies_*.csv`：建立访问副本和真实网格之间的映射。
3. `vehicle_actions_*.csv`：画每辆车在哪些网格装车、卸车。
4. `routes_*.csv`：画车辆行驶路线。
5. `shortage_service_*.csv`：画短缺满足情况。
6. `vehicle_time_*.csv`：画车辆工时对比。
7. `objective_parts_*.csv`：展示目标函数组成。

如果只做地图路线可视化，通常需要：

```text
routes_*.csv
vehicle_actions_*.csv
node_copies_*.csv
grid_metadata_*.csv
```

其中 `grid_metadata_*.csv` 来自 `data/processed`，用于把网格 ID 转成经纬度。

## `summary_*.csv`

求解结果摘要文件。每次运行 `main.m` 后都会生成。

示例文件：

```text
summary_200m_20210512_pm_peak.csv
```

字段说明：

| 字段 | 含义 |
|---|---|
| `status` | 求解状态 |
| `objective` | 目标函数值 |
| `proven_optimal` | 是否证明最优，`1` 表示已证明，`0` 表示未证明 |
| `nodes_explored` | 搜索或迭代节点数；启发式中通常等于模拟退火迭代次数 |
| `best_bound` | 精确求解器得到的下界；启发式结果通常为 `NaN` |
| `gap` | 最优性差距；启发式结果通常为 `NaN` |
| `runtime_seconds` | 求解运行时间，单位：秒 |

常见 `status`：

| 状态 | 含义 |
|---|---|
| `heuristic_feasible` | 启发式得到满足服务水平约束的可行解 |
| `heuristic_service_level_not_met` | 启发式得到路线，但没有满足服务水平约束 |
| `optimal` | 精确求解器证明最优 |
| `node_limit` | 达到分支节点上限 |
| `time_limit` | 达到时间上限 |
| `lp_size_limit` | LP 松弛超过保护规模 |

## `routes_*.csv`

车辆行驶路线边表。适合用于地图上画折线。

示例文件：

```text
routes_200m_20210512_pm_peak.csv
```

字段说明：

| 字段 | 含义 |
|---|---|
| `vehicle_id` | 调度车编号，例如 `truck_01` |
| `from_grid_id` | 路线边起点网格 ID，可能是 `DEPOT` |
| `to_grid_id` | 路线边终点网格 ID，可能是 `DEPOT` |
| `distance_km` | 该边行驶距离，单位：公里 |
| `travel_time_min` | 该边行驶时间，单位：分钟 |

注意：

- `routes` 是按车辆实际展开后的行驶边表。
- 若模型使用稀疏邻接图，路线可能由多个邻接边组成。
- `from_grid_id` 和 `to_grid_id` 可能是访问副本 ID，例如：

```text
200m_r029_c041__v01
```

其中 `__v01` 表示该真实网格的第 1 个访问副本。可视化时应通过 `node_copies_*.csv` 映射回原始网格。

## `vehicle_actions_*.csv`

车辆装卸动作表。适合用于地图上标注每辆车在哪里装车、在哪里卸车。

示例文件：

```text
vehicle_actions_200m_20210512_pm_peak.csv
```

字段说明：

| 字段 | 含义 |
|---|---|
| `vehicle_id` | 调度车编号 |
| `grid_id` | 发生装车或卸车动作的服务节点 ID |
| `pickup_bikes` | 在该节点装走的单车数量 |
| `dropoff_bikes` | 在该节点卸下的单车数量 |

解释：

- `pickup_bikes > 0` 表示该点是富余点服务动作。
- `dropoff_bikes > 0` 表示该点是短缺点服务动作。
- 同一辆车会按路线顺序出现多行动作。
- 如果启用了节点拆分，同一真实网格可能出现多个副本动作，例如：

```text
200m_r032_c034__v01
200m_r032_c034__v02
```

可视化时可以按 `original_grid_id` 聚合。

## `shortage_service_*.csv`

短缺满足情况表。适合用于画每个服务节点的短缺满足率、未满足量热力图。

示例文件：

```text
shortage_service_200m_20210512_pm_peak.csv
```

字段说明：

| 字段 | 含义 |
|---|---|
| `grid_id` | 服务节点 ID，可能是拆分后的副本 ID |
| `shortage_bikes` | 该节点短缺数量 |
| `unmet_bikes` | 该节点未满足短缺数量 |
| `served_bikes` | 该节点已满足短缺数量 |
| `surplus_bikes` | 该节点富余数量 |

常用可视化指标：

```text
满足率 = served_bikes / shortage_bikes
未满足率 = unmet_bikes / shortage_bikes
```

计算时注意 `shortage_bikes = 0` 的节点不要直接做除法。

如果需要回到真实网格级别，应与 `node_copies_*.csv` 关联后按 `original_grid_id` 聚合：

```text
真实网格总短缺 = sum(shortage_bikes)
真实网格总未满足 = sum(unmet_bikes)
真实网格总满足 = sum(served_bikes)
```

## `vehicle_time_*.csv`

每辆车的路线服务时间表。

示例文件：

```text
vehicle_time_200m_20210512_pm_peak.csv
```

字段说明：

| 字段 | 含义 |
|---|---|
| `vehicle_id` | 调度车编号 |
| `route_time_min` | 该车总服务时间，单位：分钟 |

该表适合画柱状图，用来检查车辆工作量是否均衡。

## `objective_parts_*.csv`

目标函数分解表。用于展示模型目标值由哪些部分组成。

示例文件：

```text
objective_parts_200m_20210512_pm_peak.csv
```

字段说明：

| 字段 | 含义 |
|---|---|
| `makespan_min` | 最大车辆完成时间，即所有车辆中最长路线时间 |
| `total_vehicle_time_min` | 所有车辆服务时间总和 |
| `total_unmet_bikes` | 总未满足短缺数量 |
| `total_served_bikes` | 总满足短缺数量，启发式输出中包含 |
| `service_shortfall_bikes` | 距离最低服务水平还差多少辆，启发式输出中包含 |

目标函数主要由三类项构成：

```text
目标 = alpha * makespan
     + gamma * total_vehicle_time
     + beta * total_unmet_bikes
     + 服务水平不足惩罚（启发式中可能出现）
```

## `node_copies_*.csv`

节点拆分映射表。这个文件对可视化非常重要。

示例文件：

```text
node_copies_200m_20210512_pm_peak.csv
```

字段说明：

| 字段 | 含义 |
|---|---|
| `grid_id` | 模型内部使用的服务节点 ID，可能是访问副本 |
| `original_grid_id` | 原始真实网格 ID |
| `visit_copy_index` | 当前副本编号 |
| `visit_copy_count` | 该真实网格一共被拆成多少个副本 |
| `shortage_bikes` | 该副本分到的短缺数量 |
| `surplus_bikes` | 该副本分到的富余数量 |

为什么需要这个文件：

当前模型允许大短缺/大富余网格被拆成多个访问副本，使同一真实网格可以在一辆车路线中多次出现。

例如：

```text
200m_r032_c034__v01
200m_r032_c034__v02
```

现实中都对应：

```text
200m_r032_c034
```

可视化建议：

- 画车辆路线时，可以使用副本 ID 保持动作顺序。
- 画地图点位时，应使用 `original_grid_id` 查经纬度。
- 画真实网格汇总热力图时，应按 `original_grid_id` 聚合。

## `solution_*.mat`

MATLAB 原始结果文件，包含完整的 `cfg`、`mdl` 和 `sol` 结构体。

示例文件：

```text
solution_200m_20210512_pm_peak.mat
```

字段大致包括：

| 结构体 | 含义 |
|---|---|
| `cfg` | 本次运行使用的参数 |
| `mdl` | 数学模型矩阵、变量索引、数据 |
| `sol` | 求解结果和解码后的表格 |

可视化同学通常不需要读取 `.mat` 文件，除非需要更底层的模型信息，例如：

```text
mdl.data.nodes
mdl.data.edges
mdl.data.dist_km
sol.decoded
```

## `branch_cut_compare_*.csv`

Branch-and-Cut 精确验证对比表。只有启用精确验证时才会生成。

示例文件：

```text
branch_cut_compare_1000m_20210512_pm_peak.csv
```

字段说明：

| 字段 | 含义 |
|---|---|
| `status` | Branch-and-Cut 验证状态 |
| `proven_optimal` | 是否证明验证模型中的最优性 |
| `heuristic_objective` | 启发式目标值 |
| `exact_objective` | 精确验证目标值 |
| `gap_percent` | 启发式与精确验证目标之间的百分比差距 |
| `cut_count` | 添加的子回路割数量 |
| `cut_rounds` | Branch-and-Cut 迭代轮数 |
| `runtime_seconds` | 验证运行时间 |
| `last_solver_status` | 内部 MILP 求解器最后状态 |
| `last_nodes_explored` | 内部求解器最后搜索节点数 |
| `last_best_bound` | 内部求解器最后下界 |
| `last_solver_gap` | 内部求解器 gap |

注意：

`last_solver_status = no_integer_solution` 并不一定表示原问题无解。若外层状态为：

```text
heuristic_proven_optimal_for_validation
```

则含义是：加入“寻找比启发式更优解”的目标割后，内部求解器找不到更优整数解，因此当前启发式解已在验证模型中被证明最优。

## 与 `data/processed` 的关联

可视化通常还需要读取原始网格元数据：

```text
data/processed/grid_metadata_1000m.csv
data/processed/grid_metadata_500m.csv
data/processed/grid_metadata_200m.csv
data/processed/grid_metadata_100m.csv
```

常用字段：

| 字段 | 含义 |
|---|---|
| `grid_id` | 原始真实网格 ID |
| `row` | 网格行号 |
| `col` | 网格列号 |
| `center_lng` | 网格中心经度 |
| `center_lat` | 网格中心纬度 |
| `grid_size_m` | 网格粒度 |

关联方式：

1. 对 `routes`、`vehicle_actions`、`shortage_service` 中的 `grid_id`，先通过 `node_copies` 得到 `original_grid_id`。
2. 用 `original_grid_id` 连接 `grid_metadata_*.csv` 的 `grid_id`。
3. 使用 `center_lng`、`center_lat` 在地图上画点或线。

## 可视化建议

### 车辆路线图

使用：

```text
routes_*.csv
node_copies_*.csv
grid_metadata_*.csv
```

流程：

1. 把 `from_grid_id` 和 `to_grid_id` 映射到 `original_grid_id`。
2. 用 `grid_metadata` 查经纬度。
3. 按 `vehicle_id` 分组画线。
4. `DEPOT` 需要单独处理，可以从车辆参数文件或 `solution_*.mat` 中读取调度中心经纬度。

### 装卸动作图

使用：

```text
vehicle_actions_*.csv
node_copies_*.csv
grid_metadata_*.csv
```

建议：

- 装车点用一种颜色。
- 卸车点用另一种颜色。
- 点大小按 `pickup_bikes` 或 `dropoff_bikes` 缩放。

### 短缺满足热力图

使用：

```text
shortage_service_*.csv
node_copies_*.csv
grid_metadata_*.csv
```

建议先聚合到真实网格：

```text
group by original_grid_id
sum shortage_bikes, unmet_bikes, served_bikes, surplus_bikes
```

然后画：

```text
served_bikes
unmet_bikes
unmet_bikes / shortage_bikes
```

