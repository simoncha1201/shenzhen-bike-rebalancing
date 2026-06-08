function sol = solve_heuristic(mdl, cfg)
%SOLVE_HEURISTIC 贪心插入 + 局部搜索 + 模拟退火求解器。
%
% 该求解器不尝试证明全局最优，而是直接围绕原目标函数构造高质量可行解：
%   1. 在稀疏邻接图上计算最短路；
%   2. 贪心生成“富余点 -> 短缺点”的调度任务；
%   3. 将任务插入车辆路线；
%   4. 用 relocate、swap、2-opt/reverse 等邻域操作进行模拟退火改进。

arguments
    mdl struct
    cfg struct
end

rng(cfg.heuristic.random_seed);
tStart = tic;
data = mdl.data;
opts = cfg.heuristic;

[spDist, spNext] = allPairsShortestPaths(data);
state = initialState(data);
[state, greedyInfo] = greedyConstruction(state, data, cfg, spDist);

current = state;
[currentObj, currentParts] = evaluateState(current, data, cfg, spDist);
best = current;
bestObj = currentObj;
bestParts = currentParts;

temperature = opts.initial_temperature;
if cfg.solver.display
    fprintf("启发式初解：任务数=%d，满足短缺=%.0f，未满足=%.0f，目标=%.6f，用时=%.2f秒\n", ...
        greedyInfo.task_count, sum(best.served), sum(best.unmet), bestObj, toc(tStart));
end

for iter = 1:opts.sa_iterations
    candidate = makeNeighbor(current, data);
    [candObj, candParts] = evaluateState(candidate, data, cfg, spDist);
    delta = candObj - currentObj;

    if isfinite(candObj) && (delta <= 0 || rand() < exp(-delta / max(temperature, opts.min_temperature)))
        current = candidate;
        currentObj = candObj;
        currentParts = candParts;
    end

    if currentObj < bestObj
        best = current;
        bestObj = currentObj;
        bestParts = currentParts;
    end

    temperature = max(opts.min_temperature, temperature * opts.cooling_rate);

    if cfg.solver.display && mod(iter, opts.progress_interval) == 0
        fprintf("模拟退火进度：迭代=%d，当前目标=%.6f，最好目标=%.6f，温度=%.5f，已用时=%.2f秒\n", ...
            iter, currentObj, bestObj, temperature, toc(tStart));
    end
end

if isempty(bestParts)
    [bestObj, bestParts] = evaluateState(best, data, cfg, spDist);
end

requiredServed = cfg.service_level_required * min(sum(data.shortage), sum(data.surplus));
servedEnough = sum(best.served) + 1.0e-8 >= requiredServed;

sol = struct();
if servedEnough
    sol.status = "heuristic_feasible";
else
    sol.status = "heuristic_service_level_not_met";
end
sol.x = [];
sol.objective = bestObj;
sol.proven_optimal = false;
sol.nodes_explored = opts.sa_iterations;
sol.best_bound = NaN;
sol.gap = NaN;
sol.runtime_seconds = toc(tStart);
sol.decoded = decodeHeuristicSolution(best, bestParts, data, cfg, spDist, spNext);
end

function state = initialState(data)
%INITIALSTATE 构造空路线初始状态。
state.routes = cell(data.k, 1);
for k = 1:data.k
    state.routes{k} = zeros(0, 3); % 每行：[富余节点编号, 短缺节点编号, 调度数量]
end
state.remaining_surplus = data.surplus(:);
state.remaining_shortage = data.shortage(:);
state.served = zeros(data.n, 1);
state.unmet = data.shortage(:);
end

function [state, info] = greedyConstruction(state, data, cfg, spDist)
%GREEDYCONSTRUCTION 按单位时间收益贪心插入调度任务。
targetServed = cfg.service_level_required * min(sum(data.shortage), sum(data.surplus));
taskCount = 0;

