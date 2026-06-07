function mdl = model(cfg)
%MODEL 根据处理后数据生成共享单车再平衡混合整数线性模型。
%
% 模型采用改进目标函数：
%   min alpha*T + gamma*sum(T_k) + sum_j beta_j*u_j
% 若参数中开启 MTZ，则同时加入 MTZ 子回路消除约束。

arguments
    cfg struct
end

if ~ismember(cfg.grid_size_m, cfg.available_grid_sizes)
    error("Unsupported grid size: %d", cfg.grid_size_m);
end
if cfg.grid_size_m ~= 1000 && cfg.grid_size_m ~= 500
    error("Grid size %dm is reserved, but no processed demand file exists yet.", cfg.grid_size_m);
end

demand = readDemandTable(cfg);
gridMeta = readtable(fullfile(cfg.data_dir, sprintf("grid_metadata_%s.csv", gridTag(cfg.grid_size_m))));
vehicles = readtable(cfg.vehicle_param_file, TextType="string");

if cfg.use_available_vehicles_only && any(strcmp("available", vehicles.Properties.VariableNames))
    vehicles = vehicles(vehicles.available == 1, :);
end
if isempty(vehicles)
    error("No available dispatch vehicles found.");
end
vehicles = expandVehicleTable(vehicles, cfg.max_vehicles_to_use);

scenarioRows = demand(string(demand.scenario_id) == string(cfg.scenario_id), :);
if isempty(scenarioRows)
    error("Scenario %s not found in demand table.", cfg.scenario_id);
end

nodes = selectServiceNodes(scenarioRows, cfg);
if isempty(nodes)
    error("No service nodes selected. Check shortage/surplus thresholds.");
end

[nodes, depot] = attachCoordinates(nodes, gridMeta, vehicles);
distKm = buildDistanceKm(nodes, depot);
edges = buildSparseEdges(distKm, cfg);

data = struct();
data.nodes = nodes;
data.vehicles = vehicles;
data.depot = depot;
data.dist_km = distKm;
data.edges = edges;
data.edge_from = edges.from;
data.edge_to = edges.to;
data.edge_dist_km = edges.distance_km;
data.edge_count = height(edges);
data.n = height(nodes);
data.k = height(vehicles);
data.node_ids = string(nodes.grid_id);
data.vehicle_ids = string(vehicles.vehicle_id);
data.surplus = double(nodes.surplus);
data.shortage = double(nodes.shortage);
data.capacity = double(vehicles.capacity_bikes);
data.speed = double(vehicles.speed_kmh);
data.load_time = vehicleColumn(vehicles, "load_time_min_per_bike", cfg.default_load_time_min_per_bike);
data.unload_time = vehicleColumn(vehicles, "unload_time_min_per_bike", cfg.default_unload_time_min_per_bike);
data.fixed_stop_time = vehicleColumn(vehicles, "fixed_stop_time_min", cfg.default_fixed_stop_time_min);
data.max_route_time = vehicleColumn(vehicles, "max_route_time_min", cfg.default_max_route_time_min);
data.beta = cfg.beta_unmet_shortage * cfg.priority_shortage_multiplier * ones(data.n, 1);

if cfg.print_edge_summary
    outDegree = accumarray(data.edge_from, 1, [data.n + 1, 1]);
    fprintf("稀疏邻接图：节点=%d，边=%d，平均出度=%.2f，最大出度=%d\n", ...
        data.n + 1, data.edge_count, mean(outDegree), max(outDegree));
end

builder = newBuilder();
idx = defineVariables(data, cfg, builder);
builder = idx.builder;

[builder, c] = setObjective(builder, idx, data, cfg);
builder = addCoreConstraints(builder, idx, data, cfg);
builder = addRoutingConstraints(builder, idx, data, cfg);
builder = addLoadConstraints(builder, idx, data, cfg);
if cfg.use_mtz_subtour_elimination
    builder = addMtzConstraints(builder, idx, data);
end

mdl = struct();
mdl.name = "bike_rebalancing_" + string(cfg.grid_size_m) + "m_" + string(cfg.scenario_id);
mdl.Aineq = sparse(builder.ai, builder.aj, builder.av, builder.nIneq, builder.nVar);
mdl.bineq = builder.bineq(:);
mdl.Aeq = sparse(builder.ei, builder.ej, builder.ev, builder.nEq, builder.nVar);
mdl.beq = builder.beq(:);
mdl.c = c(:);
mdl.lb = builder.lb(:);
mdl.ub = builder.ub(:);
mdl.intcon = unique(builder.intcon(:));
mdl.var_names = builder.varNames(:);
mdl.index = rmfield(idx, "builder");
mdl.data = data;
mdl.cfg = cfg;
end

