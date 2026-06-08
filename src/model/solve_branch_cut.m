function bc = solve_branch_cut(mdl, cfg, heuristicSol)
%SOLVE_BRANCH_CUT 带启发式初始上界的 Branch-and-Cut 精确验证算法。
%
% 说明：
%   1. 本函数不修改 solve.m，也不修改 solve_heuristic.m。
%   2. 内部 LP/MILP 节点求解仍调用已有自写 MILP 求解器 solve.m。
%   3. 本函数负责 Branch-and-Cut 外层逻辑：使用启发式解作为初始上界，
%      动态检查整数解中的子回路，并加入 SEC 子回路割。
%   4. 该方法用于小规模精确验证，不建议直接用于完整大规模实例。

arguments
    mdl struct
    cfg struct
    heuristicSol struct
end

tStart = tic;
heuristicFeasible = isfield(heuristicSol, "status") && ...
    (heuristicSol.status == "heuristic_feasible" || heuristicSol.status == "optimal");
bc = struct();
bc.status = "not_started";
if heuristicFeasible && isfinite(heuristicSol.objective)
    bc.incumbent_objective = heuristicSol.objective;
    bc.incumbent_source = "heuristic";
else
    bc.incumbent_objective = inf;
    bc.incumbent_source = "none";
end
bc.proven_optimal = false;
bc.cut_count = 0;
bc.cut_rounds = 0;
bc.runtime_seconds = 0;
bc.best_exact_solution = [];
bc.heuristic_objective = heuristicSol.objective;
bc.exact_objective = NaN;
bc.gap_percent = NaN;
bc.last_solver_status = "";
bc.last_nodes_explored = 0;
bc.last_best_bound = NaN;
bc.last_solver_gap = NaN;

work = mdl;
localCfg = cfg;
localCfg.solver.method = "milp";
localCfg.solver.display = cfg.solver.display;
localCfg.solver.max_seconds = min(cfg.solver.max_seconds, cfg.exact_validation.max_seconds);
localCfg.solver.max_branch_nodes = cfg.exact_validation.max_branch_nodes;
if isfield(cfg.exact_validation, "max_lp_rows")
    localCfg.solver.max_lp_rows = cfg.exact_validation.max_lp_rows;
end
if isfield(cfg.exact_validation, "max_lp_nonzeros")
    localCfg.solver.max_lp_nonzeros = cfg.exact_validation.max_lp_nonzeros;
end

if isfinite(bc.incumbent_objective)
    work = addObjectiveCut(work, bc.incumbent_objective - cfg.exact_validation.objective_epsilon);
end

for roundId = 1:cfg.exact_validation.max_cut_rounds
    remaining = cfg.exact_validation.max_seconds - toc(tStart);
    if remaining <= 0
        bc.status = "time_limit";
        break;
    end
    localCfg.solver.max_seconds = remaining;

    fprintf("Branch-and-Cut 第 %d 轮：已有割=%d，当前启发式上界=%.6f\n", ...
        roundId, bc.cut_count, bc.incumbent_objective);

    exactSol = solve(work, localCfg);
    bc.cut_rounds = roundId;
    bc.runtime_seconds = toc(tStart);
    bc.last_solver_status = exactSol.status;
    bc.last_nodes_explored = exactSol.nodes_explored;
    bc.last_best_bound = exactSol.best_bound;
    bc.last_solver_gap = exactSol.gap;

    if exactSol.status == "time_limit" || exactSol.status == "limit_reached"
        bc.status = "time_limit";
        break;
    elseif exactSol.status == "node_limit"
        bc.status = "node_limit";
        break;
    elseif exactSol.status == "lp_size_limit"
        bc.status = "lp_size_limit";
        break;
    elseif exactSol.status == "lp_iteration_limit"
        bc.status = "lp_iteration_limit";
        break;
    end

    if isempty(exactSol.x) || exactSol.status == "no_integer_solution"
        if isfinite(bc.incumbent_objective)
            bc.status = "heuristic_proven_optimal_for_validation";
            bc.proven_optimal = true;
            bc.exact_objective = bc.incumbent_objective;
            bc.gap_percent = 0;
        else
            bc.status = "no_integer_solution";
        end
        break;
    end

    cuts = findSubtourCuts(exactSol.x, work);
    if ~isempty(cuts)
        fprintf("  发现 %d 条子回路割，加入后继续求解。\n", numel(cuts));
        for i = 1:numel(cuts)
            work = addSubtourCut(work, cuts(i).vehicle, cuts(i).nodes);
            bc.cut_count = bc.cut_count + 1;
        end
        continue;
    end

    bc.best_exact_solution = exactSol;
    bc.exact_objective = exactSol.objective;
    if exactSol.objective < bc.incumbent_objective
        bc.incumbent_objective = exactSol.objective;
        bc.incumbent_source = "branch_cut";
        work = addObjectiveCut(work, exactSol.objective - cfg.exact_validation.objective_epsilon);
        fprintf("  找到更优整数解：%.6f，继续尝试证明没有更优解。\n", exactSol.objective);
        continue;
    end

    bc.status = "exact_solution_found";
    break;
