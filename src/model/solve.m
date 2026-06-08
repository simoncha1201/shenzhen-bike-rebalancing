function sol = solve(mdl, cfg)
%SOLVE 不调用 MATLAB 优化工具箱，自写求解器求解再平衡 MILP。
%
% 求解器采用自包含实现：
%   1. LP 松弛问题使用稀疏两阶段修正单纯形法求解。
%   2. 整数变量使用分支定界处理。
%
% 本文件不调用 linprog、intlinprog、optimproblem 或其他 MATLAB 优化工具箱求解器。
% 对较大规模 VRP，精确 MILP 仍可能计算困难；若达到时间或节点上限，
% 返回结果中的 proven_optimal 会被标记为 false。

arguments
    mdl struct
    cfg struct
end

opts = cfg.solver;
if ~isfield(opts, "simplex_display_interval")
    opts.simplex_display_interval = 500;
end
if ~isfield(opts, "remove_dependent_equalities")
    opts.remove_dependent_equalities = false;
end
if ~isfield(opts, "max_dense_rank_rows")
    opts.max_dense_rank_rows = 300;
end
if ~isfield(opts, "scale_rows")
    opts.scale_rows = true;
end
if ~isfield(opts, "max_lp_rows")
    opts.max_lp_rows = inf;
end
if ~isfield(opts, "max_lp_nonzeros")
    opts.max_lp_nonzeros = inf;
end

warnNear = warning("off", "MATLAB:nearlySingularMatrix");
warnSing = warning("off", "MATLAB:singularMatrix");
warnCleanup = onCleanup(@() restoreMatrixWarnings(warnNear, warnSing));

tStart = tic;

root = makeNode(mdl.lb, mdl.ub, 0);
stack = root;
bestX = [];
bestObj = inf;
bestBound = inf;
nodesExplored = 0;
status = "not_started";

initial = initialFeasibleSolution(mdl, opts);
if initial.feasible
    bestX = initial.x;
    bestObj = initial.obj;
    if opts.display
        fprintf("已构造初始可行解：目标值=%.6f\n", bestObj);
    end
end

while ~isempty(stack)
    if nodesExplored >= opts.max_branch_nodes
        status = "node_limit";
        break;
    elseif toc(tStart) >= opts.max_seconds
        status = "time_limit";
        break;
    end

    node = stack(end);
    stack(end) = [];
    nodesExplored = nodesExplored + 1;

    if opts.display
        fprintf("开始求解分支节点 %d：深度=%d，待搜索节点=%d，已用时=%.1f秒\n", ...
            nodesExplored, node.depth, numel(stack), toc(tStart));
    end

    lp = solveLpRelaxation(mdl, node.lb, node.ub, opts, tStart);
    if opts.display
        fprintf("分支节点 %d 的 LP 状态=%s", nodesExplored, lp.status);
        if isfield(lp, "obj") && isfinite(lp.obj)
            fprintf("，LP目标=%.6f", lp.obj);
        end
        fprintf("，已用时=%.1f秒\n", toc(tStart));
    end
    if lp.status == "infeasible"
        continue;
    elseif lp.status == "unbounded"
        status = "lp_unbounded";
        break;
    elseif lp.status == "time_limit"
        status = "time_limit";
        break;
    elseif lp.status == "iteration_limit"
        status = "lp_iteration_limit";
        break;
    elseif lp.status == "lp_size_limit"
        status = "lp_size_limit";
        break;
    elseif lp.status ~= "optimal"
        status = "lp_" + string(lp.status);
        break;
    end

    bestBound = min(bestBound, lp.obj);
    if lp.obj >= bestObj - opts.tol
        continue;
    end

    [isInt, branchVar] = checkIntegrality(lp.x, mdl.intcon, opts.integer_tol, opts.branch_rule);
    if isInt
        check = validateCandidate(lp.x, mdl, opts);
        if check.feasible && lp.obj < bestObj
            bestObj = lp.obj;
            bestX = lp.x;
            if opts.display
                fprintf("发现新的整数可行解：目标值=%.6f，分支节点=%d\n", bestObj, nodesExplored);
            end
        end
        continue;
    end

    value = lp.x(branchVar);
    floorValue = floor(value);
    ceilValue = ceil(value);

    left = node;
    left.ub(branchVar) = min(left.ub(branchVar), floorValue);
    left.depth = node.depth + 1;

    right = node;
    right.lb(branchVar) = max(right.lb(branchVar), ceilValue);
    right.depth = node.depth + 1;

    if left.lb(branchVar) <= left.ub(branchVar) + opts.tol
        stack(end+1) = left; %#ok<AGROW>
    end
    if right.lb(branchVar) <= right.ub(branchVar) + opts.tol
        stack(end+1) = right; %#ok<AGROW>
    end

    if opts.display && mod(nodesExplored, 100) == 0
        fprintf("分支定界进度：节点=%d，当前最好目标=%.6f，当前下界=%.6f，待搜索节点=%d\n", ...
            nodesExplored, bestObj, bestBound, numel(stack));
    end
