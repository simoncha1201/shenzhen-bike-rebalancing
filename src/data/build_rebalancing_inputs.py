"""Build cleaned bike rebalancing model inputs from raw API files."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import glob

import pandas as pd

SRC_DIR = Path(__file__).resolve().parents[1]
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

from bike_rebalancing.data_pipeline import (
    build_distance_matrix,
    build_od_flow,
    build_scenario_grid_demand,
    clean_orders,
    load_api_jsonl,
    scenario_counts,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw_files", nargs="+", help="Raw API JSONL files saved by download_orders.py.")
    parser.add_argument("--out-dir", default="data/processed")
    parser.add_argument("--start-date", default="2021-05-10")
    parser.add_argument("--end-date", default="2021-05-14")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    raw_files = _expand_raw_files(args.raw_files)
    raw = load_api_jsonl(raw_files)
    clean, quality = clean_orders(raw)
    clean.to_parquet(out_dir / "orders_clean_futian_week.parquet", index=False)

    demand_1km, grid_1km = build_scenario_grid_demand(clean, 1000, args.start_date, args.end_date)
    demand_500m, grid_500m = build_scenario_grid_demand(clean, 500, args.start_date, args.end_date)
    od_1km = build_od_flow(clean, 1000, args.start_date, args.end_date)
    distance_1km = build_distance_matrix(grid_1km)
    scenario_summary = scenario_counts(clean, args.start_date, args.end_date)

    demand_1km.to_parquet(out_dir / "scenario_grid_demand_1km.parquet", index=False)
    demand_500m.to_parquet(out_dir / "scenario_grid_demand_500m.parquet", index=False)
    od_1km.to_parquet(out_dir / "od_flow_grid_1km.parquet", index=False)
    distance_1km.to_parquet(out_dir / "distance_matrix_1km.parquet", index=False)
    grid_1km.to_csv(out_dir / "grid_metadata_1km.csv", index=False)
    grid_500m.to_csv(out_dir / "grid_metadata_500m.csv", index=False)

    quality.to_csv(out_dir / "data_quality_summary.csv", index=False)
    scenario_summary.to_csv(out_dir / "scenario_order_counts.csv", index=False)

    print(f"clean_orders={len(clean)}")
    print(f"scenario_grid_demand_1km={len(demand_1km)}")
    print(f"od_flow_grid_1km={len(od_1km)}")
    print(f"outputs={out_dir}")


def _expand_raw_files(patterns: list[str]) -> list[str]:
    files: list[str] = []
    for pattern in patterns:
        matches = sorted(glob.glob(pattern))
        files.extend(matches or [pattern])
    missing = [path for path in files if not Path(path).exists()]
    if missing:
        raise SystemExit(f"Raw files not found: {missing}")
    return files


if __name__ == "__main__":
    main()