end

if bc.status == "not_started"
    bc.status = "cut_round_limit";
end

if isfinite(bc.heuristic_objective) && isfinite(bc.exact_objective) && bc.exact_objective > 0
    bc.gap_percent = 100 * (bc.heuristic_objective - bc.exact_objective) / bc.exact_objective;
end
bc.runtime_seconds = toc(tStart);
end

function mdl = addObjectiveCut(mdl, upperBound)
%ADDOBJECTIVECUT 加入目标函数上界割：c'x <= upperBound。
if ~isfinite(upperBound)
    return;
end
mdl.Aineq = [mdl.Aineq; sparse(1, 1:numel(mdl.c), mdl.c(:)', 1, numel(mdl.c))];
mdl.bineq = [mdl.bineq; upperBound];
end

function cuts = findSubtourCuts(x, mdl)
%FINDSUBTOURCUTS 从整数解中寻找不含调度中心的服务节点子回路。
idx = mdl.index;
data = mdl.data;
cuts = struct("vehicle", {}, "nodes", {});

for kk = 1:data.k
    usedEdges = find(x(idx.x(:, kk)) > 0.5);
    if isempty(usedEdges)
        continue;
    end

    graphEdges = [data.edge_from(usedEdges), data.edge_to(usedEdges)];
    serviceNodes = unique(graphEdges(:));
    serviceNodes(serviceNodes == 1) = [];
    if isempty(serviceNodes)
        continue;
    end

    components = connectedComponentsUndirected(graphEdges, data.n + 1);
    for c = 1:numel(components)
        comp = components{c};
        if any(comp == 1)
            continue;
        end
        internalServiceNodes = comp(comp > 1) - 1;
        if numel(internalServiceNodes) >= 2
            cuts(end+1) = struct("vehicle", kk, "nodes", internalServiceNodes(:)); %#ok<AGROW>
        end
    end
end
end

function components = connectedComponentsUndirected(edges, nodeCount)
%CONNECTEDCOMPONENTSUNDIRECTED 计算无向连通分量。
adj = cell(nodeCount, 1);
for e = 1:size(edges, 1)
    i = edges(e, 1);
    j = edges(e, 2);
    adj{i}(end+1) = j;
    adj{j}(end+1) = i;
end

visited = false(nodeCount, 1);
components = {};
activeNodes = unique(edges(:));
for start = reshape(activeNodes, 1, [])
    if visited(start)
        continue;
    end
    queue = start;
    visited(start) = true;
    comp = [];
    while ~isempty(queue)
        v = queue(1);
        queue(1) = [];
        comp(end+1) = v; %#ok<AGROW>
        for nb = adj{v}
            if ~visited(nb)
                visited(nb) = true;
                queue(end+1) = nb; %#ok<AGROW>
            end
        end
    end
    components{end+1} = comp(:); %#ok<AGROW>
end
end

function mdl = addSubtourCut(mdl, vehicle, serviceNodes)
%ADDSUBTOURCUT 加入 SEC 子回路割：
% sum_{i in U, j in U} x_{ijk} <= |U|-1。
internalNodes = serviceNodes(:) + 1;
mask = ismember(mdl.data.edge_from, internalNodes) & ismember(mdl.data.edge_to, internalNodes);
edgeIds = find(mask);
if isempty(edgeIds)
    return;
end

vars = mdl.index.x(edgeIds, vehicle);
row = sparse(1, vars, 1, 1, numel(mdl.c));
mdl.Aineq = [mdl.Aineq; row];
mdl.bineq = [mdl.bineq; numel(serviceNodes) - 1];
end
