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

% 初解构造：默认贪心（任务整合更好、装卸停靠更省）；可选最小费用流构造。
initMethod = "greedy";
if isfield(opts, "init_method")
    initMethod = opts.init_method;
end

% 最小费用流分配：每次运行都计算，用作目标的"分配层下界"与报告对比（图论亮点）。
% 该下界 = 最优"路费 + 未满足惩罚"，不含车辆路线时间项，故是真实目标的下界。
[flowTasks, flowInfo] = mincost_flow_assignment(data, spDist, cfg);
flowLowerBound = flowInfo.flow_cost;

if initMethod == "flow"
    [state, initInfo] = flowConstruction(state, data, cfg, spDist, flowTasks);
else
    [state, initInfo] = greedyConstruction(state, data, cfg, spDist);
end

current = state;
[currentObj, ~, current] = evaluateStateFull(current, data, cfg, spDist, false);

% add-task 邻域的触发概率：仅当开启且 remaining 池有余量时才尝试新增调度，补救服务水平。
addWeight = 0;
if isfield(opts, "enable_add_task_move") && opts.enable_add_task_move
    if isfield(opts, "add_task_move_weight")
        addWeight = opts.add_task_move_weight;
    else
        addWeight = 0.15;
    end
end
if cfg.solver.display
    fprintf("启发式初解（%s）：任务数=%d，满足短缺=%.0f，未满足=%.0f，目标=%.6f，用时=%.2f秒\n", ...
        initMethod, initInfo.task_count, sum(current.served), sum(current.unmet), currentObj, toc(tStart));
end

% 多起点模拟退火：贪心构造与最小费用流为确定性、只算一次；SA 随机游走可并行。
% 用 parfor 跑 numRestarts 条不同随机种子的 SA 链（同一构造初解出发），取目标最优者。
% 种子按链号固定（random_seed + r），结果与 worker 执行顺序无关、可复现。
numRestarts = 1;
if isfield(opts, "num_restarts")
    numRestarts = max(1, round(opts.num_restarts));
end
wantParallel = numRestarts > 1 && isfield(opts, "use_parallel") && opts.use_parallel;
useParallel = wantParallel && ensureParallelPool();
seeds = opts.random_seed + (0:numRestarts - 1);

chainBest = cell(numRestarts, 1);
chainObj = inf(numRestarts, 1);

if useParallel
    parfor r = 1:numRestarts
        [chainBest{r}, chainObj(r)] = runSAChain(current, currentObj, ...
            data, cfg, spDist, opts, addWeight, seeds(r), false);
    end
else
    for r = 1:numRestarts
        % 单链时保留逐步进度打印（行为与原串行 SA 一致）；多链串行回退则不刷屏。
        displayChain = cfg.solver.display && numRestarts == 1;
        [chainBest{r}, chainObj(r)] = runSAChain(current, currentObj, ...
            data, cfg, spDist, opts, addWeight, seeds(r), displayChain);
    end
end

[bestObj, bestChain] = min(chainObj);
best = chainBest{bestChain};

if cfg.solver.display
    fprintf("多起点 SA：%d 条链（%s），最优目标=%.6f（第 %d 条），用时=%.2f秒\n", ...
        numRestarts, ternary(useParallel, "并行", "串行"), bestObj, bestChain, toc(tStart));
end

% 兜底校验：用全量重算核对最优解，防止增量缓存漂移。
[bestObj, bestParts, best] = evaluateStateFull(best, data, cfg, spDist, false);

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
sol.nodes_explored = numRestarts * opts.sa_iterations;
sol.best_bound = NaN;
sol.gap = NaN;
% 最小费用流分配结果：忽略路线时间约束时的最优调度费用与最大可服务量。
% flow_served 是"只看供需可达、不受车队路线时间限制"时能服务的上界，
% 与启发式实际服务量之差，正好量化了车队路线时间预算的影响（报告对比用）。
sol.flow_cost = flowLowerBound;
sol.flow_served = flowInfo.total_served;
sol.flow_unmet = flowInfo.total_unmet;
sol.flow_runtime_seconds = flowInfo.runtime_seconds;
sol.runtime_seconds = toc(tStart);
sol.decoded = decodeHeuristicSolution(best, bestParts, data, cfg, spDist, spNext);
end

