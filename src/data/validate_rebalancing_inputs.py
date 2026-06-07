"""Validate generated model input files for the data deliverable."""

from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd


GRID_SIZES = (1000, 500, 200, 100)
DISTANCE_GRID_SIZES = (1000, 200, 100)

REQUIRED_FILES = [
    "orders_clean_futian_week.parquet",
    "data_quality_summary.csv",
    "scenario_order_counts.csv",
]

DEMAND_COLUMNS = {
    "scenario_id",
    "date",
    "peak_type",
    "grid_id",
    "departures",
    "arrivals",
    "net_outflow",
    "shortage",
    "surplus",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--processed-dir", default="data/processed")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    processed_dir = Path(args.processed_dir)
    expected_files = REQUIRED_FILES + _grid_files() + _distance_files()
    missing = [name for name in expected_files if not (processed_dir / name).exists()]
    if missing:
        raise SystemExit(f"Missing required output files: {missing}")

    demand_counts: dict[str, int] = {}
    od_counts: dict[str, int] = {}

    for grid_size_m in GRID_SIZES:
        suffix = _grid_suffix(grid_size_m)
        demand = pd.read_parquet(processed_dir / f"scenario_grid_demand_{suffix}.parquet")
        missing_columns = DEMAND_COLUMNS - set(demand.columns)
        if missing_columns:
            raise SystemExit(f"scenario_grid_demand_{suffix}.parquet missing columns: {sorted(missing_columns)}")

        if demand["scenario_id"].nunique() != 10:
            raise SystemExit(f"scenario_grid_demand_{suffix}.parquet should contain exactly 10 scenarios.")

        if not (demand["net_outflow"] == demand["departures"] - demand["arrivals"]).all():
            raise SystemExit(f"scenario_grid_demand_{suffix}.parquet net_outflow must equal departures - arrivals.")

        if not (demand["shortage"] == demand["net_outflow"].clip(lower=0)).all():
            raise SystemExit(f"scenario_grid_demand_{suffix}.parquet shortage must equal max(net_outflow, 0).")

        if not (demand["surplus"] == (-demand["net_outflow"]).clip(lower=0)).all():
            raise SystemExit(f"scenario_grid_demand_{suffix}.parquet surplus must equal max(-net_outflow, 0).")

        grid_meta = pd.read_csv(processed_dir / f"grid_metadata_{suffix}.csv")
        if grid_meta.empty:
            raise SystemExit(f"grid_metadata_{suffix}.csv is empty.")

        od_flow = pd.read_parquet(processed_dir / f"od_flow_grid_{suffix}.parquet")
        if od_flow.empty:
            raise SystemExit(f"od_flow_grid_{suffix}.parquet is empty.")

        demand_counts[suffix] = len(demand)
        od_counts[suffix] = len(od_flow)

    scenario_counts = pd.read_csv(processed_dir / "scenario_order_counts.csv")
    empty_scenarios = scenario_counts.loc[scenario_counts["orders"] <= 0, "scenario_id"].tolist()
    if empty_scenarios:
        raise SystemExit(f"Scenarios with no cleaned orders: {empty_scenarios}")

    distance_counts: dict[str, int] = {}
    for grid_size_m in DISTANCE_GRID_SIZES:
        suffix = _grid_suffix(grid_size_m)
        distance = pd.read_parquet(processed_dir / f"distance_matrix_{suffix}.parquet", columns=["distance_km"])
        if distance.empty or (distance["distance_km"] <= 0).any():
            raise SystemExit(f"distance_matrix_{suffix}.parquet must contain positive distances.")
        distance_counts[suffix] = len(distance)

    print("validated=true")
    print("scenario_count=10")
    for suffix, count in demand_counts.items():
        print(f"grid_rows_{suffix}={count}")
    for suffix, count in od_counts.items():
        print(f"od_flow_rows_{suffix}={count}")
    for suffix, count in distance_counts.items():
        print(f"distance_rows_{suffix}={count}")


def _grid_files() -> list[str]:
    files = []
    for grid_size_m in GRID_SIZES:
        suffix = _grid_suffix(grid_size_m)
        files.extend(
            [
                f"scenario_grid_demand_{suffix}.parquet",
                f"od_flow_grid_{suffix}.parquet",
                f"grid_metadata_{suffix}.csv",
            ]
        )
    return files


def _distance_files() -> list[str]:
    return [f"distance_matrix_{_grid_suffix(grid_size_m)}.parquet" for grid_size_m in DISTANCE_GRID_SIZES]


def _grid_suffix(grid_size_m: int) -> str:
    if grid_size_m % 1000 == 0:
        return f"{grid_size_m // 1000}km"
    return f"{grid_size_m}m"


if __name__ == "__main__":
    main()