while taskCount < cfg.heuristic.max_greedy_tasks
    bestMove = [];
    bestObj = inf;
    currentObj = evaluateState(state, data, cfg, spDist, false);
    samples = 0;

    surplusNodes = find(state.remaining_surplus > 0);
    shortageNodes = find(state.remaining_shortage > 0);
    if isempty(surplusNodes) || isempty(shortageNodes)
        break;
    end

    vehicleTime = zeros(data.k, 1);
    for kk = 1:data.k
        [vehicleTime(kk), okTime] = routeTime(state.routes{kk}, kk, data, spDist, cfg.return_to_depot);
        if ~okTime
            vehicleTime(kk) = inf;
        end
    end
    [~, vehicleOrder] = sort(vehicleTime, "ascend");

    for kk = reshape(vehicleOrder, 1, [])
        for si = reshape(surplusNodes, 1, [])
            for dj = reshape(shortageNodes, 1, [])
                if samples >= cfg.heuristic.neighbor_sample_limit
                    break;
                end
                samples = samples + 1;
                qty = min([state.remaining_surplus(si), state.remaining_shortage(dj), data.capacity(kk)]);
                if qty <= 0 || ~isfinite(spDist(si + 1, dj + 1))
                    continue;
                end

                trial = state;
                trial.routes{kk} = [trial.routes{kk}; si, dj, qty];
                trial.remaining_surplus(si) = trial.remaining_surplus(si) - qty;
                trial.remaining_shortage(dj) = trial.remaining_shortage(dj) - qty;
                trial.served(dj) = trial.served(dj) + qty;
                trial.unmet(dj) = trial.remaining_shortage(dj);

                trialObj = evaluateState(trial, data, cfg, spDist, false);
                if trialObj < bestObj
                    bestObj = trialObj;
                    bestMove = trial;
                end
            end
            if samples >= cfg.heuristic.neighbor_sample_limit
                break;
            end
        end
    end

    servedEnough = sum(state.served) >= targetServed;
    improvesObjective = bestObj < currentObj - 1.0e-8;
    if isempty(bestMove) || (~improvesObjective && (servedEnough || ~cfg.heuristic.allow_unserved_after_target))
        break;
    end

    state = bestMove;
    taskCount = taskCount + 1;
end

info = struct("task_count", taskCount);
end

function candidate = makeNeighbor(state, data)
%MAKENEIGHBOR 随机生成一个邻域解。
candidate = state;
moveType = randi(4);
nonempty = find(cellfun(@(r) size(r, 1), candidate.routes) > 0);
if isempty(nonempty)
    return;
end

switch moveType
    case 1
        % relocate：把某个任务移动到另一辆车的任意位置。
        fromK = nonempty(randi(numel(nonempty)));
        row = randi(size(candidate.routes{fromK}, 1));
        task = candidate.routes{fromK}(row, :);
        toK = randi(data.k);
        if task(3) > data.capacity(toK)
            return;
        end
        candidate.routes{fromK}(row, :) = [];
        pos = randi(size(candidate.routes{toK}, 1) + 1);
        candidate.routes{toK} = insertTask(candidate.routes{toK}, task, pos);

    case 2
        % swap：交换两辆车或同一辆车中的两个任务。
        k1 = nonempty(randi(numel(nonempty)));
        k2 = nonempty(randi(numel(nonempty)));
        r1 = randi(size(candidate.routes{k1}, 1));
        r2 = randi(size(candidate.routes{k2}, 1));
        t1 = candidate.routes{k1}(r1, :);
        t2 = candidate.routes{k2}(r2, :);
        if t1(3) > data.capacity(k2) || t2(3) > data.capacity(k1)
            return;
        end
        candidate.routes{k1}(r1, :) = t2;
        candidate.routes{k2}(r2, :) = t1;

    case 3
        % reverse：反转某辆车路线中的一段任务顺序。
        k = nonempty(randi(numel(nonempty)));
        m = size(candidate.routes{k}, 1);
        if m >= 2
            a = randi(m);
            b = randi(m);
            lo = min(a, b);
            hi = max(a, b);
            candidate.routes{k}(lo:hi, :) = flipud(candidate.routes{k}(lo:hi, :));
        end

    case 4
        % intra-relocate：在同一辆车内部移动任务位置。
        k = nonempty(randi(numel(nonempty)));
        m = size(candidate.routes{k}, 1);
        if m >= 2
            from = randi(m);
            task = candidate.routes{k}(from, :);
            candidate.routes{k}(from, :) = [];
            to = randi(m);
            candidate.routes{k} = insertTask(candidate.routes{k}, task, to);
        end
