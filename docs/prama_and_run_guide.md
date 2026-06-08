# 参数配置与模型运行说明

本文档面向后续负责运行模型和做可视化的同学，说明 `src/model/prama.m` 中主要参数如何配置，以及如何运行模型生成 `outputs/model_results` 中的结果文件。

## 运行入口

模型主入口是：

```text
src/model/main.m
```

运行方式：

1. 打开 MATLAB。
2. 将当前目录切换到项目根目录：

```matlab
cd("C:\Users\lsy\Desktop\运筹学\大作业\shenzhen-bike-rebalancing")
```

3. 运行：

```matlab
addpath("src/model")
main
```

如果你刚修改过函数文件，建议先清理 MATLAB 函数缓存：

```matlab
clear solve solve_heuristic solve_branch_cut model prama main
addpath("src/model")
main
```

运行完成后，结果会保存到：

```text
outputs/model_results
```

## 配置文件位置

所有主要参数集中在：

```text
src/model/prama.m
```

该文件返回一个结构体：

```matlab
cfg = prama();
```

`main.m` 会读取 `cfg`，再调用：

```matlab
mdl = model(cfg);
sol = solve_heuristic(mdl, cfg);  % 或 solve(mdl, cfg)
```

## 数据开关

### `cfg.grid_size_m`

控制使用哪一种网格粒度。

可选值：

```matlab
cfg.grid_size_m = 1000;
cfg.grid_size_m = 500;
cfg.grid_size_m = 200;
cfg.grid_size_m = 100;
```

模型会自动读取：

```text
scenario_grid_demand_1km.parquet
scenario_grid_demand_500m.parquet
scenario_grid_demand_200m.parquet
scenario_grid_demand_100m.parquet
```

以及对应的：

```text
grid_metadata_*.csv
```

注意：

- 网格越细，节点越多，运行越慢。
- 100m 数据规模较大，建议先降低 `cfg.max_service_nodes`。

### `cfg.scenario_id`

控制使用哪一个需求场景。

示例：

```matlab
cfg.scenario_id = "20210512_pm_peak";
```

该值必须存在于 `scenario_grid_demand_*.parquet` 的 `scenario_id` 字段中。

### `cfg.data_dir`

处理后数据目录。

默认：

```matlab
cfg.data_dir = fullfile(projectRoot(), "data", "processed");
```

通常不需要修改。

### `cfg.output_dir`

模型结果输出目录。

默认：

```matlab
cfg.output_dir = fullfile(projectRoot(), "outputs", "model_results");
```

可视化同学主要读取这个目录中的 CSV 文件。

### `cfg.use_processed_distance_matrix`

是否使用 `distance_matrix_*.parquet` 覆盖服务网格之间的距离。

默认：

```matlab
cfg.use_processed_distance_matrix = false;
```

建议保持关闭，原因：

- 100m 的 `distance_matrix_100m.parquet` 很大。
- 当前模型只需要被选中服务节点之间的距离，直接用经纬度近似更快。

如果确实希望使用预处理距离矩阵：

```matlab
cfg.use_processed_distance_matrix = true;
```

### `cfg.load_od_flow`

是否将 `od_flow_grid_*.parquet` 读入 `mdl.data.od_flow`。

默认：

```matlab
cfg.load_od_flow = false;
```

当前优化模型不依赖 OD 流量表，因此一般不需要打开。若可视化或分析需要查看 OD 流，可单独读取数据文件，或打开此开关。

### `cfg.load_raw_distance_matrix`

是否将全量距离矩阵读入 `mdl.data.raw_distance_matrix`。

默认：

```matlab
cfg.load_raw_distance_matrix = false;
```

不建议在 100m 下打开，文件很大，可能导致读入时间和内存占用明显增加。

## 节点筛选与节点拆分

### `cfg.max_service_nodes`

最多保留多少个服务节点参与优化。

示例：

```matlab
cfg.max_service_nodes = 1200;
```

