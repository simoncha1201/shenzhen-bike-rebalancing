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
    write_distance_matrix_parquet,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw_files", nargs="+", help="Raw API JSONL files saved by download_orders.py.")
    parser.add_argument("--out-dir", default="data/processed")
    parser.add_argument("--start-date", default="2021-05-10")
    parser.add_argument("--end-date", default="2021-05-14")
    parser.add_argument("--grid-sizes", default="1000,500,200,100", help="Comma-separated grid sizes in meters.")
    parser.add_argument(
        "--distance-grid-sizes",
        default="1000,200,100",
        help="Comma-separated grid sizes in meters for dense distance matrices. Use an empty string to skip.",
    )
    parser.add_argument("--distance-chunk-origins", type=int, default=256)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    raw_files = _expand_raw_files(args.raw_files)
    raw = load_api_jsonl(raw_files)
    clean, quality = clean_orders(raw)
    clean.to_parquet(out_dir / "orders_clean_futian_week.parquet", index=False)

    grid_sizes = _parse_grid_sizes(args.grid_sizes)
    distance_grid_sizes = _parse_grid_sizes(args.distance_grid_sizes)
    grid_metadata: dict[int, pd.DataFrame] = {}
    output_counts: dict[str, int] = {}

    for grid_size_m in grid_sizes:
        suffix = _grid_suffix(grid_size_m)
        demand, grid = build_scenario_grid_demand(clean, grid_size_m, args.start_date, args.end_date)
        od_flow = build_od_flow(clean, grid_size_m, args.start_date, args.end_date)
        grid_metadata[grid_size_m] = grid

        demand.to_parquet(out_dir / f"scenario_grid_demand_{suffix}.parquet", index=False)
        od_flow.to_parquet(out_dir / f"od_flow_grid_{suffix}.parquet", index=False)
        grid.to_csv(out_dir / f"grid_metadata_{suffix}.csv", index=False)

        output_counts[f"scenario_grid_demand_{suffix}"] = len(demand)
        output_counts[f"od_flow_grid_{suffix}"] = len(od_flow)
        output_counts[f"grid_metadata_{suffix}"] = len(grid)

    for grid_size_m in distance_grid_sizes:
        suffix = _grid_suffix(grid_size_m)
        grid = grid_metadata.get(grid_size_m)
        if grid is None:
            _, grid = build_scenario_grid_demand(clean, grid_size_m, args.start_date, args.end_date)
        if grid_size_m == 1000:
            distance = build_distance_matrix(grid)
            distance.to_parquet(out_dir / f"distance_matrix_{suffix}.parquet", index=False)
            distance_rows = len(distance)
        else:
            distance_rows = write_distance_matrix_parquet(
                grid,
                out_dir / f"distance_matrix_{suffix}.parquet",
                chunk_origins=args.distance_chunk_origins,
            )
        output_counts[f"distance_matrix_{suffix}"] = distance_rows

    scenario_summary = scenario_counts(clean, args.start_date, args.end_date)

    quality.to_csv(out_dir / "data_quality_summary.csv", index=False)
    scenario_summary.to_csv(out_dir / "scenario_order_counts.csv", index=False)

    print(f"clean_orders={len(clean)}")
    for name, count in output_counts.items():
        print(f"{name}={count}")
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


def _parse_grid_sizes(value: str) -> list[int]:
    if not value.strip():
        return []
    return [int(item.strip()) for item in value.split(",") if item.strip()]


def _grid_suffix(grid_size_m: int) -> str:
    if grid_size_m % 1000 == 0:
        return f"{grid_size_m // 1000}km"
    return f"{grid_size_m}m"


if __name__ == "__main__":
    main()
