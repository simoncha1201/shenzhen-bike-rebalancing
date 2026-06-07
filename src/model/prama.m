function cfg = prama()
%PRAMA 共享单车再平衡 MILP 模型与求解器参数。
%
% 本文件集中存放所有可调整参数。文件名沿用项目中已有的 prama.m，
% 实际作用等同于参数配置模块。

cfg = struct();

%% 数据开关
cfg.grid_size_m = 1000;                  % 网格粒度主开关：1000、500、200 或 100 米。
cfg.available_grid_sizes = [1000 500 200 100]; % 预留的网格粒度选项，后续有数据即可切换。
cfg.scenario_id = "20210512_pm_peak";   % 需要优化的场景编号，必须存在于 scenario_grid_demand_* 文件中。
cfg.data_dir = fullfile(projectRoot(), "data", "processed"); % 处理后数据所在目录。
cfg.output_dir = fullfile(projectRoot(), "outputs", "model_results"); % 求解结果输出目录，供可视化继续使用。

%% 节点筛选
cfg.max_service_nodes = 1200;              % 精确 MILP 会很快变难，默认只保留最重要的服务节点。
cfg.min_shortage_to_keep = 3;            % 短缺量低于该阈值的节点不参与优化。
cfg.min_surplus_to_keep = 3;             % 富余量低于该阈值的节点不参与优化。
cfg.balance_shortage_surplus_nodes = true; % 筛选时尽量同时保留短缺点和富余点。

%% 稀疏邻接图参数
cfg.use_sparse_adjacency = true;         % 若为 true，只允许车辆沿局部邻接边行驶，不再使用全联通图。
cfg.edge_radius_km = 1.6 * cfg.grid_size_m / 1000; % 邻接半径：距离不超过该值的网格对默认连边。
cfg.edge_nearest_neighbors = 6;          % 每个节点至少连接的最近邻数量，防止局部边过少。
cfg.depot_nearest_neighbors = 8;         % 调度中心至少连接的最近服务节点数量。
cfg.ensure_undirected_edges = true;      % 若为 true，加入 i->j 的同时也加入 j->i。
cfg.print_edge_summary = true;           % 是否打印稀疏图边数量、平均出度等信息。

%% 调度车数据
cfg.vehicle_param_file = fullfile(cfg.data_dir, "dispatch_vehicle_params_1km.csv"); % 调度车参数表。
cfg.use_available_vehicles_only = true;  % 只使用 available 字段等于 1 的调度车。
cfg.max_vehicles_to_use = 20;            % 使用的调度车数量；若超过车辆表数量，则循环复制已有车辆模板补足。
cfg.force_all_vehicles_used = false;     % 若为 false，模型允许部分车辆不出车。
cfg.return_to_depot = true;              % 若为 true，已出车车辆最终返回起点/调度中心。

%% 服务时间参数
cfg.use_vehicle_specific_service_time = true; % 若车辆表中有装卸时间，则优先使用车辆表。
cfg.default_load_time_min_per_bike = 0.60;    % 默认装载一辆单车所需时间，单位：分钟/辆。
cfg.default_unload_time_min_per_bike = 0.45;  % 默认卸载一辆单车所需时间，单位：分钟/辆。
cfg.default_fixed_stop_time_min = 4.0;        % 每访问一个网格的固定停车、找车和操作时间，单位：分钟。
cfg.default_max_route_time_min = 180.0;       % 单辆车单次高峰调度最大工作时间，单位：分钟。

%% 目标函数权重
cfg.alpha_makespan = 1.0;                % 最大完成时间 T 的权重。
cfg.gamma_total_time = 0.08;             % 所有车辆总服务时间 sum(T_k) 的权重。
cfg.beta_unmet_shortage = 25.0;          % 每辆未满足短缺单车的基础惩罚。
cfg.priority_shortage_multiplier = 1.0;  % 区域短缺惩罚倍数，后续可替换为区域重要性权重。

%% 模型选项
cfg.integer_bike_quantities = true;      % 若为 true，装车量、卸车量和未满足短缺量均为整数。
cfg.big_m_load = 1.0e4;                  % 载重转移 Big-M 约束中的大常数。
cfg.service_level_required = 0.85;       % 被选中短缺节点的总短缺至少满足该比例。
cfg.include_service_level_constraint = true; % 是否加入总服务水平约束。
cfg.use_mtz_subtour_elimination = true;  % 是否使用 MTZ 约束消除子回路。

%% 自写求解器控制参数
cfg.solver.method = "heuristic";         % 求解方法："heuristic" 为贪心+局部搜索+模拟退火；"milp" 为原自写分支定界。
cfg.solver.tol = 1.0e-8;                 % 单纯形法与约束判断的数值容差。
cfg.solver.integer_tol = 1.0e-6;         % 变量距离最近整数不超过该值时视为整数。
cfg.solver.max_branch_nodes = 5000;      % 分支定界最大搜索节点数。
cfg.solver.max_seconds = 3600;            % 分支定界最大运行时间，单位：秒。
cfg.solver.display = true;               % 是否打印分支定界过程信息。
cfg.solver.branch_rule = "most_fractional"; % 分支策略：优先选择最接近 0.5 的整数变量。

%% 启发式求解器参数
cfg.heuristic.random_seed = 20240607;    % 随机种子，保证模拟退火结果可复现。
cfg.heuristic.max_greedy_tasks = 300;    % 贪心阶段最多生成的调度任务数。
cfg.heuristic.sa_iterations = 6000;      % 模拟退火迭代次数。
cfg.heuristic.initial_temperature = 80;  % 模拟退火初始温度。
cfg.heuristic.cooling_rate = 0.996;      % 每次迭代后的降温系数。
cfg.heuristic.min_temperature = 1.0e-4;  % 最低温度。
cfg.heuristic.progress_interval = 500;   % 每隔多少次迭代打印一次进度。
cfg.heuristic.neighbor_sample_limit = 100000; % 贪心阶段每轮最多评估的候选动作数量，500m 下需要覆盖更多供需组合。
cfg.heuristic.allow_unserved_after_target = true; % 达到服务水平后，仍允许继续加入能改善目标的任务。

end

function root = projectRoot()
%PROJECTROOT 根据当前文件位置返回项目根目录。
thisFile = mfilename("fullpath");
root = string(fileparts(fileparts(fileparts(thisFile))));
end
