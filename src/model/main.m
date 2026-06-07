function main()
%MAIN 共享单车再平衡模型主入口。
%
% 运行流程：
%   1. 读取 prama.m 中的模型参数；
%   2. 根据指定网格和场景生成 MILP 数学模型；
%   3. 调用 solve.m 中的自写线性/整数规划求解器；
%   4. 保存路线、装卸、短缺满足和车辆时间结果，供后续可视化使用。

thisDir = fileparts(mfilename("fullpath"));
addpath(thisDir);

cfg = prama();
if ~isfolder(cfg.output_dir)
    mkdir(cfg.output_dir);
end

fprintf("正在生成模型：网格=%dm，场景=%s\n", cfg.grid_size_m, cfg.scenario_id);
fprintf("参数摘要：max_service_nodes=%d，max_vehicles_to_use=%d，服务水平=%.2f，求解时限=%d秒，节点上限=%d\n", ...
    cfg.max_service_nodes, cfg.max_vehicles_to_use, cfg.service_level_required, ...
    cfg.solver.max_seconds, cfg.solver.max_branch_nodes);
mdl = model(cfg);

fprintf("模型规模：变量=%d，整数变量=%d，不等式=%d，等式=%d\n", ...
    numel(mdl.c), numel(mdl.intcon), size(mdl.Aineq, 1), size(mdl.Aeq, 1));
fprintf("数据规模：服务网格=%d，车辆=%d，总短缺=%.0f，总富余=%.0f，车辆单趟总容量=%.0f\n", ...
    mdl.data.n, mdl.data.k, sum(mdl.data.shortage), sum(mdl.data.surplus), sum(mdl.data.capacity));
fprintf("服务水平约束：要求满足 %.1f%% × min(总短缺,总富余)=%.1f 辆，允许未满足最多 %.1f 辆\n", ...
    100 * cfg.service_level_required, cfg.service_level_required * min(sum(mdl.data.shortage), sum(mdl.data.surplus)), ...
    sum(mdl.data.shortage) - cfg.service_level_required * min(sum(mdl.data.shortage), sum(mdl.data.surplus)));
fprintf("邻接图规模：稀疏边=%d，若全联通则约为=%d，边数压缩比例=%.2f%%\n", ...
    mdl.data.edge_count, (mdl.data.n + 1) * mdl.data.n, ...
    100 * mdl.data.edge_count / max(1, (mdl.data.n + 1) * mdl.data.n));
fprintf("目标权重：alpha=%.4g，gamma=%.4g，beta均值=%.4g\n", ...
    cfg.alpha_makespan, cfg.gamma_total_time, mean(mdl.data.beta));
printTopNodes(mdl);

fprintf("开始求解。当前方法=%s，不调用 MATLAB 内置优化工具箱。\n", cfg.solver.method);
if cfg.solver.method == "heuristic"
    sol = solve_heuristic(mdl, cfg);
elseif cfg.solver.method == "milp"
    sol = solve(mdl, cfg);
else
    error("未知求解方法：%s。可选值为 heuristic 或 milp。", cfg.solver.method);
end

fprintf("求解状态：%s\n", sol.status);
fprintf("目标函数值：%.6f\n", sol.objective);
fprintf("是否已证明最优：%d\n", sol.proven_optimal);
fprintf("分支定界节点数：%d\n", sol.nodes_explored);
fprintf("运行时间：%.2f 秒\n", sol.runtime_seconds);

saveOutputs(cfg, mdl, sol);
fprintf("结果已保存到：%s\n", cfg.output_dir);
end

function printTopNodes(mdl)
%PRINTTOPNODES 打印短缺和富余最大的若干网格，便于检查输入是否合理。
nShow = min(8, mdl.data.n);
[~, shortOrder] = sort(mdl.data.shortage, "descend");
[~, surpOrder] = sort(mdl.data.surplus, "descend");

fprintf("短缺最大的前 %d 个网格：\n", nShow);
for t = 1:nShow
    i = shortOrder(t);
    fprintf("  %s shortage=%.0f surplus=%.0f\n", mdl.data.node_ids(i), mdl.data.shortage(i), mdl.data.surplus(i));
end

fprintf("富余最大的前 %d 个网格：\n", nShow);
for t = 1:nShow
    i = surpOrder(t);
    fprintf("  %s surplus=%.0f shortage=%.0f\n", mdl.data.node_ids(i), mdl.data.surplus(i), mdl.data.shortage(i));
end
end

function saveOutputs(cfg, mdl, sol)
%SAVEOUTPUTS 保存求解结果，便于后续可视化和报告分析。

tag = string(cfg.grid_size_m) + "m_" + string(cfg.scenario_id);
matFile = fullfile(cfg.output_dir, "solution_" + tag + ".mat");
save(matFile, "cfg", "mdl", "sol");

summary = table( ...
    string(sol.status), sol.objective, sol.proven_optimal, sol.nodes_explored, ...
    sol.best_bound, sol.gap, sol.runtime_seconds, ...
    VariableNames=["status","objective","proven_optimal","nodes_explored","best_bound","gap","runtime_seconds"]);
writetable(summary, fullfile(cfg.output_dir, "summary_" + tag + ".csv"));

if isempty(sol.decoded)
    return;
end

writetable(sol.decoded.routes, fullfile(cfg.output_dir, "routes_" + tag + ".csv"));
writetable(sol.decoded.actions, fullfile(cfg.output_dir, "vehicle_actions_" + tag + ".csv"));
writetable(sol.decoded.shortage, fullfile(cfg.output_dir, "shortage_service_" + tag + ".csv"));
writetable(sol.decoded.vehicle_time, fullfile(cfg.output_dir, "vehicle_time_" + tag + ".csv"));
writetable(sol.decoded.objective_parts, fullfile(cfg.output_dir, "objective_parts_" + tag + ".csv"));
end