end
end

function route = insertTask(route, task, pos)
%INSERTTASK 将任务插入到指定位置。
if isempty(route)
    route = task;
elseif pos <= 1
    route = [task; route];
elseif pos > size(route, 1)
    route = [route; task];
else
    route = [route(1:pos-1, :); task; route(pos:end, :)];
end
end

function [obj, parts] = evaluateState(state, data, cfg, spDist, enforceServiceLevel)
%EVALUATESTATE 按原目标函数评价一个调度方案。
if nargin < 5
    enforceServiceLevel = false;
end
vehicleTime = zeros(data.k, 1);
feasible = true;

for kk = 1:data.k
    [t, ok] = routeTime(state.routes{kk}, kk, data, spDist, cfg.return_to_depot);
    if ~ok || t > data.max_route_time(kk) + 1.0e-8
        feasible = false;
        break;
    end
    vehicleTime(kk) = t;
end

if ~feasible
    obj = inf;
    parts = [];
    return;
end

served = sum(state.served);
requiredServed = cfg.service_level_required * min(sum(data.shortage), sum(data.surplus));
serviceShortfall = max(0, requiredServed - served);

unmetPenalty = data.beta' * state.unmet;
makespan = max(vehicleTime);
totalTime = sum(vehicleTime);
obj = cfg.alpha_makespan * makespan + cfg.gamma_total_time * totalTime + unmetPenalty;
if cfg.include_service_level_constraint && serviceShortfall > 0
    if enforceServiceLevel
        obj = inf;
        parts = [];
        return;
    end
    servicePenalty = 100 * max(data.beta) * serviceShortfall;
    obj = obj + servicePenalty;
else
    servicePenalty = 0;
end
parts = struct("vehicle_time", vehicleTime, "makespan", makespan, ...
    "total_time", totalTime, "unmet", state.unmet, "served", state.served, ...
    "unmet_penalty", unmetPenalty, "service_shortfall", serviceShortfall, ...
    "service_penalty", servicePenalty);
end

function [t, ok] = routeTime(route, kk, data, spDist, returnToDepot)
%ROUTETIME 计算一辆车路线的服务时间。
t = 0;
ok = true;
current = 1; % 调度中心内部编号。

for r = 1:size(route, 1)
    pickup = route(r, 1) + 1;
    dropoff = route(r, 2) + 1;
    qty = route(r, 3);
    if qty > data.capacity(kk) + 1.0e-8
        ok = false;
        return;
    end
    if ~isfinite(spDist(current, pickup)) || ~isfinite(spDist(pickup, dropoff))
        ok = false;
        return;
    end
    t = t + 60 * spDist(current, pickup) / data.speed(kk);
    t = t + data.fixed_stop_time(kk) + data.load_time(kk) * qty;
    t = t + 60 * spDist(pickup, dropoff) / data.speed(kk);
    t = t + data.fixed_stop_time(kk) + data.unload_time(kk) * qty;
    current = dropoff;
end

if returnToDepot && current ~= 1
    if ~isfinite(spDist(current, 1))
        ok = false;
        return;
    end
    t = t + 60 * spDist(current, 1) / data.speed(kk);
end
end

function [dist, nextNode] = allPairsShortestPaths(data)
%ALLPAIRSSHORTESTPATHS 在稀疏邻接图上计算所有节点之间最短路。
nNode = data.n + 1;
dist = inf(nNode, nNode);
nextNode = zeros(nNode, nNode);
for i = 1:nNode
    dist(i, i) = 0;
    nextNode(i, i) = i;
end

for e = 1:data.edge_count
    i = data.edge_from(e);
    j = data.edge_to(e);
    if data.edge_dist_km(e) < dist(i, j)
        dist(i, j) = data.edge_dist_km(e);
        nextNode(i, j) = j;
    end
end

for k = 1:nNode
    for i = 1:nNode
        dik = dist(i, k);
        if ~isfinite(dik)
            continue;
        end
        for j = 1:nNode
            alt = dik + dist(k, j);
            if alt < dist(i, j)
                dist(i, j) = alt;
                nextNode(i, j) = nextNode(i, k);
            end
        end
    end