含义：

- 原始网格很多时，只保留短缺或富余较大的节点。
- 该值越大，模型越细，但运行越慢。

建议：

| 网格粒度 | 建议范围 |
|---|---|
| 1000m | 50 到 150 |
| 500m | 100 到 400 |
| 200m | 300 到 1200 |
| 100m | 300 到 1500，需谨慎 |

如果只做快速测试，可以先设小一点：

```matlab
cfg.max_service_nodes = 50;
```

### `cfg.min_shortage_to_keep`

短缺量低于该值的节点不参与优化。

```matlab
cfg.min_shortage_to_keep = 3;
```

### `cfg.min_surplus_to_keep`

富余量低于该值的节点不参与优化。

```matlab
cfg.min_surplus_to_keep = 3;
```

### `cfg.balance_shortage_surplus_nodes`

是否在筛选节点时尽量同时保留短缺点和富余点。

```matlab
cfg.balance_shortage_surplus_nodes = true;
```

建议保持开启，否则可能筛出大量短缺点但富余点不足，导致调度效果不好。

### `cfg.split_large_service_nodes`

是否启用节点拆分。

```matlab
cfg.split_large_service_nodes = true;
```

节点拆分的作用：

- 允许同一个真实网格在一辆车路线中被多次访问。
- 例如现实路线：

```text
depot -> A -> B -> A -> C -> depot
```

在模型中表示为：

```text
depot -> A__v01 -> B__v01 -> A__v02 -> C__v01 -> depot
```

### `cfg.node_split_threshold_bikes`

节点拆分阈值。

```matlab
cfg.node_split_threshold_bikes = NaN;
```

`NaN` 表示使用调度车最小运载量作为阈值。若某个网格：

```text
max(shortage, surplus) > 最小车辆容量
```

则拆分。

也可以手动指定，例如：

```matlab
cfg.node_split_threshold_bikes = 30;
```

### `cfg.node_split_unit_bikes`

每个副本分配的目标单车量。

```matlab
cfg.node_split_unit_bikes = NaN;
```

`NaN` 表示使用调度车最小运载量。

### `cfg.node_split_max_copies`

每个真实网格最多拆分成多少个副本。

```matlab
cfg.node_split_max_copies = inf;
```

如果 100m 下节点过多，可以限制：

```matlab
cfg.node_split_max_copies = 3;
```

这样可以控制模型规模。

## 稀疏邻接图参数

### `cfg.use_sparse_adjacency`

是否使用稀疏邻接图。

```matlab
cfg.use_sparse_adjacency = true;
```

建议保持开启。若关闭，会接近全联通图，边数大幅增加。

### `cfg.edge_radius_km`

邻接半径。默认和网格粒度相关：

```matlab
cfg.edge_radius_km = 1.6 * cfg.grid_size_m / 1000;
```

含义：

- 距离不超过该半径的节点默认连边。
- 200m 下默认约 `0.32 km`。
- 100m 下默认约 `0.16 km`。

如果稀疏图过碎，可以适当增大：

```matlab
cfg.edge_radius_km = 2.0 * cfg.grid_size_m / 1000;
```

### `cfg.edge_nearest_neighbors`

每个服务节点至少连接多少个最近邻。

```matlab
cfg.edge_nearest_neighbors = 6;
```

如果路线不连通或绕路严重，可以提高到：

```matlab
cfg.edge_nearest_neighbors = 8;
```

### `cfg.depot_nearest_neighbors`

调度中心至少连接多少个最近服务节点。

```matlab
cfg.depot_nearest_neighbors = 8;
```

如果车辆无法从调度中心到达足够多节点，可以提高。

### `cfg.ensure_undirected_edges`

是否保证边双向存在。

```matlab
cfg.ensure_undirected_edges = true;
```

建议保持开启，便于车辆往返。

## 调度车参数

### `cfg.vehicle_param_file`