function demand = readDemandTable(cfg)
tag = gridTag(cfg.grid_size_m);
parquetFile = fullfile(cfg.data_dir, sprintf("scenario_grid_demand_%s.parquet", tag));
csvFile = fullfile(cfg.data_dir, sprintf("scenario_grid_demand_%s.csv", tag));
if isfile(csvFile)
    demand = readtable(csvFile, TextType="string");
elseif isfile(parquetFile) && exist("parquetread", "file") == 2
    demand = parquetread(parquetFile);
else
    error("Cannot read demand data. Provide %s or use MATLAB with parquetread for %s.", csvFile, parquetFile);
end
end

function tag = gridTag(sizeM)
if mod(sizeM, 1000) == 0
    tag = sprintf("%dkm", sizeM / 1000);
else
    tag = sprintf("%dm", sizeM);
end
end

function nodes = selectServiceNodes(rows, cfg)
rows = rows(double(rows.shortage) >= cfg.min_shortage_to_keep | double(rows.surplus) >= cfg.min_surplus_to_keep, :);
if height(rows) <= cfg.max_service_nodes
    nodes = rows;
    return;
end

if cfg.balance_shortage_surplus_nodes
    nShort = ceil(cfg.max_service_nodes / 2);
    nSurp = cfg.max_service_nodes - nShort;
    shortRows = sortrows(rows(double(rows.shortage) > 0, :), "shortage", "descend");
    surpRows = sortrows(rows(double(rows.surplus) > 0, :), "surplus", "descend");
    keepShort = shortRows(1:min(nShort, height(shortRows)), :);
    keepSurp = surpRows(1:min(nSurp, height(surpRows)), :);
    nodes = unique([keepShort; keepSurp], "rows", "stable");
    if height(nodes) < cfg.max_service_nodes
        left = setdiff(rows, nodes, "rows", "stable");
        left.score = double(left.shortage) + double(left.surplus);
        left = sortrows(left, "score", "descend");
        nodes = [nodes; left(1:min(cfg.max_service_nodes - height(nodes), height(left)), 1:width(rows))];
    end
else
    rows.score = double(rows.shortage) + double(rows.surplus);
    rows = sortrows(rows, "score", "descend");
    nodes = rows(1:cfg.max_service_nodes, 1:width(rows)-1);
end
end

function [nodes, depot] = attachCoordinates(nodes, gridMeta, vehicles)
[ok, loc] = ismember(string(nodes.grid_id), string(gridMeta.grid_id));
if any(~ok)
    error("Some selected grid IDs are missing from grid metadata.");
end
nodes.center_lng = gridMeta.center_lng(loc);
nodes.center_lat = gridMeta.center_lat(loc);

depot.grid_id = string(vehicles.start_grid_id(1));
depot.lng = double(vehicles.start_lng(1));
depot.lat = double(vehicles.start_lat(1));
end

function distKm = buildDistanceKm(nodes, depot)
lng = [depot.lng; double(nodes.center_lng)];
lat = [depot.lat; double(nodes.center_lat)];
m = numel(lng);
distKm = zeros(m, m);
for i = 1:m
    for j = 1:m
        if i ~= j
            distKm(i, j) = haversineKm(lng(i), lat(i), lng(j), lat(j));
        end
    end
end
end

function edges = buildSparseEdges(distKm, cfg)
%BUILDSPARSEEDGES 根据半径和最近邻规则构造稀疏有向邻接图。
nodeCount = size(distKm, 1);
depot = 1;
edgeMask = false(nodeCount, nodeCount);

if cfg.use_sparse_adjacency
    edgeMask = edgeMask | (distKm <= cfg.edge_radius_km & distKm > 0);

    for i = 1:nodeCount
        candidates = setdiff(1:nodeCount, i);
        [~, order] = sort(distKm(i, candidates), "ascend");
        keepCount = min(cfg.edge_nearest_neighbors, numel(candidates));
        keep = candidates(order(1:keepCount));
        edgeMask(i, keep) = true;
    end

    serviceNodes = 2:nodeCount;
    [~, depotOrder] = sort(distKm(depot, serviceNodes), "ascend");
    keepCount = min(cfg.depot_nearest_neighbors, numel(serviceNodes));
    depotKeep = serviceNodes(depotOrder(1:keepCount));
    edgeMask(depot, depotKeep) = true;
    edgeMask(depotKeep, depot) = true;