end
end

function decoded = decodeHeuristicSolution(state, parts, data, cfg, spDist, spNext)
%DECODEHEURISTICSOLUTION 将启发式路线展开为可视化所需表格。
nodeLabels = ["DEPOT"; data.node_ids(:)];
routeRows = {};
actionRows = {};
shortageRows = {};

for kk = 1:data.k
    current = 1;
    route = state.routes{kk};
    for r = 1:size(route, 1)
        pickup = route(r, 1) + 1;
        dropoff = route(r, 2) + 1;
        qty = route(r, 3);
        routeRows = appendPathRows(routeRows, data.vehicle_ids(kk), current, pickup, nodeLabels, spDist, spNext, data.speed(kk));
        actionRows(end+1, :) = {data.vehicle_ids(kk), data.node_ids(route(r, 1)), qty, 0}; %#ok<AGROW>
        routeRows = appendPathRows(routeRows, data.vehicle_ids(kk), pickup, dropoff, nodeLabels, spDist, spNext, data.speed(kk));
        actionRows(end+1, :) = {data.vehicle_ids(kk), data.node_ids(route(r, 2)), 0, qty}; %#ok<AGROW>
        current = dropoff;
    end
    if cfg.return_to_depot && current ~= 1
        routeRows = appendPathRows(routeRows, data.vehicle_ids(kk), current, 1, nodeLabels, spDist, spNext, data.speed(kk));
    end
end

for i = 1:data.n
    shortageRows(end+1, :) = {data.node_ids(i), data.shortage(i), state.unmet(i), ...
        state.served(i), data.surplus(i)}; %#ok<AGROW>
end

decoded = struct();
decoded.routes = makeTable(routeRows, ["vehicle_id","from_grid_id","to_grid_id","distance_km","travel_time_min"]);
decoded.actions = makeTable(actionRows, ["vehicle_id","grid_id","pickup_bikes","dropoff_bikes"]);
decoded.shortage = makeTable(shortageRows, ["grid_id","shortage_bikes","unmet_bikes","served_bikes","surplus_bikes"]);
decoded.vehicle_time = table(data.vehicle_ids(:), parts.vehicle_time(:), VariableNames=["vehicle_id","route_time_min"]);
decoded.objective_parts = table(parts.makespan, parts.total_time, sum(state.unmet), ...
    sum(state.served), parts.service_shortfall, ...
    VariableNames=["makespan_min","total_vehicle_time_min","total_unmet_bikes","total_served_bikes","service_shortfall_bikes"]);
decoded.node_copies = makeNodeCopyTable(data);
end

function tbl = makeNodeCopyTable(data)
tbl = table(data.node_ids(:), data.original_node_ids(:), data.visit_copy_index(:), ...
    data.visit_copy_count(:), data.shortage(:), data.surplus(:), ...
    VariableNames=["grid_id","original_grid_id","visit_copy_index", ...
    "visit_copy_count","shortage_bikes","surplus_bikes"]);
end

function rows = appendPathRows(rows, vehicleId, fromNode, toNode, nodeLabels, spDist, spNext, speedKmh)
%APPENDPATHROWS 将最短路节点序列展开为路线边表。
path = reconstructPath(fromNode, toNode, spNext);
for p = 1:(numel(path) - 1)
    i = path(p);
    j = path(p + 1);
    d = spDist(i, j);
    rows(end+1, :) = {vehicleId, nodeLabels(i), nodeLabels(j), d, 60 * d / speedKmh}; %#ok<AGROW>
end
end

function path = reconstructPath(i, j, spNext)
%RECONSTRUCTPATH 根据 Floyd next 矩阵恢复最短路节点序列。
if spNext(i, j) == 0
    path = [];
    return;
end
path = i;
while i ~= j
    i = spNext(i, j);
    path(end+1) = i; %#ok<AGROW>
end
end

function tbl = makeTable(rows, names)
%MAKETABLE 将单元格结果转换为表。
if isempty(rows)
    tbl = array2table(zeros(0, numel(names)), VariableNames=names);
else
    tbl = cell2table(rows, VariableNames=names);
end
end