车辆参数表。

```matlab
cfg.vehicle_param_file = fullfile(cfg.data_dir, "dispatch_vehicle_params_1km.csv");
```

虽然文件名含 `1km`，但其中是车辆参数，不是网格数据。当前 500m、200m、100m 也复用这张车辆表。

### `cfg.use_available_vehicles_only`

是否只使用车辆表中 `available = 1` 的车辆。

```matlab
cfg.use_available_vehicles_only = true;
```

### `cfg.max_vehicles_to_use`

使用多少辆调度车。

```matlab
cfg.max_vehicles_to_use = 20;
```

如果设置数量超过车辆参数表中可用车辆数，代码会循环复制已有车辆模板，并自动生成：

```text
truck_01
truck_02
...
```

### `cfg.force_all_vehicles_used`

是否强制所有车都出车。

```matlab
cfg.force_all_vehicles_used = false;
```

建议保持 `false`。否则在需求较少时，模型可能为了让所有车出车产生不必要路线。

### `cfg.return_to_depot`

车辆是否必须返回调度中心。

```matlab
cfg.return_to_depot = true;
```

若实际运营允许开放路径，可以改为 `false`，但当前模型主要按闭合路线设计。

## 服务时间参数

### `cfg.use_vehicle_specific_service_time`

是否优先使用车辆表中的服务时间参数。

```matlab
cfg.use_vehicle_specific_service_time = true;
```

### `cfg.default_load_time_min_per_bike`

默认装载一辆单车耗时，单位：分钟/辆。

```matlab
cfg.default_load_time_min_per_bike = 0.60;
```

### `cfg.default_unload_time_min_per_bike`

默认卸载一辆单车耗时，单位：分钟/辆。

```matlab
cfg.default_unload_time_min_per_bike = 0.45;
```

### `cfg.default_fixed_stop_time_min`

每访问一个服务网格的固定停靠、找车、操作时间，单位：分钟。

```matlab
cfg.default_fixed_stop_time_min = 4.0;
```

### `cfg.default_max_route_time_min`

单辆车最大路线工作时间，单位：分钟。

```matlab
cfg.default_max_route_time_min = 360.0;
```

如果很多车辆路线被判不可行，可以适当增大；如果要模拟更严格班次，可以减小。

## 目标函数权重

模型目标大致为：

```text
alpha * 最大完成时间
+ gamma * 所有车辆总服务时间
+ beta * 未满足短缺数量
```

### `cfg.alpha_makespan`

最大完成时间权重。

```matlab
cfg.alpha_makespan = 1.0;
```

提高该值会更重视尽快完成全部调度。

### `cfg.gamma_total_time`

车辆总服务时间权重。

```matlab
cfg.gamma_total_time = 0.08;
```

提高该值会减少总绕路和总运营时间。

### `cfg.beta_unmet_shortage`

每辆未满足短缺单车的惩罚。

```matlab
cfg.beta_unmet_shortage = 25.0;
```

提高该值会更积极补短缺，但可能增加路线时间。

### `cfg.priority_shortage_multiplier`

短缺惩罚倍数。

```matlab
cfg.priority_shortage_multiplier = 1.0;
```

当前所有区域使用统一倍数。后续如果要按区域重要性加权，可以扩展为每个网格不同的 `beta`。

## 模型选项

### `cfg.integer_bike_quantities`

装车量、卸车量、未满足短缺量是否必须为整数。

```matlab
cfg.integer_bike_quantities = true;
```

建议保持开启。

### `cfg.big_m_load`

保留参数。

当前载重约束默认使用动态 Big-M：

```text
M_k = 2Q_k + max(s) + max(r)
```

因此一般不需要修改 `cfg.big_m_load`。

### `cfg.service_level_required`

最低服务水平。

```matlab
cfg.service_level_required = 0.85;
```

含义：

```text
满足短缺量 >= 0.85 * min(总短缺, 总富余)
```

