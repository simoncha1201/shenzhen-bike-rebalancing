"""Validate generated model input files for the data deliverable."""

from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd


REQUIRED_FILES = [
    "orders_clean_futian_week.parquet",
    "scenario_grid_demand_1km.parquet",
    "scenario_grid_demand_500m.parquet",
    "od_flow_grid_1km.parquet",
    "distance_matrix_1km.parquet",
    "grid_metadata_1km.csv",
    "grid_metadata_500m.csv",
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
    missing = [name for name in REQUIRED_FILES if not (processed_dir / name).exists()]
    if missing:
        raise SystemExit(f"Missing required output files: {missing}")

    demand = pd.read_parquet(processed_dir / "scenario_grid_demand_1km.parquet")
    missing_columns = DEMAND_COLUMNS - set(demand.columns)
    if missing_columns:
        raise SystemExit(f"scenario_grid_demand_1km.parquet missing columns: {sorted(missing_columns)}")

    if demand["scenario_id"].nunique() != 10:
        raise SystemExit("Expected exactly 10 scenarios: 5 weekdays x AM/PM peaks.")

    if not (demand["net_outflow"] == demand["departures"] - demand["arrivals"]).all():
        raise SystemExit("net_outflow must equal departures - arrivals.")

    if not (demand["shortage"] == demand["net_outflow"].clip(lower=0)).all():
        raise SystemExit("shortage must equal max(net_outflow, 0).")

    if not (demand["surplus"] == (-demand["net_outflow"]).clip(lower=0)).all():
        raise SystemExit("surplus must equal max(-net_outflow, 0).")

    scenario_counts = pd.read_csv(processed_dir / "scenario_order_counts.csv")
    empty_scenarios = scenario_counts.loc[scenario_counts["orders"] <= 0, "scenario_id"].tolist()
    if empty_scenarios:
        raise SystemExit(f"Scenarios with no cleaned orders: {empty_scenarios}")

    od_flow = pd.read_parquet(processed_dir / "od_flow_grid_1km.parquet")
    if od_flow.empty:
        raise SystemExit("od_flow_grid_1km.parquet is empty.")

    distance = pd.read_parquet(processed_dir / "distance_matrix_1km.parquet")
    if distance.empty or (distance["distance_km"] <= 0).any():
        raise SystemExit("distance_matrix_1km.parquet must contain positive distances.")

    print("validated=true")
    print(f"scenario_count={demand['scenario_id'].nunique()}")
    print(f"grid_rows_1km={len(demand)}")
    print(f"od_flow_rows_1km={len(od_flow)}")


if __name__ == "__main__":
    main()