end

if isempty(bestX)
    if status == "not_started"
        status = "no_integer_solution";
    end
    sol = struct("status", status, "x", [], "objective", inf, "proven_optimal", false, ...
        "nodes_explored", nodesExplored, "best_bound", bestBound, "gap", inf, ...
        "runtime_seconds", toc(tStart), "decoded", []);
    return;
end

if isempty(stack) && status == "not_started"
    status = "optimal";
end

gap = max(0, bestObj - bestBound);
sol = struct();
sol.status = status;
sol.x = bestX;
sol.objective = bestObj;
sol.proven_optimal = status == "optimal";
sol.nodes_explored = nodesExplored;
sol.best_bound = bestBound;
sol.gap = gap;
sol.runtime_seconds = toc(tStart);
sol.decoded = decodeSolution(bestX, mdl);
end

function initial = initialFeasibleSolution(mdl, opts)
%INITIALFEASIBLESOLUTION 构造“车辆不出车，全部短缺未满足”的初始解。
x = zeros(numel(mdl.c), 1);
if isfield(mdl.index, "unmet")
    x(mdl.index.unmet) = mdl.data.shortage;
end
check = validateCandidate(x, mdl, opts);
initial = struct();
initial.x = x;
initial.obj = mdl.c' * x;
initial.feasible = check.feasible;
end

function check = validateCandidate(x, mdl, opts)
%VALIDATECANDIDATE 使用原始模型矩阵严格检查候选解是否可行。
tol = max(1.0e-7, 10 * opts.tol);
ineqViolation = max([0; mdl.Aineq * x - mdl.bineq]);
eqViolation = max([0; abs(mdl.Aeq * x - mdl.beq)]);
lbViolation = max([0; mdl.lb - x]);
ubViolation = max([0; x - mdl.ub]);
intViolation = 0;
if ~isempty(mdl.intcon)
    intViolation = max(abs(x(mdl.intcon) - round(x(mdl.intcon))));
end
check = struct();
check.ineq_violation = ineqViolation;
check.eq_violation = eqViolation;
check.lb_violation = lbViolation;
check.ub_violation = ubViolation;
check.integer_violation = intViolation;
check.feasible = ineqViolation <= tol && eqViolation <= tol && ...
    lbViolation <= tol && ubViolation <= tol && intViolation <= opts.integer_tol;
end

function node = makeNode(lb, ub, depth)
node = struct("lb", lb(:), "ub", ub(:), "depth", depth);
end

function [isInt, branchVar] = checkIntegrality(x, intcon, tol, rule)
frac = abs(x(intcon) - round(x(intcon)));
[maxFrac, pos] = max(frac);
isInt = maxFrac <= tol;
if isInt
    branchVar = [];
    return;