else
    edgeMask = true(nodeCount, nodeCount);
end

edgeMask(1:nodeCount+1:end) = false;
if cfg.ensure_undirected_edges
    edgeMask = edgeMask | edgeMask';
end

[from, to] = find(edgeMask);
edges = table(from, to, distKm(edgeMask), VariableNames=["from","to","distance_km"]);
edges = sortrows(edges, ["from","to"]);
end

function d = haversineKm(lng1, lat1, lng2, lat2)
r = 6371.0088;
dlng = deg2rad(lng2 - lng1);
dlat = deg2rad(lat2 - lat1);
a = sin(dlat / 2)^2 + cos(deg2rad(lat1)) * cos(deg2rad(lat2)) * sin(dlng / 2)^2;
d = 2 * r * asin(sqrt(a));
end

function values = vehicleColumn(tbl, name, defaultValue)
if any(strcmp(name, tbl.Properties.VariableNames))
    values = double(tbl.(name));
else
    values = defaultValue * ones(height(tbl), 1);
end
end

function vehicles = expandVehicleTable(vehicles, targetCount)
%EXPANDVEHICLETABLE 按需要循环复制车辆模板，支持灵活调整车辆数量。
if targetCount <= 0
    error("max_vehicles_to_use 必须为正数。");
end

base = vehicles;
baseCount = height(base);
if baseCount >= targetCount
    vehicles = base(1:targetCount, :);
    return;
end

