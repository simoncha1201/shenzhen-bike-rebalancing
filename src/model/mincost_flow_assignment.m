function [tasks, flowInfo] = mincost_flow_assignment(data, spDist, cfg)
%MINCOST_FLOW_ASSIGNMENT 用最小费用流求解"从哪个富余点调多少辆到哪个短缺点"。
%
% 第一阶段任务量分配（忽略路线时间，只看调度量与距离 + 未满足惩罚）：
%   min  sum_{i,j} c_ij * w_ij + sum_j beta_j * unmet_j
%   s.t. sum_j w_ij <= surplus_i;  sum_i w_ij + unmet_j = shortage_j;  w,unmet >= 0
%
% 等价最小费用流（超源 S、超汇 T）：
%   S -> i      (富余点)：cap = surplus_i,  cost = 0
%   i -> j      (可达点对)：cap = inf,       cost = c_ij
%   S -> j      (虚拟未满足弧)：cap = shortage_j, cost = beta_j（流量即 unmet_j）
%   j -> T      (短缺点)：cap = shortage_j, cost = 0
% 要求总流量 = sum(shortage_j)，虚拟弧保证总能满流。
%
% 自写求解：Successive Shortest Path + Johnson 势函数 + O(V^2) Dijkstra。
% 所有弧费用 >= 0，初始势全 0，首轮起即可纯 Dijkstra。供需整数 => 流量自动整数。
%
% 输出：
%   tasks    M×3 = [surplusNodeIdx, shortageNodeIdx, qty]（qty>0，已按整数瓶颈增广）
%   flowInfo struct(total_served, total_unmet, flow_cost, augment_count, runtime_seconds,
%                   unmet_by_node)

arguments
    data struct
    spDist double
    cfg struct
end

tStart = tic;
tol = getfielddef(cfg.heuristic, "flow_tol", 1.0e-9);
maxAugment = getfielddef(cfg.heuristic, "flow_max_augment", 5000);
costMetric = getfielddef(cfg.heuristic, "flow_cost_metric", "distance");

net = buildFlowNetwork(data, spDist, cfg, costMetric);
net.display = getfielddef(cfg.solver, "display", false);

if net.requiredFlow <= 0
    tasks = zeros(0, 3);
    flowInfo = struct("total_served", 0, "total_unmet", 0, "flow_cost", 0, ...
        "augment_count", 0, "runtime_seconds", toc(tStart), ...
        "unmet_by_node", zeros(data.n, 1));
    return;
end

[flowOnArc, augCount] = sspMinCostFlow(net, net.requiredFlow, tol, maxAugment);

[tasks, totalServed, totalUnmet, flowCost, unmetByNode] = extractTasks(net, flowOnArc, data);

flowInfo = struct();
flowInfo.total_served = totalServed;
flowInfo.total_unmet = totalUnmet;
flowInfo.flow_cost = flowCost;
flowInfo.augment_count = augCount;
flowInfo.runtime_seconds = toc(tStart);
flowInfo.unmet_by_node = unmetByNode;
end

% ====================================================================== %

function net = buildFlowNetwork(data, spDist, cfg, costMetric)
%BUILDFLOWNETWORK 装配残量网络弧表。节点编号：1=S(超源)，2=T(超汇)，
% 之后 3..(2+n) 对应服务网格 1..n（既可能是富余点也可能是短缺点）。
n = data.n;
S = 1;
T = 2;
nodeOf = @(i) i + 2;     % 服务网格 i -> 流网络节点编号

surplus = round(double(data.surplus(:)));
shortage = round(double(data.shortage(:)));
beta = double(data.beta(:));

% 弧费用与真实目标一致：服务一辆车的路费 ≈ gamma * 行驶时间(min) = gamma * 60*d/平均车速；
% 未满足一辆车的惩罚 = beta(约25)。因 gamma*时间(每辆约 1~3) << beta，最小费用流会
% 自然"先尽量服务、再就近分配"，只把供给不足时真正无法服务的部分留作未满足。
% 该 distScale 同时让 flow_cost 成为真实目标中（路费项 + 未满足惩罚项）的一个下界参照。
avgSpeed = mean(double(data.speed));
gamma = getfielddef(cfg, "gamma_total_time", 0.08);
if costMetric == "time"
    distScale = gamma * 60 / max(avgSpeed, 1e-6);   % km -> gamma 加权的分钟成本
else
    % 纯距离度量：仍按车速折算，保证服务成本远小于 beta（serve-first），距离用于排序。
    distScale = gamma * 60 / max(avgSpeed, 1e-6);
end

surplusIdx = find(surplus > 0);
shortageIdx = find(shortage > 0);
nS = numel(surplusIdx);
nD = numel(shortageIdx);

% --- S -> i（富余）---
sFrom = S * ones(nS, 1);
sTo   = surplusIdx + 2;
sCap  = surplus(surplusIdx);
sCost = zeros(nS, 1);
sMeta = [ones(nS, 1), surplusIdx];