如果启发式经常出现：

```text
heuristic_service_level_not_met
```

可以考虑：

```matlab
cfg.service_level_required = 0.75;
```

或增加车辆数、路线时间、候选任务数。

### `cfg.include_service_level_constraint`

是否加入最低服务水平约束。

```matlab
cfg.include_service_level_constraint = true;
```

建议保持开启，保证结果不会只追求少量便宜调度。

### `cfg.use_mtz_subtour_elimination`

是否使用 MTZ 子回路消除约束。

```matlab
cfg.use_mtz_subtour_elimination = true;
```

如果使用启发式主求解器，该参数对启发式路线影响较小；如果使用 MILP 精确求解器，则建议开启。

## 求解器选择

### `cfg.solver.method`

选择主求解器。

```matlab
cfg.solver.method = "heuristic";
```

可选：

| 值 | 含义 |
|---|---|
| `"heuristic"` | 贪心插入 + 局部搜索 + 模拟退火，推荐大规模使用 |
| `"milp"` | 自写 MILP 分支定界求解器，仅适合很小规模 |

建议：

- 1000m、500m、200m、100m 主实验都使用 `"heuristic"`。
- `"milp"` 只用于小规模测试。

### `cfg.solver.display`

是否打印求解过程。

```matlab
cfg.solver.display = true;
```

如果觉得输出太多，可以改为：

```matlab
cfg.solver.display = false;
```

### `cfg.solver.max_seconds`

精确求解器最大运行时间，单位：秒。

```matlab
cfg.solver.max_seconds = 3600;
```

启发式主要由 `cfg.heuristic.sa_iterations` 控制，通常不会用满该时间。

### `cfg.solver.max_branch_nodes`

精确求解器最大分支节点数。

```matlab
cfg.solver.max_branch_nodes = 5000;
```

如果状态为 `node_limit`，表示达到了该上限。

## 启发式求解器参数

### `cfg.heuristic.random_seed`

随机种子。

```matlab
cfg.heuristic.random_seed = 20240607;
```

保持不变可以复现实验结果。

### `cfg.heuristic.max_greedy_tasks`

贪心阶段最多生成多少个调度任务。

```matlab
cfg.heuristic.max_greedy_tasks = 300;
```

如果短缺满足不够，可以增大：

```matlab
cfg.heuristic.max_greedy_tasks = 500;
```

### `cfg.heuristic.sa_iterations`

模拟退火迭代次数。

```matlab
cfg.heuristic.sa_iterations = 6000;
```

越大搜索越充分，但耗时越长。

### `cfg.heuristic.neighbor_sample_limit`

贪心阶段每轮最多评估多少个候选动作。

```matlab
cfg.heuristic.neighbor_sample_limit = 100000;
```

200m、100m 下候选组合多，建议保持较大。若运行太慢，可以降低。

### 其他退火参数

```matlab
cfg.heuristic.initial_temperature = 80;
cfg.heuristic.cooling_rate = 0.996;
cfg.heuristic.min_temperature = 1.0e-4;
cfg.heuristic.progress_interval = 500;
```

一般不需要修改。

## Branch-and-Cut 精确验证参数

### `cfg.exact_validation.enabled`

是否在 `main` 结尾运行 Branch-and-Cut 精确验证。

```matlab
cfg.exact_validation.enabled = false;
```

建议大规模运行时保持关闭。

### `cfg.exact_validation.same_as_main_model`

是否直接验证主模型。

```matlab
cfg.exact_validation.same_as_main_model = true;
```

如果主模型很大，不建议打开精确验证。

### 小规模验证建议

若需要做小规模精确验证，建议：

```matlab
cfg.exact_validation.enabled = true;
cfg.exact_validation.same_as_main_model = false;
cfg.exact_validation.max_service_nodes = 8;
cfg.exact_validation.max_vehicles_to_use = 3;
cfg.exact_validation.max_seconds = 120;
cfg.exact_validation.max_branch_nodes = 100;
```

