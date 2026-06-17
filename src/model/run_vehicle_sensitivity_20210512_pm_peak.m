function run_vehicle_sensitivity_20210512_pm_peak()
%RUN_VEHICLE_SENSITIVITY_20210512_PM_PEAK Run fleet-mix sensitivity cases.

thisDir = fileparts(mfilename("fullpath"));
addpath(thisDir);

outDir = fullfile(projectRoot(), "outputs", "vehicle_sensitivity_20210512_pm_peak");
paramDir = fullfile(outDir, "vehicle_params");
if ~isfolder(outDir)
    mkdir(outDir);
end
if ~isfolder(paramDir)
    mkdir(paramDir);
end

cfgBase = prama();
cfgBase.grid_size_m = 1000;
cfgBase.scenario_id = "20210512_pm_peak";
cfgBase.max_service_nodes = 1200;
cfgBase.max_vehicles_to_use = 20;
cfgBase.solver.method = "heuristic";
cfgBase.solver.display = false;
cfgBase.heuristic.sa_iterations = 6000;
cfgBase.heuristic.max_greedy_tasks = 300;
cfgBase.heuristic.neighbor_sample_limit = 100000;
cfgBase.print_edge_summary = false;
cfgBase.exact_validation.enabled = false;

scenarios = makeScenarios();
writetable(scenarios, fullfile(outDir, "vehicle_sensitivity_scenarios.csv"));

names = ["scenario_id","analysis_group","small_count","medium_count","large_count", ...
    "total_count","small_share","medium_share","large_share","total_capacity_bikes", ...
    "avg_capacity_bikes","min_capacity_bikes","max_capacity_bikes","status","objective", ...
    "makespan_min","total_vehicle_time_min","total_unmet_bikes","total_served_bikes", ...
    "service_shortfall_bikes","total_shortage_bikes","total_surplus_bikes", ...
    "shortage_satisfaction_rate","relocatable_service_rate","used_vehicle_count", ...
    "idle_vehicle_count","avg_used_route_time_min","max_route_time_min", ...
    "split_original_node_count","split_node_count","runtime_seconds","total_run_seconds"];
rows = cell(height(scenarios), numel(names));

for s = 1:height(scenarios)
    scenario = scenarios(s, :);
    fprintf("Running %s (%d/%d): S=%d M=%d L=%d\n", ...
        scenario.scenario_id, s, height(scenarios), scenario.small_count, ...
        scenario.medium_count, scenario.large_count);

    fleet = makeFleet(scenario.small_count, scenario.medium_count, scenario.large_count);
    paramFile = fullfile(paramDir, scenario.scenario_id + "_vehicles.csv");
    writetable(fleet, paramFile);

    cfg = cfgBase;
    cfg.vehicle_param_file = paramFile;
    cfg.max_vehicles_to_use = height(fleet);

    tAll = tic;
    mdl = model(cfg);
    sol = solve_heuristic(mdl, cfg);
    totalRunSeconds = toc(tAll);

    parts = sol.decoded.objective_parts;
    vehicleTime = sol.decoded.vehicle_time;
    usedMask = double(vehicleTime.route_time_min) > 1.0e-8;
    usedVehicleCount = sum(usedMask);
    idleVehicleCount = height(vehicleTime) - usedVehicleCount;
    usedTimes = double(vehicleTime.route_time_min(usedMask));
    if isempty(usedTimes)
        avgUsedRouteTime = 0;
    else
        avgUsedRouteTime = mean(usedTimes);
    end

    totalShortage = sum(mdl.data.shortage);
    totalSurplus = sum(mdl.data.surplus);
    totalServed = double(parts.total_served_bikes(1));
    shortageSatisfactionRate = totalServed / totalShortage;
    relocatableServiceRate = totalServed / min(totalShortage, totalSurplus);

    totalCount = scenario.small_count + scenario.medium_count + scenario.large_count;
    totalCapacity = sum(fleet.capacity_bikes);

    rows(s, :) = { ...
        string(scenario.scenario_id), string(scenario.analysis_group), ...
        scenario.small_count, scenario.medium_count, scenario.large_count, totalCount, ...
        scenario.small_count / totalCount, scenario.medium_count / totalCount, ...
        scenario.large_count / totalCount, totalCapacity, mean(fleet.capacity_bikes), ...
        min(fleet.capacity_bikes), max(fleet.capacity_bikes), string(sol.status), sol.objective, ...
        double(parts.makespan_min(1)), double(parts.total_vehicle_time_min(1)), ...
        double(parts.total_unmet_bikes(1)), totalServed, ...
        double(parts.service_shortfall_bikes(1)), totalShortage, totalSurplus, ...
        shortageSatisfactionRate, relocatableServiceRate, usedVehicleCount, ...
        idleVehicleCount, avgUsedRouteTime, max(double(vehicleTime.route_time_min)), ...
        mdl.data.node_split.original_node_count, mdl.data.node_split.split_node_count, ...
        sol.runtime_seconds, totalRunSeconds};