function [best, bestObj] = runSAChain(current, currentObj, data, cfg, spDist, opts, addWeight, seed, display)
%RUNSACHAIN 单条模拟退火链：从给定初解出发做 sa_iterations 次邻域搜索，返回该链最优解。
%   多起点并行时每条链用独立种子，互不干扰；逻辑与原串行 SA 完全一致。
rng(seed);
best = current;
bestObj = currentObj;
temperature = opts.initial_temperature;

for iter = 1:opts.sa_iterations
    [candidate, changedK] = makeNeighbor(current, data, addWeight);
    candidate = refreshChangedVehicles(candidate, changedK, data, cfg, spDist);
    candObj = evalFromCache(candidate, data, cfg);
    delta = candObj - currentObj;

    if isfinite(candObj) && (delta <= 0 || rand() < exp(-delta / max(temperature, opts.min_temperature)))
        current = candidate;
        currentObj = candObj;
    end

    if currentObj < bestObj
        best = current;
        bestObj = currentObj;
    end

    temperature = max(opts.min_temperature, temperature * opts.cooling_rate);

    if display && mod(iter, opts.progress_interval) == 0
        fprintf("模拟退火进度：迭代=%d，当前目标=%.6f，最好目标=%.6f，温度=%.5f\n", ...
            iter, currentObj, bestObj, temperature);
    end
end
end

function ok = ensureParallelPool()
%ENSUREPARALLELPOOL 确保有可用并行池；无 PCT 或建池失败时返回 false（回退串行）。
ok = false;
if exist("gcp", "file") ~= 2
    return;   % 无 Parallel Computing Toolbox
end
try
    pool = gcp("nocreate");
    if isempty(pool)
        pool = parpool;
    end
    ok = ~isempty(pool);
catch
    ok = false;   % 建池失败（如许可证占用），回退串行
end
end

function out = ternary(cond, a, b)
if cond; out = a; else; out = b; end
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
% 增量评估缓存：空路线时每车时间为 0、可行；已满足量为 0；未满足惩罚等于全部短缺惩罚。
state.vehicle_time = zeros(data.k, 1);
state.feasible = true(data.k, 1);
state.served_total = 0;
state.unmet_penalty = data.beta' * state.unmet;
end

function [state, info] = greedyConstruction(state, data, cfg, spDist)
%GREEDYCONSTRUCTION 按目标值贪心插入调度任务（向量化候选评估）。
%   每轮对所有 (车辆×富余×短缺) 候选用 O(1) 增量公式批量计算追加后的路线时间与目标值，
%   不再逐候选调用 routeTime（避免每候选 O(路长) 的重复路线遍历），也不需 sample 截断。
%   追加任务到车 kk 末尾的路线时间增量（与 routeTime 代数等价）：
%     tkNew = vehicle_time(kk) - 旧返场段 + 行驶(末点->富余) + 2*固定停靠
%             + (装+卸)*qty + 行驶(富余->短缺) + 新返场段
targetServed = cfg.service_level_required * min(sum(data.shortage), sum(data.surplus));
returnToDepot = cfg.return_to_depot;
serviceConstraint = cfg.include_service_level_constraint;
maxBeta = max(data.beta);
taskCount = 0;