% --- i -> j（可达富余->短缺点对，向量化构造 + K 近邻稀疏化）---
% 因 beta >> 距离费用，最优分配只会用到"较近"的供需配对；对每个短缺点 j 只保留
% 其最近的 K 个富余点，可大幅压缩弧数(约 240×240 -> 240×K)，显著加速 Dijkstra
% 与增广。虚拟未满足弧仍保证可行，不会因稀疏化而不可行。
[A, B] = meshgrid(surplusIdx, shortageIdx);   % nD×nS
A = A(:); B = B(:);
lin = sub2ind(size(spDist), A + 1, B + 1);    % spDist 中 depot=1，服务网格 i 在 i+1
dAB = spDist(lin);
keep = isfinite(dAB) & (A ~= B);
A = A(keep); B = B(keep); dAB = dAB(keep);

K = round(getfielddef(cfg.heuristic, "flow_max_pairs_per_node", 12));
if isfinite(K) && K > 0 && ~isempty(B)
    % 对每个短缺点 j，按距离升序保留最近 K 个富余点。
    [~, ord] = sortrows([B, dAB], [1, 2]);
    A = A(ord); B = B(ord); dAB = dAB(ord);
    isNewGroup = [true; diff(B) ~= 0];
    grpStart = find(isNewGroup);
    rankInGrp = (1:numel(B))' - grpStart(cumsum(isNewGroup)) + 1;
    sel = rankInGrp <= K;
    A = A(sel); B = B(sel); dAB = dAB(sel);
end

ijFrom = A + 2;
ijTo   = B + 2;
ijCap  = min(surplus(A), shortage(B));
ijCost = dAB * distScale;
ijMeta = [2 * ones(numel(A), 1), B];

% --- S -> j（虚拟未满足弧，流量=unmet_j，费用=beta_j）---
vFrom = S * ones(nD, 1);
vTo   = shortageIdx + 2;
vCap  = shortage(shortageIdx);
vCost = beta(shortageIdx);
vMeta = [3 * ones(nD, 1), shortageIdx];

% --- j -> T（短缺需求）---
tFrom = shortageIdx + 2;
tTo   = T * ones(nD, 1);
tCap  = shortage(shortageIdx);
tCost = zeros(nD, 1);
tMeta = [4 * ones(nD, 1), shortageIdx];

from    = [sFrom; ijFrom; vFrom; tFrom];
to      = [sTo;   ijTo;   vTo;   tTo];
cap     = [sCap;  ijCap;  vCap;  tCap];
cost    = [sCost; ijCost; vCost; tCost];
arcMeta = [sMeta; ijMeta; vMeta; tMeta];

net = struct();
net.S = S;
net.T = T;
net.numNodes = n + 2;
net.from = from;
net.to = to;
net.cap = cap;
net.cost = cost;
net.arcMeta = arcMeta;
net.numArcs = numel(from);
net.requiredFlow = sum(shortage);
net.nodeOf = nodeOf;
end

% ====================================================================== %

function [flowOnArc, augCount] = sspMinCostFlow(net, requiredFlow, tol, maxAugment)
%SSPMINCOSTFLOW Successive Shortest Path（最短增广路用 SPFA 求解）。
% 残量图用前向/反向弧对表示；每条原弧 e 的反向弧编号为 e+numArcs。
% 反向弧费用为负，故直接用 SPFA(队列式 Bellman-Ford) 在真实费用上求最短增广路，
% 不用 Johnson 势函数 + reduced-cost clamp —— 后者在势函数随供给弧饱和而失效时
% 会扭曲距离，把本可服务的供给错误地留作未满足。SPFA 原生支持负费用弧，
% 且最短路增广保证残量图无负环，正确性有保障。
nA = net.numArcs;
nV = net.numNodes;

% 残量图弧数组：原弧 1..nA，反向弧 nA+1..2nA
arcFrom = [net.from; net.to];
arcTo   = [net.to;   net.from];
arcCost = [net.cost; -net.cost];
arcCap  = [net.cap;  zeros(nA, 1)];
residual = arcCap;          % 当前残量
twin = [(nA+1:2*nA)'; (1:nA)'];   % 配对反向弧

% CSR 邻接结构：按起点排序弧，记录每个节点弧段的起止位置（避免 cell 逐元素增长）。
[sortedFrom, order] = sort(arcFrom);
adjArc = order;                      % 按起点排序后的弧编号
adjHead = ones(nV + 1, 1);           % adjHead(u)..adjHead(u+1)-1 为节点 u 的弧段
counts = accumarray(sortedFrom, 1, [nV, 1]);
adjHead(2:end) = cumsum(counts) + 1;

sent = 0;
augCount = 0;
flowDisplay = isfield(net, "display") && net.display;
tLoop = tic;