end

if rule == "most_fractional"
    distanceToHalf = abs(frac - 0.5);
    candidates = find(frac > tol);
    [~, localPos] = min(distanceToHalf(candidates));
    branchVar = intcon(candidates(localPos));
else
    branchVar = intcon(pos);
end
end

function lp = solveLpRelaxation(mdl, lb, ub, opts, tStart)
[A, b, c, shift, baseObj, mapBack, ineqRowCount] = buildStandardLp(mdl, lb, ub, opts);
if isinf(baseObj)
    lp = struct("status", "infeasible", "x", [], "obj", inf);
    return;
end
if isempty(A)
    x = shift;
    lp = struct("status", "optimal", "x", x, "obj", mdl.c' * x);
    return;
end
if size(A, 1) > opts.max_lp_rows || nnz(A) > opts.max_lp_nonzeros
    lp = struct("status", "lp_size_limit", "x", [], "obj", inf);
    return;
end

if opts.display
    fprintf("  LP标准型规模：约束=%d，变量=%d，非零元=%d\n", size(A, 1), size(A, 2), nnz(A));
end
std = twoPhaseSimplex(A, b, c, ineqRowCount, opts, tStart);
if std.status ~= "optimal"
    lp = struct("status", std.status, "x", [], "obj", inf);
    return;
end

z = std.x(1:numel(mapBack));
x = shift;
x(mapBack) = shift(mapBack) + z;
lp = struct("status", "optimal", "x", x, "obj", std.obj + baseObj);
end

function [A, b, c, shift, baseObj, mapBack, ineqRowCount] = buildStandardLp(mdl, lb, ub, opts)
lb = lb(:);
ub = ub(:);
if any(lb > ub)
    [A, b, c, shift, baseObj, mapBack, ineqRowCount] = infeasibleStandardLp();
    return;
end
if any(isinf(lb) & lb < 0)
    error("自写求解器要求所有变量具有有限下界。");
end

mapBack = find(ub > lb);
shift = lb;
c = mdl.c(mapBack);
baseObj = mdl.c' * shift;

Aineq = mdl.Aineq(:, mapBack);
bineq = mdl.bineq - mdl.Aineq * shift;
Aeq = mdl.Aeq(:, mapBack);
beq = mdl.beq - mdl.Aeq * shift;

finiteUb = isfinite(ub(mapBack));
ubRows = speye(numel(mapBack));
ubRows = ubRows(finiteUb, :);
ubRhs = ub(mapBack(finiteUb)) - lb(mapBack(finiteUb));

Aineq = [Aineq; ubRows];
bineq = [bineq; ubRhs];

[Aineq, bineq, ok] = removeZeroIneqRows(Aineq, bineq);
if ~ok
    [A, b, c, shift, baseObj, mapBack, ineqRowCount] = infeasibleStandardLp();
    return;
end
[Aeq, beq, ok] = removeZeroEqRows(Aeq, beq);
if ~ok
    [A, b, c, shift, baseObj, mapBack, ineqRowCount] = infeasibleStandardLp();
    return;
end
if opts.remove_dependent_equalities
    [Aeq, beq, ok] = removeDependentEqualities(Aeq, beq, opts);
    if ~ok
        [A, b, c, shift, baseObj, mapBack, ineqRowCount] = infeasibleStandardLp();
        return;
    end
end
if opts.scale_rows
    [Aineq, bineq] = scaleConstraintRows(Aineq, bineq);
    [Aeq, beq] = scaleConstraintRows(Aeq, beq);
end

mIneq = size(Aineq, 1);
mEq = size(Aeq, 1);
ineqRowCount = mIneq;

A = [Aineq, speye(mIneq); Aeq, sparse(mEq, mIneq)];
b = [bineq; beq];
c = [c; zeros(mIneq, 1)];

% 删除几乎为零的约束行，并检查是否存在不一致的零行。
rowNorm = full(sum(abs(A), 2));
zeroRows = rowNorm < 1.0e-12;
if any(zeroRows & abs(b) > 1.0e-9)
    [A, b, c, shift, baseObj, mapBack, ineqRowCount] = infeasibleStandardLp();
    return;
end
removedIneqRows = nnz(zeroRows(1:ineqRowCount));
ineqRowCount = ineqRowCount - removedIneqRows;
A = A(~zeroRows, :);
b = b(~zeroRows);

% 为人工变量初始基构造非负右端项。
neg = b < 0;
A(neg, :) = -A(neg, :);
b(neg) = -b(neg);
end

function [A, b, c, shift, baseObj, mapBack, ineqRowCount] = infeasibleStandardLp()
%INFEASIBLESTANDARDLP 构造表示 LP 松弛不可行的标准返回值。
A = [];
b = [];
c = [];
shift = [];
baseObj = inf;
mapBack = [];
ineqRowCount = 0;
end

function [A, b, ok] = removeZeroIneqRows(A, b)
% 删除 0 <= b 的冗余不等式；若 b < 0，则该 LP 松弛不可行。
ok = true;
rowNorm = full(sum(abs(A), 2));
zeroRows = rowNorm < 1.0e-12;
if any(zeroRows & b < -1.0e-9)
    ok = false;
    return;
end
A = A(~zeroRows, :);
b = b(~zeroRows);
end

function [A, b, ok] = removeZeroEqRows(A, b)
% 删除 0 = 0 的冗余等式；若 0 = b 且 b 非零，则该 LP 松弛不可行。
ok = true;
rowNorm = full(sum(abs(A), 2));
zeroRows = rowNorm < 1.0e-12;
if any(zeroRows & abs(b) > 1.0e-9)
    ok = false;
    return;
end
A = A(~zeroRows, :);
b = b(~zeroRows);
end

function [A, b, ok] = removeDependentEqualities(A, b, opts)
% 用秩揭示 QR 删除线性相关等式，减少人工变量退基时的病态基。
ok = true;
m = size(A, 1);
if m <= 1 || m > opts.max_dense_rank_rows
    return;
end

denseA = full(A);
tolRank = 1.0e-10 * max(1, max(size(denseA))) * max(1, norm(denseA, 1));
[~, rA, pivA] = qr(denseA', "vector");
rankA = sum(abs(diag(rA)) > tolRank);

aug = [denseA, b(:)];
tolAug = 1.0e-10 * max(1, max(size(aug))) * max(1, norm(aug, 1));
[~, rAug] = qr(aug', 0);
rankAug = sum(abs(diag(rAug)) > tolAug);
if rankAug > rankA
    ok = false;
    return;
end

if rankA < m
    keepRows = sort(pivA(1:rankA));
    A = A(keepRows, :);
    b = b(keepRows);
end
end

function [A, b] = scaleConstraintRows(A, b)
% 将每行最大系数缩放到 1 附近，降低 Big-M 和时间系数造成的尺度差异。
if isempty(A)
    return;
end
rowScale = full(max(abs(A), [], 2));
rowScale(rowScale < 1.0) = 1.0;
A = spdiags(1 ./ rowScale, 0, size(A, 1), size(A, 1)) * A;
b = b ./ rowScale;
end

function out = twoPhaseSimplex(A, b, c, ineqRowCount, opts, tStart)
tol = opts.tol;
m = size(A, 1);
n = size(A, 2);
if any(b < -tol)
    out = struct("status", "infeasible", "x", [], "obj", inf);
    return;
end

mEq = m - ineqRowCount;
if mEq < 0
    error("标准型中不等式行数记录错误。");
end

if mEq == 0
    basis = (n - ineqRowCount + 1:n)';
    phase2 = revisedSimplex(A, b, c, basis, tol, 50000, "第二阶段", opts, tStart);
    out = phase2;
    return;
end

artificial = [sparse(ineqRowCount, mEq); speye(mEq)];
A1 = [A, artificial];
c1 = [zeros(n, 1); ones(mEq, 1)];
slackBasis = (n - ineqRowCount + 1:n)';
artificialBasis = (n+1:n+mEq)';
basis = [slackBasis; artificialBasis];

if opts.display
    fprintf("  进入第一阶段单纯形：原变量=%d，人工变量=%d\n", n, m);
end
phase1 = revisedSimplex(A1, b, c1, basis, tol, 20000, "第一阶段", opts, tStart);
if phase1.status ~= "optimal"
    out = phase1;
    return;
end
if phase1.obj > 1.0e-7
    out = struct("status", "infeasible", "x", [], "obj", inf);
    return;
end
if opts.display
    fprintf("  第一阶段完成：人工变量目标=%.6g\n", phase1.obj);
end

[A2, b2, basis2, ok] = removeArtificialBasis(A1, b, phase1.basis, n, tol);
if ~ok
    out = struct("status", "infeasible", "x", [], "obj", inf);
    return;
end

if opts.display
    fprintf("  进入第二阶段单纯形：约束=%d，变量=%d\n", size(A2, 1), size(A2, 2));
end
phase2 = revisedSimplex(A2, b2, c, basis2, tol, 50000, "第二阶段", opts, tStart);
if phase2.status ~= "optimal"
    out = phase2;
    return;
end

out = phase2;
end

function [A2, b2, basis, ok] = removeArtificialBasis(A1, b, basis, nOriginal, tol)
ok = true;
rowsToKeep = true(size(b));

while any(basis > nOriginal)
    artRows = find(basis > nOriginal);
    progressed = false;
    B = A1(:, basis);
    BinvA = basisSolve(B, A1(:, 1:nOriginal));
    currentBasis = basis(basis <= nOriginal);

    for r = artRows(:)'
        candidates = setdiff(1:nOriginal, currentBasis);
        coeff = abs(BinvA(r, candidates));
        [bestCoeff, pos] = max(coeff);
        if ~isempty(pos) && bestCoeff > tol
            basis(r) = candidates(pos);
            progressed = true;
            break;
        else
            rowsToKeep(r) = false;
            progressed = true;
            break;
        end
    end

    if ~progressed
        ok = false;
        return;
    end

    if any(~rowsToKeep)
        A1 = A1(rowsToKeep, :);
        b = b(rowsToKeep);
        basis = basis(rowsToKeep);
        rowsToKeep = true(size(b));
    end
end

A2 = A1(:, 1:nOriginal);
b2 = b;
end

function out = revisedSimplex(A, b, c, basis, tol, maxIter, stageName, opts, tStart)
m = size(A, 1);
n = size(A, 2);
basis = basis(:);

for iter = 1:maxIter
    if opts.display && mod(iter, opts.simplex_display_interval) == 0
        fprintf("    %s迭代=%d，基规模=%d，变量=%d，已用时=%.1f秒\n", ...
            stageName, iter, m, n, toc(tStart));
    end
    if toc(tStart) >= opts.max_seconds
        out = struct("status", "time_limit", "x", [], "obj", inf, "basis", basis);
        return;
    end

    B = A(:, basis);
    xB = basisSolve(B, b);
    if any(xB < -1.0e-7)
        out = struct("status", "infeasible", "x", [], "obj", inf, "basis", basis);
        return;
    end

    y = basisSolve(B', c(basis));
    rc = c - A' * y;
    rc(basis) = 0;
    [minRc, entering] = min(rc);

    if minRc >= -tol
        x = zeros(n, 1);
        x(basis) = max(0, xB);
        out = struct("status", "optimal", "x", x, "obj", c' * x, "basis", basis);
        return;
    end

    d = basisSolve(B, A(:, entering));
    positive = d > tol;
    if ~any(positive)
        out = struct("status", "unbounded", "x", [], "obj", -inf, "basis", basis);
        return;
    end

    ratio = inf(m, 1);
    ratio(positive) = xB(positive) ./ d(positive);
    minRatio = min(ratio);
    leavingCandidates = find(abs(ratio - minRatio) <= 1.0e-10);
    [~, blandPos] = min(basis(leavingCandidates));
    leavingRow = leavingCandidates(blandPos);
    basis(leavingRow) = entering;
end

out = struct("status", "iteration_limit", "x", [], "obj", inf, "basis", basis);
end

function x = basisSolve(B, rhs)
% 基矩阵求解的统一入口：避免 MATLAB 在退化基上反复刷屏。
x = B \ rhs;
if any(~isfinite(x(:))) && size(B, 1) <= 1500
    x = lsqminnorm(full(B), full(rhs));
end
end

function restoreMatrixWarnings(stateNear, stateSing)
warning(stateNear);
warning(stateSing);
end

function decoded = decodeSolution(x, mdl)
idx = mdl.index;
data = mdl.data;
n = data.n;
k = data.k;
nodeLabels = ["DEPOT"; data.node_ids(:)];

routeRows = {};
actionRows = {};
shortageRows = {};

for kk = 1:k
    for e = 1:data.edge_count
        if x(idx.x(e, kk)) > 0.5
            i = data.edge_from(e);
            j = data.edge_to(e);
            routeRows(end+1, :) = {data.vehicle_ids(kk), nodeLabels(i), nodeLabels(j), ...
                data.edge_dist_km(e), 60 * data.edge_dist_km(e) / data.speed(kk)}; %#ok<AGROW>
        end
    end
    for i = 1:n
        pickup = x(idx.p(i, kk));
        dropoff = x(idx.q(i, kk));
        if pickup > 1.0e-6 || dropoff > 1.0e-6
            actionRows(end+1, :) = {data.vehicle_ids(kk), data.node_ids(i), pickup, dropoff}; %#ok<AGROW>
        end
    end
end

for i = 1:n
    shortageRows(end+1, :) = {data.node_ids(i), data.shortage(i), x(idx.unmet(i)), ...
        data.shortage(i) - x(idx.unmet(i)), data.surplus(i)}; %#ok<AGROW>
end

decoded = struct();
decoded.routes = makeTable(routeRows, ["vehicle_id","from_grid_id","to_grid_id","distance_km","travel_time_min"]);
decoded.actions = makeTable(actionRows, ["vehicle_id","grid_id","pickup_bikes","dropoff_bikes"]);
decoded.shortage = makeTable(shortageRows, ["grid_id","shortage_bikes","unmet_bikes","served_bikes","surplus_bikes"]);
decoded.vehicle_time = table(data.vehicle_ids(:), x(idx.tk(:)), VariableNames=["vehicle_id","route_time_min"]);
decoded.objective_parts = table(x(idx.t), sum(x(idx.tk(:))), sum(x(idx.unmet(:))), ...
    VariableNames=["makespan_min","total_vehicle_time_min","total_unmet_bikes"]);
decoded.node_copies = makeNodeCopyTable(data);
end

function tbl = makeNodeCopyTable(data)
tbl = table(data.node_ids(:), data.original_node_ids(:), data.visit_copy_index(:), ...
    data.visit_copy_count(:), data.shortage(:), data.surplus(:), ...
    VariableNames=["grid_id","original_grid_id","visit_copy_index", ...
    "visit_copy_count","shortage_bikes","surplus_bikes"]);
end

function tbl = makeTable(rows, names)
%MAKETABLE 将解码结果单元格转换为表；若为空，则返回带列名的空表。
if isempty(rows)
    tbl = array2table(zeros(0, numel(names)), VariableNames=names);
else
    tbl = cell2table(rows, VariableNames=names);
end
end