while taskCount < cfg.heuristic.max_greedy_tasks
    currentObj = evalFromCache(state, data, cfg);

    surplusNodes = find(state.remaining_surplus > 0);
    shortageNodes = find(state.remaining_shortage > 0);
    if isempty(surplusNodes) || isempty(shortageNodes)
        break;
    end

    rs = state.remaining_surplus(surplusNodes);          % [S x 1]
    rsh = state.remaining_shortage(shortageNodes);        % [D x 1]
    betaD = data.beta(shortageNodes);                     % [D x 1]
    qtySupDem = min(rs, rsh.');                            % [S x D] 受供需限制（未计车容）
    spPD = spDist(surplusNodes + 1, shortageNodes + 1);   % [S x D] 富余->短缺最短路（km）
    spDepotD = spDist(shortageNodes + 1, 1);              % [D x 1] 短缺->depot
    pdFinite = isfinite(spPD);                            % [S x D]

    sumVT = sum(state.vehicle_time);
    % 各车“去掉自身时间后的最大值”，用于合成 makespan = max(otherMax, tkNew)。
    [maxVT, argMaxVT] = max(state.vehicle_time);
    secondMaxVT = max(state.vehicle_time([1:argMaxVT-1, argMaxVT+1:end]));
    if isempty(secondMaxVT); secondMaxVT = 0; end

    bestObj = inf;
    bestMove = [];
    % 仅 20 辆车，外层按当前最空闲车辆优先以贴近原贪心选择顺序。
    [~, vehicleOrder] = sort(state.vehicle_time, "ascend");
    for kk = reshape(vehicleOrder, 1, [])
        cap = data.capacity(kk);
        spd = data.speed(kk);
        qtyKK = min(qtySupDem, cap);                      % [S x D] 计入车容
        if returnToDepot && ~isempty(state.routes{kk})
            lastNode = state.routes{kk}(end, 2) + 1;
        else
            lastNode = 1;   % 空路线从 depot 出发
        end
        % 旧返场段（缓存的 vehicle_time 含此段，需先扣除）。
        if returnToDepot && lastNode ~= 1
            oldReturn = 60 * spDist(lastNode, 1) / spd;
        else
            oldReturn = 0;
        end
        baseVT = state.vehicle_time(kk) - oldReturn;

        leg1 = 60 * spDist(lastNode, surplusNodes + 1).' / spd;   % [S x 1] 末点->富余
        if returnToDepot
            legRet = 60 * spDepotD / spd;                          % [D x 1] 短缺->depot
        else
            legRet = zeros(numel(shortageNodes), 1);
        end
        loadUnload = (data.load_time(kk) + data.unload_time(kk)) * qtyKK;   % [S x D]

        % 追加后的路线时间 [S x D]（leg1 沿行广播，legRet 沿列广播）。
        tkNew = baseVT + 2 * data.fixed_stop_time(kk) + leg1 + (60 / spd) * spPD ...
            + legRet.' + loadUnload;

        % 可行性：有量、各段可达、不超时。
        feasible = (qtyKK > 0) & pdFinite & isfinite(leg1) & isfinite(legRet).' ...
            & (tkNew <= data.max_route_time(kk) + 1.0e-8);
        if ~any(feasible(:))
            continue;
        end

        % 目标合成（与 evalFromCache 的目标公式一致）。
        otherMax = max(secondMaxVT * (argMaxVT == kk) + maxVT * (argMaxVT ~= kk), 0);
        makespan = max(otherMax, tkNew);
        totalTime = (sumVT - state.vehicle_time(kk)) + tkNew;
        unmetPenalty = state.unmet_penalty - (betaD.') .* qtyKK;   % [S x D]
        servedTotal = state.served_total + qtyKK;
        shortfall = max(0, targetServed - servedTotal);

        obj = cfg.alpha_makespan * makespan + cfg.gamma_total_time * totalTime + unmetPenalty;
        if serviceConstraint
            obj = obj + 100 * maxBeta * shortfall;
        end
        obj(~feasible) = inf;

        [objMin, lin] = min(obj(:));
        if objMin < bestObj - 1.0e-12
            [siIdx, djIdx] = ind2sub(size(obj), lin);
            bestObj = objMin;
            bestMove = struct("kk", kk, "si", surplusNodes(siIdx), ...
                "dj", shortageNodes(djIdx), "qty", qtyKK(siIdx, djIdx), ...
                "tk", tkNew(siIdx, djIdx));
        end
    end

    servedEnough = state.served_total >= targetServed;
    improvesObjective = bestObj < currentObj - 1.0e-8;
    if isempty(bestMove) || (~improvesObjective && (servedEnough || ~cfg.heuristic.allow_unserved_after_target))
        break;
    end

    % 落地最优移动并更新缓存。
    state = applyTaskToVehicle(state, data, bestMove.kk, bestMove.si, bestMove.dj, bestMove.qty, bestMove.tk);
    taskCount = taskCount + 1;
end

info = struct("task_count", taskCount);
end

function [state, info] = flowConstruction(state, data, cfg, spDist, tasks)
%FLOWCONSTRUCTION 用最小费用流的分配结果（tasks，外部已求好）构造初始路线：
%   把每条调度任务按车容拆分、贪心塞进 makespan 增量最小且不超时的车辆。
%   塞不下的部分留在 remaining 池（served/unmet 已由本函数同步），供 SA 的 add-task 邻域补救。
%   注意：在细网格上 flow 会把需求拆成大量小任务，装卸停靠开销大、装车数少于贪心，
%   故仅作可选构造；默认初解用 greedyConstruction。
returnToDepot = cfg.return_to_depot;

chunkSize = max(1, min(data.capacity));   % 拆分粒度：取最小车容，保证每块都能塞进任一车
taskCount = 0;

for r = 1:size(tasks, 1)
    si = tasks(r, 1);
    dj = tasks(r, 2);
    remainQty = tasks(r, 3);
    while remainQty > 0
        qty = min(remainQty, chunkSize);
        % 该块可用量受 remaining 限制（拆分后仍需逐块校验）。
        qty = min([qty, state.remaining_surplus(si), state.remaining_shortage(dj)]);
        if qty <= 0
            break;
        end

        % 选 makespan 增量最小且不超时的车辆，末尾追加该块。
        bestKK = 0;
        bestMakespan = inf;
        bestTk = inf;
        for kk = 1:data.k
            if qty > data.capacity(kk) + 1.0e-8
                continue;
            end
            newRoute = [state.routes{kk}; si, dj, qty];
            [tk, okTk] = routeTime(newRoute, kk, data, spDist, returnToDepot);
            if ~okTk || tk > data.max_route_time(kk) + 1.0e-8
                continue;
            end
            vt = state.vehicle_time;
            vt(kk) = tk;
            mk = max(vt);
            if mk < bestMakespan - 1.0e-9 || (abs(mk - bestMakespan) <= 1.0e-9 && tk < bestTk)
                bestMakespan = mk;
                bestKK = kk;
                bestTk = tk;
            end
        end

        if bestKK == 0
            break;   % 该 (si,dj) 当前块塞不下任何车，留作 remaining
        end
        state = applyTaskToVehicle(state, data, bestKK, si, dj, qty, bestTk);
        taskCount = taskCount + 1;
        remainQty = remainQty - qty;
    end
end

info = struct("task_count", taskCount);
end

function [candidate, changedK] = makeNeighbor(state, data, addWeight)
%MAKENEIGHBOR 随机生成一个邻域解，并返回受影响的车辆编号集合 changedK。
%   relocate/swap/reverse/intra-relocate（case 1-4）只重排已有任务，不改变装卸量，
%   served/unmet/remaining 保持不变，仅被改动车辆的路线时间需要重算。
%   add-task（case 5）从 remaining 池新增调度任务，改变 served/unmet（故同步相关缓存）；
%   路线是否超时由调用方的 refreshChangedVehicles 重算校验，超时则该候选被拒。
candidate = state;
changedK = [];

% 以 addWeight 概率尝试 add-task，否则在四种重排邻域中随机选一。
if addWeight > 0 && rand() < addWeight
    moveType = 5;
else
    moveType = randi(4);
end

if moveType == 5
    siList = find(state.remaining_surplus > 0);
    djList = find(state.remaining_shortage > 0);
    if isempty(siList) || isempty(djList)
        return;
    end
    si = siList(randi(numel(siList)));
    dj = djList(randi(numel(djList)));
    k = randi(data.k);
    qty = min([state.remaining_surplus(si), state.remaining_shortage(dj), data.capacity(k)]);
    if qty <= 0
        return;
    end
    % 追加任务到车 k 末尾并同步装卸量缓存（路线时间/可行性交给 refreshChangedVehicles）。
    candidate.routes{k} = [candidate.routes{k}; si, dj, qty];
    candidate.remaining_surplus(si) = candidate.remaining_surplus(si) - qty;
    candidate.remaining_shortage(dj) = candidate.remaining_shortage(dj) - qty;
    candidate.served(dj) = candidate.served(dj) + qty;
    candidate.unmet(dj) = candidate.remaining_shortage(dj);
    candidate.served_total = candidate.served_total + qty;
    candidate.unmet_penalty = candidate.unmet_penalty - data.beta(dj) * qty;
    changedK = k;
    return;
end

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
        changedK = unique([fromK, toK]);

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
        changedK = unique([k1, k2]);

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
            changedK = k;
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
            changedK = k;
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

function [obj, parts, state] = evaluateStateFull(state, data, cfg, spDist, enforceServiceLevel)
%EVALUATESTATEFULL 全量重算所有车辆路线时间并刷新缓存，按原目标函数评价方案。
%   仅在初始化和末尾兜底校验时调用；返回更新了缓存字段的 state。
if nargin < 5
    enforceServiceLevel = false;
end
vehicleTime = zeros(data.k, 1);
feasibleVec = true(data.k, 1);
feasible = true;

for kk = 1:data.k
    [t, ok] = routeTime(state.routes{kk}, kk, data, spDist, cfg.return_to_depot);
    okHere = ok && t <= data.max_route_time(kk) + 1.0e-8;
    feasibleVec(kk) = okHere;
    if ~okHere
        feasible = false;
    else
        vehicleTime(kk) = t;
    end
end

% 刷新缓存（即便不可行也写入，便于增量逻辑一致）。
state.vehicle_time = vehicleTime;
state.feasible = feasibleVec;
state.served_total = sum(state.served);
state.unmet_penalty = data.beta' * state.unmet;

if ~feasible
    obj = inf;
    parts = [];
    return;
end

[obj, parts] = evalFromCache(state, data, cfg, enforceServiceLevel);
end

function [obj, parts] = evalFromCache(state, data, cfg, enforceServiceLevel)
%EVALFROMCACHE 只用缓存字段合成目标值，O(K)。
%   依赖 state.vehicle_time / feasible / served_total / unmet_penalty 已正确维护。
if nargin < 4
    enforceServiceLevel = false;
end
if ~all(state.feasible)
    obj = inf;
    parts = [];
    return;
end

requiredServed = cfg.service_level_required * min(sum(data.shortage), sum(data.surplus));
serviceShortfall = max(0, requiredServed - state.served_total);

unmetPenalty = state.unmet_penalty;
makespan = max(state.vehicle_time);
totalTime = sum(state.vehicle_time);
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
parts = struct("vehicle_time", state.vehicle_time, "makespan", makespan, ...
    "total_time", totalTime, "unmet", state.unmet, "served", state.served, ...
    "unmet_penalty", unmetPenalty, "service_shortfall", serviceShortfall, ...
    "service_penalty", servicePenalty);
end

function state = refreshChangedVehicles(state, changedK, data, cfg, spDist)
%REFRESHCHANGEDVEHICLES 仅重算受邻域操作影响车辆的路线时间与可行标志，更新缓存。
for kk = reshape(changedK, 1, [])
    [t, ok] = routeTime(state.routes{kk}, kk, data, spDist, cfg.return_to_depot);
    okHere = ok && t <= data.max_route_time(kk) + 1.0e-8;
    state.feasible(kk) = okHere;
    if okHere
        state.vehicle_time(kk) = t;
    else
        state.vehicle_time(kk) = inf;
    end
end
end

function state = applyTaskToVehicle(state, data, kk, si, dj, qty, tkNew)
%APPLYTASKTOVEHICLE 将任务 (si->dj, qty) 追加到车辆 kk 末尾，并同步全部缓存。
%   tkNew 为预先算好的该车新路线时间（避免重复计算）。
state.routes{kk} = [state.routes{kk}; si, dj, qty];
state.remaining_surplus(si) = state.remaining_surplus(si) - qty;
state.remaining_shortage(dj) = state.remaining_shortage(dj) - qty;
state.served(dj) = state.served(dj) + qty;
state.unmet(dj) = state.remaining_shortage(dj);
state.vehicle_time(kk) = tkNew;
state.feasible(kk) = true;
state.served_total = state.served_total + qty;
state.unmet_penalty = state.unmet_penalty - data.beta(dj) * qty;
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