while sent < requiredFlow - tol
    if augCount >= maxAugment
        break;
    end
    [dist, prevArc] = spfaResidual(net, adjArc, adjHead, arcTo, arcCost, residual, tol);
    if ~isfinite(dist(net.T))
        break;   % 无增广路（理论上不会发生，虚拟弧保证可达）
    end

    % 沿增广路找瓶颈
    bottleneck = requiredFlow - sent;
    v = net.T;
    guard = 0;
    while v ~= net.S
        e = prevArc(v);
        if e == 0
            error("mincost_flow:brokenPath", "增广路断裂：节点 %d 无入弧。", v);
        end
        bottleneck = min(bottleneck, residual(e));
        v = arcFrom(e);
        guard = guard + 1;
        if guard > nV + 1
            error("mincost_flow:cycle", "增广路出现环路，疑似数值问题。");
        end
    end

    % 推流
    v = net.T;
    while v ~= net.S
        e = prevArc(v);
        residual(e) = residual(e) - bottleneck;
        residual(twin(e)) = residual(twin(e)) + bottleneck;
        v = arcFrom(e);
    end

    sent = sent + bottleneck;
    augCount = augCount + 1;

    if flowDisplay && mod(augCount, 50) == 0
        fprintf("  最小费用流增广：第 %d 次，已送 %.0f/%.0f，用时 %.1f 秒\n", ...
            augCount, sent, requiredFlow, toc(tLoop));
    end
end

% 原弧实际流量 = 初始容量 - 残量
flowOnArc = net.cap - residual(1:nA);
end

% ====================================================================== %

function [dist, prevArc] = spfaResidual(net, adjArc, adjHead, arcTo, arcCost, residual, tol)
%SPFARESIDUAL 队列式 Bellman-Ford(SPFA)：在残量图上求 S 出发的最短路（含负费用反向弧）。
% 返回每节点最短距离与入弧。向量化松弛单个出队节点的全部可用出弧。
nV = net.numNodes;
dist = inf(nV, 1);
prevArc = zeros(nV, 1);
inQueue = false(nV, 1);
relaxCount = zeros(nV, 1);    % 每节点出队次数；超 nV 视为异常（理论无负环）

dist(net.S) = 0;
queue = zeros(max(64, 4 * nV), 1);   % 简单环形队列；不足时翻倍扩容
head = 1;
tail = 1;
queue(1) = net.S;
inQueue(net.S) = true;

while head <= tail
    u = queue(head);
    head = head + 1;
    inQueue(u) = false;
    relaxCount(u) = relaxCount(u) + 1;
    if relaxCount(u) > nV
        error("mincost_flow:negcycle", "SPFA 松弛超限，疑似负环或数值问题。");
    end

    seg = adjArc(adjHead(u):adjHead(u+1)-1);
    if isempty(seg)
        continue;
    end
    open = seg(residual(seg) > tol);
    if isempty(open)
        continue;
    end

    vs = arcTo(open);
    nd = dist(u) + arcCost(open);
    improve = nd < dist(vs) - tol;
    if ~any(improve)
        continue;
    end
    % 本网络单节点出弧目标互不相同，vimp 无重复，向量化赋值安全。
    vimp = vs(improve);
    dist(vimp) = nd(improve);
    prevArc(vimp) = open(improve);

    enq = vimp(~inQueue(vimp));
    for t = 1:numel(enq)
        vv = enq(t);
        tail = tail + 1;
        if tail > numel(queue)
            queue = [queue; zeros(numel(queue), 1)]; %#ok<AGROW>
        end
        queue(tail) = vv;
        inQueue(vv) = true;
    end
end
end

% ====================================================================== %

function [tasks, totalServed, totalUnmet, flowCost, unmetByNode] = extractTasks(net, flowOnArc, data)
%EXTRACTTASKS 从原弧流量中提取 i->j 调度任务，并统计满足/未满足/费用。
n = data.n;
tasks = zeros(0, 3);
totalServed = 0;
flowCost = 0;
unmetByNode = zeros(n, 1);

for e = 1:net.numArcs
    f = flowOnArc(e);
    if f <= 1e-9
        continue;
    end
    arcType = net.arcMeta(e, 1);
    flowCost = flowCost + f * net.cost(e);
    if arcType == 2
        % i -> j 真实调度任务
        i = net.from(e) - 2;
        j = net.to(e) - 2;
        tasks(end+1, :) = [i, j, round(f)]; %#ok<AGROW>
        totalServed = totalServed + f;
    elseif arcType == 3
        % S -> j 虚拟未满足
        j = net.arcMeta(e, 2);
        unmetByNode(j) = unmetByNode(j) + f;
    end
end
totalUnmet = sum(unmetByNode);
end

% ====================================================================== %

function v = getfielddef(s, name, def)
if isfield(s, name)
    v = s.(name);
else
    v = def;
end
end