end

summary = cell2table(rows, VariableNames=names);
writetable(summary, fullfile(outDir, "vehicle_sensitivity_summary.csv"));
fprintf("Saved sensitivity results to %s\n", outDir);
end

function scenarios = makeScenarios()
scenarioId = [
    "baseline_20_6s12m2l"
    "composition_small_heavy_20_10s8m2l"
    "composition_medium_heavy_20_4s14m2l"
    "composition_large_heavy_20_4s8m8l"
    "composition_balanced_20_7s7m6l"
    "composition_no_large_20_8s12m0l"
    "composition_no_small_20_0s14m6l"
    "composition_all_small_20_20s0m0l"
    "composition_all_medium_20_0s20m0l"
    "composition_all_large_20_0s0m20l"
    "total_8_2s5m1l"
    "total_12_4s7m1l"
    "total_16_5s10m1l"
    "total_24_7s14m3l"
    "total_28_8s17m3l"
    ];
analysisGroup = [
    "baseline"
    repmat("composition", 9, 1)
    repmat("total_count", 5, 1)
    ];
smallCount = [6; 10; 4; 4; 7; 8; 0; 20; 0; 0; 2; 4; 5; 7; 8];
mediumCount = [12; 8; 14; 8; 7; 12; 14; 0; 20; 0; 5; 7; 10; 14; 17];
largeCount = [2; 2; 2; 8; 6; 0; 6; 0; 0; 20; 1; 1; 1; 3; 3];

scenarios = table(scenarioId, analysisGroup, smallCount, mediumCount, largeCount, ...
    VariableNames=["scenario_id","analysis_group","small_count","medium_count","large_count"]);
end

function fleet = makeFleet(smallCount, mediumCount, largeCount)
totalCount = smallCount + mediumCount + largeCount;
if totalCount <= 0
    error("Fleet must contain at least one vehicle.");
end

vehicle_id = strings(totalCount, 1);
capacity_bikes = zeros(totalCount, 1);
speed_kmh = zeros(totalCount, 1);
start_grid_id = strings(totalCount, 1);
start_lng = zeros(totalCount, 1);
start_lat = zeros(totalCount, 1);
load_time_min_per_bike = 0.60 * ones(totalCount, 1);
unload_time_min_per_bike = 0.45 * ones(totalCount, 1);
fixed_stop_time_min = 4 * ones(totalCount, 1);
max_route_time_min = 180 * ones(totalCount, 1);
available = ones(totalCount, 1);
notes = strings(totalCount, 1);

depotGrid = "1000m_r005_c008";
depotLng = 114.06266855872391;
depotLat = 22.539407114624506;
idx = 0;

    function addVehicle(capacity, speed, note)
        idx = idx + 1;
        vehicle_id(idx) = compose("truck_%02d", idx);
        capacity_bikes(idx) = capacity;
        speed_kmh(idx) = speed;
        start_grid_id(idx) = depotGrid;
        start_lng(idx) = depotLng;
        start_lat(idx) = depotLat;
        notes(idx) = note;
    end

for i = 1:smallCount
    addVehicle(20, 22, "Sensitivity small vehicle");
end

standardMediumCount = ceil(mediumCount / 2);
upperMediumCount = mediumCount - standardMediumCount;
for i = 1:standardMediumCount
    addVehicle(24, 21, "Sensitivity medium vehicle, lower capacity template");
end
for i = 1:upperMediumCount
    addVehicle(28, 20, "Sensitivity medium vehicle, upper capacity template");
end

for i = 1:largeCount
    addVehicle(32, 18, "Sensitivity large vehicle");
end

fleet = table(vehicle_id, capacity_bikes, speed_kmh, start_grid_id, start_lng, ...
    start_lat, load_time_min_per_bike, unload_time_min_per_bike, ...
    fixed_stop_time_min, max_route_time_min, available, notes);
end

function root = projectRoot()
thisFile = mfilename("fullpath");
root = string(fileparts(fileparts(fileparts(thisFile))));
end