精确验证只是用来比较启发式质量，不建议用于 200m/100m 完整规模。

## 常用配置模板

### 快速测试模板

适合检查代码是否能跑通。

```matlab
cfg.grid_size_m = 1000;
cfg.max_service_nodes = 30;
cfg.max_vehicles_to_use = 3;
cfg.heuristic.sa_iterations = 200;
cfg.heuristic.max_greedy_tasks = 50;
cfg.exact_validation.enabled = false;
```

### 1000m 正式运行模板

```matlab
cfg.grid_size_m = 1000;
cfg.max_service_nodes = 120;
cfg.max_vehicles_to_use = 8;
cfg.solver.method = "heuristic";
cfg.heuristic.sa_iterations = 6000;
cfg.exact_validation.enabled = false;
```

### 200m 运行模板

```matlab
cfg.grid_size_m = 200;
cfg.max_service_nodes = 1200;
cfg.max_vehicles_to_use = 20;
cfg.solver.method = "heuristic";
cfg.heuristic.sa_iterations = 6000;
cfg.heuristic.neighbor_sample_limit = 100000;
cfg.exact_validation.enabled = false;
```

### 100m 谨慎运行模板

100m 数据规模大，建议先用较小节点数试跑。

```matlab
cfg.grid_size_m = 100;
cfg.max_service_nodes = 500;
cfg.max_vehicles_to_use = 20;
cfg.solver.method = "heuristic";
cfg.heuristic.max_greedy_tasks = 300;
cfg.heuristic.sa_iterations = 4000;
cfg.heuristic.neighbor_sample_limit = 80000;
cfg.node_split_max_copies = 3;
cfg.exact_validation.enabled = false;
```

## 如何判断结果能不能用于可视化

运行结束后先看：

```text
summary_*.csv
```

如果：

```text
status = heuristic_feasible
```

说明启发式找到满足服务水平约束的可行解，可以直接用于可视化。

如果：

```text
status = heuristic_service_level_not_met
```

说明有路线结果，但没有达到最低服务水平。仍可以可视化，但需要在图或报告中说明“服务水平未满足”。

可以进一步查看：

```text
objective_parts_*.csv
```

重点字段：

```text
total_unmet_bikes
total_served_bikes
service_shortfall_bikes
```

## 输出文件

每次成功运行后，通常生成：

```text
summary_*.csv
routes_*.csv
vehicle_actions_*.csv
shortage_service_*.csv
vehicle_time_*.csv
objective_parts_*.csv
node_copies_*.csv
solution_*.mat
```

如果开启精确验证，还会生成：

```text
branch_cut_compare_*.csv
```

详细字段含义见：

```text
docs/output_data_guide.md
```

## 常见问题

### 运行很慢怎么办？

优先调整：

```matlab
cfg.max_service_nodes
cfg.heuristic.sa_iterations
cfg.heuristic.neighbor_sample_limit
cfg.node_split_max_copies
```

建议先降低 `max_service_nodes`，确认流程跑通后再逐步放大。

### 服务水平不满足怎么办？

可以尝试：

```matlab
cfg.max_vehicles_to_use = 更大值;
cfg.default_max_route_time_min = 更大值;
cfg.heuristic.max_greedy_tasks = 更大值;
cfg.service_level_required = 稍低值;
```

### 100m 文件很大怎么办？

保持：

```matlab
cfg.use_processed_distance_matrix = false;
cfg.load_raw_distance_matrix = false;
```

并控制：

```matlab
cfg.max_service_nodes
cfg.node_split_max_copies
```

### 可视化中出现 `__v01` 是什么？

这是节点拆分后的访问副本 ID。

例如：

```text
200m_r032_c034__v01
```

真实网格是：

```text
200m_r032_c034
```

请使用：

```text
node_copies_*.csv
```

映射到 `original_grid_id` 后再查经纬度。