extraCount = targetCount - baseCount;
extra = base(repmat((1:baseCount)', ceil(extraCount / baseCount), 1), :);
extra = extra(1:extraCount, :);
vehicles = [base; extra];

if any(strcmp("vehicle_id", vehicles.Properties.VariableNames))
    vehicles.vehicle_id = compose("truck_%02d", (1:targetCount)');
end

if any(strcmp("notes", vehicles.Properties.VariableNames))
    for i = (baseCount + 1):targetCount
        templateIndex = mod(i - 1, baseCount) + 1;
        vehicles.notes(i) = "Repeated template from " + string(base.vehicle_id(templateIndex));
    end
end
end

function b = newBuilder()
b.nVar = 0;
b.varNames = strings(0, 1);
b.lb = zeros(0, 1);
b.ub = zeros(0, 1);
b.intcon = zeros(0, 1);
b.ai = zeros(0, 1); b.aj = zeros(0, 1); b.av = zeros(0, 1); b.bineq = zeros(0, 1); b.nIneq = 0;
b.ei = zeros(0, 1); b.ej = zeros(0, 1); b.ev = zeros(0, 1); b.beq = zeros(0, 1); b.nEq = 0;
end

function [b, ids] = addVars(b, prefix, dims, lb, ub, isInteger)
count = prod(dims);
ids = reshape((b.nVar + 1):(b.nVar + count), dims);
b.nVar = b.nVar + count;
b.lb(ids(:), 1) = lb;
b.ub(ids(:), 1) = ub;
for t = 1:count
    b.varNames(ids(t), 1) = prefix + "_" + string(t);
end
if isInteger
    b.intcon = [b.intcon; ids(:)];
end
end

function idx = defineVariables(data, cfg, builder)
n = data.n;
k = data.k;
nodeCount = n + 1; % 节点总数：调度中心 + 服务网格。
edgeCount = data.edge_count;

[builder, idx.x] = addVars(builder, "x", [edgeCount, k], 0, 1, true);
[builder, idx.y] = addVars(builder, "y", [n, k], 0, 1, true);
[builder, idx.h] = addVars(builder, "h", [n, k], 0, 1, true);
[builder, idx.p] = addVars(builder, "p", [n, k], 0, inf, cfg.integer_bike_quantities);
[builder, idx.q] = addVars(builder, "q", [n, k], 0, inf, cfg.integer_bike_quantities);
[builder, idx.load] = addVars(builder, "load", [nodeCount, k], 0, inf, cfg.integer_bike_quantities);
[builder, idx.unmet] = addVars(builder, "unmet", [n, 1], 0, inf, cfg.integer_bike_quantities);
[builder, idx.tk] = addVars(builder, "vehicle_time", [k, 1], 0, inf, false);
[builder, idx.t] = addVars(builder, "makespan", [1, 1], 0, inf, false);
[builder, idx.order] = addVars(builder, "mtz_order", [n, k], 0, n, false);

% 设置每个节点的装车、卸车和未满足短缺变量上界。
for i = 1:n
    builder.ub(idx.unmet(i)) = data.shortage(i);
    for kk = 1:k
        builder.ub(idx.p(i, kk)) = data.surplus(i);
        builder.ub(idx.q(i, kk)) = data.shortage(i);
    end
end

% 设置车辆载重上界和单车路线时间上界。
for kk = 1:k
    builder.ub(idx.load(:, kk)) = data.capacity(kk);
    builder.ub(idx.tk(kk)) = data.max_route_time(kk);
end
idx.builder = builder;
end

function [b, c] = setObjective(b, idx, data, cfg)
c = zeros(b.nVar, 1);
c(idx.t) = cfg.alpha_makespan;
c(idx.tk) = cfg.gamma_total_time;
c(idx.unmet) = data.beta;
end

function b = addCoreConstraints(b, idx, data, cfg)
n = data.n; k = data.k;

% 车辆时间约束：行驶时间 + 装车时间 + 卸车时间 + 固定停车时间 <= T_k。
for kk = 1:k
    row = idx.x(:, kk)';
    val = 60 * data.edge_dist_km' / data.speed(kk);
    serviceVars = [idx.p(:, kk)', idx.q(:, kk)', idx.y(:, kk)', idx.tk(kk)];
    serviceVals = [data.load_time(kk) * ones(1, n), data.unload_time(kk) * ones(1, n), ...
        zeros(1, n), -1];
    stopVars = idx.h(:, kk)';
    stopVals = data.fixed_stop_time(kk) * ones(1, n);
    b = addIneq(b, [row, serviceVars, stopVars], [val, serviceVals, stopVals], 0);
end

% 最大完成时间约束：每辆车的服务时间均不能超过 T。
for kk = 1:k
    b = addIneq(b, [idx.tk(kk), idx.t], [1, -1], 0);
end

% 每个富余节点被装走的车辆数不能超过该节点富余量。
for i = 1:n
    b = addIneq(b, idx.p(i, :), ones(1, k), data.surplus(i));
end

% 短缺平衡约束：被补入数量 + 未满足数量 = 短缺量。
for i = 1:n
    b = addEq(b, [idx.q(i, :), idx.unmet(i)], [ones(1, k), 1], data.shortage(i));
end

% 可选服务水平约束：满足量至少达到“可满足需求上限”的给定比例。
totalShortage = sum(data.shortage);
totalSurplus = sum(data.surplus);
if cfg.include_service_level_constraint && totalShortage > 0
    maxServableShortage = min(totalShortage, totalSurplus);
    requiredServed = cfg.service_level_required * maxServableShortage;
    b = addIneq(b, idx.unmet(:)', ones(1, n), totalShortage - requiredServed);
end

% 服务启用约束：车辆只有在节点真实服务，才能装车或卸车；服务必须发生在已访问节点。
for i = 1:n
    for kk = 1:k
        b = addIneq(b, [idx.p(i, kk), idx.h(i, kk)], [1, -data.surplus(i)], 0);
        b = addIneq(b, [idx.q(i, kk), idx.h(i, kk)], [1, -data.shortage(i)], 0);
        b = addIneq(b, [idx.h(i, kk), idx.y(i, kk)], [1, -1], 0);
    end
end
end

function b = addRoutingConstraints(b, idx, data, cfg)
n = data.n; k = data.k;
depot = 1; % 在内部编号中，1 表示调度中心。
edgeFrom = data.edge_from;
edgeTo = data.edge_to;

for kk = 1:k
    % 服务节点流平衡：访问某节点则必须有一条进弧和一条出弧。
    for ii = 1:n
        node = ii + 1;
        outgoingEdges = find(edgeFrom == node);
        incomingEdges = find(edgeTo == node);
        b = addEq(b, [idx.x(outgoingEdges, kk)', idx.y(ii, kk)], [ones(1, numel(outgoingEdges)), -1], 0);
        b = addEq(b, [idx.x(incomingEdges, kk)', idx.y(ii, kk)], [ones(1, numel(incomingEdges)), -1], 0);
    end

    % 每辆车最多从调度中心出发一次，并最多返回一次。
    departEdges = find(edgeFrom == depot & edgeTo ~= depot);
    returnEdges = find(edgeTo == depot & edgeFrom ~= depot);
    departArcs = reshape(idx.x(departEdges, kk), 1, []);
    returnArcs = reshape(idx.x(returnEdges, kk), 1, []);
    b = addIneq(b, departArcs, ones(1, numel(departEdges)), 1);
    b = addIneq(b, returnArcs, ones(1, numel(returnEdges)), 1);

    if cfg.force_all_vehicles_used
        b = addEq(b, departArcs, ones(1, numel(departEdges)), 1);
        b = addEq(b, returnArcs, ones(1, numel(returnEdges)), 1);
    else
        % 若车辆出发，则必须返回；若车辆闲置，则出发和返回弧都为 0。
        b = addEq(b, [departArcs, returnArcs], ...
            [ones(1, numel(departEdges)), -ones(1, numel(returnEdges))], 0);
    end

    if ~cfg.return_to_depot
        % 预留开放路径接口。当前版本保留闭合路径，便于 MTZ 约束定义清晰。
    end
end
end

function b = addLoadConstraints(b, idx, data, cfg)
k = data.k;
M = max(cfg.big_m_load, max(data.capacity) + max(data.surplus) + max(data.shortage));
edgeFrom = data.edge_from;
edgeTo = data.edge_to;

for kk = 1:k
    % 车辆离开调度中心时为空载。
    b = addEq(b, idx.load(1, kk), 1, 0);

    for e = 1:data.edge_count
        i = edgeFrom(e);
        j = edgeTo(e);
        if j == 1
            pVar = [];
            qVar = [];
            pCoef = [];
            qCoef = [];
        else
            pVar = idx.p(j-1, kk);
            qVar = idx.q(j-1, kk);
            pCoef = -1;
            qCoef = 1;
        end
        % 载重下界：load_j >= load_i + p_j - q_j - M(1-x_ijk)
        % 等价线性形式：load_i - load_j + p_j - q_j + M*x_ijk <= M
        b = addIneq(b, [idx.load(i, kk), idx.load(j, kk), pVar, qVar, idx.x(e, kk)], ...
            [1, -1, -pCoef, -qCoef, M], M);
        % 载重上界：load_j <= load_i + p_j - q_j + M(1-x_ijk)
        % 等价线性形式：-load_i + load_j - p_j + q_j + M*x_ijk <= M
        b = addIneq(b, [idx.load(i, kk), idx.load(j, kk), pVar, qVar, idx.x(e, kk)], ...
            [-1, 1, pCoef, qCoef, M], M);
    end
end
end

function b = addMtzConstraints(b, idx, data)
n = data.n; k = data.k;
edgeFrom = data.edge_from;
edgeTo = data.edge_to;
serviceEdgeMask = edgeFrom > 1 & edgeTo > 1;
serviceEdges = find(serviceEdgeMask);
for kk = 1:k
    for i = 1:n
        % 访问顺序启用约束：0 <= order_i <= n*y_i。
        b = addIneq(b, [idx.order(i, kk), idx.y(i, kk)], [1, -n], 0);
    end
    for pos = 1:numel(serviceEdges)
        e = serviceEdges(pos);
        ii = edgeFrom(e) - 1;
        jj = edgeTo(e) - 1;
        b = addIneq(b, [idx.order(ii, kk), idx.order(jj, kk), idx.x(e, kk)], ...
            [1, -1, n], n - 1);
    end
end
end

function b = addIneq(b, vars, vals, rhs)
vars = vars(:);
vals = vals(:);
mask = ~isempty(vars) & vars > 0 & vals ~= 0;
vars = vars(mask);
vals = vals(mask);
b.nIneq = b.nIneq + 1;
b.ai = [b.ai; b.nIneq * ones(numel(vars), 1)];
b.aj = [b.aj; vars(:)];
b.av = [b.av; vals(:)];
b.bineq(b.nIneq, 1) = rhs;
end

function b = addEq(b, vars, vals, rhs)
vars = vars(:);
vals = vals(:);
mask = ~isempty(vars) & vars > 0 & vals ~= 0;
vars = vars(mask);
vals = vals(mask);
b.nEq = b.nEq + 1;
b.ei = [b.ei; b.nEq * ones(numel(vars), 1)];
b.ej = [b.ej; vars(:)];
b.ev = [b.ev; vals(:)];
b.beq(b.nEq, 1) = rhs;
end
