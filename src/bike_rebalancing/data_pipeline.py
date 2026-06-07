"""Data preparation utilities for regional bike rebalancing inputs."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from math import asin, cos, floor, radians, sin, sqrt
from pathlib import Path
from typing import Iterable
import json

import numpy as np
import pandas as pd


CANONICAL_COLUMNS = [
    "user_id",
    "company_id",
    "start_time",
    "start_lng",
    "start_lat",
    "end_time",
    "end_lng",
    "end_lat",
]

COLUMN_ALIASES = {
    "USER_ID": "user_id",
    "COM_ID": "company_id",
    "COMPANY_ID": "company_id",
    "START_TIME": "start_time",
    "START_LNG": "start_lng",
    "START_LAT": "start_lat",
    "END_TIME": "end_time",
    "END_LNG": "end_lng",
    "END_LAT": "end_lat",
}

FUTIAN_BBOX = {
    "min_lng": 113.98,
    "max_lng": 114.13,
    "min_lat": 22.49,
    "max_lat": 22.58,
}

DEFAULT_PEAK_WINDOWS = {
    "am_peak": ("07:00", "10:00"),
    "pm_peak": ("17:00", "20:00"),
}


@dataclass(frozen=True)
class GridSpec:
    size_m: int
    min_lng: float = FUTIAN_BBOX["min_lng"]
    max_lng: float = FUTIAN_BBOX["max_lng"]
    min_lat: float = FUTIAN_BBOX["min_lat"]
    max_lat: float = FUTIAN_BBOX["max_lat"]

    @property
    def lat_step(self) -> float:
        return self.size_m / 1000 / 111.32

    @property
    def lng_step(self) -> float:
        mid_lat = (self.min_lat + self.max_lat) / 2
        return self.size_m / 1000 / (111.32 * cos(radians(mid_lat)))

    @property
    def n_rows(self) -> int:
        return int(np.ceil((self.max_lat - self.min_lat) / self.lat_step))

    @property
    def n_cols(self) -> int:
        return int(np.ceil((self.max_lng - self.min_lng) / self.lng_step))


def normalize_orders(records: Iterable[dict] | pd.DataFrame) -> pd.DataFrame:
    """Normalize API records to canonical lowercase column names."""
    df = records.copy() if isinstance(records, pd.DataFrame) else pd.DataFrame(records)
    rename_map = {}
    for col in df.columns:
        upper_col = str(col).upper()
        if upper_col in COLUMN_ALIASES:
            rename_map[col] = COLUMN_ALIASES[upper_col]
    df = df.rename(columns=rename_map)

    for col in CANONICAL_COLUMNS:
        if col not in df.columns:
            df[col] = pd.NA

    return df[CANONICAL_COLUMNS].copy()


def load_api_jsonl(paths: Iterable[str | Path]) -> pd.DataFrame:
    """Load raw API JSON/JSONL responses saved by download_orders.py."""
    rows: list[dict] = []
    for path_like in paths:
        path = Path(path_like)
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                payload = json.loads(line)
                if isinstance(payload, dict) and isinstance(payload.get("data"), list):
                    rows.extend(payload["data"])
                elif isinstance(payload, list):
                    rows.extend(payload)
                elif isinstance(payload, dict):
                    rows.append(payload)
                else:
                    raise ValueError(f"Unsupported JSON payload in {path}")
    return normalize_orders(rows)


def clean_orders(
    orders: pd.DataFrame,
    bbox: dict[str, float] | None = None,
    min_duration_min: float = 1,
    max_duration_min: float = 120,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Clean orders and return cleaned rows plus a quality summary."""
    bbox = bbox or FUTIAN_BBOX
    df = normalize_orders(orders)
    summary = [_summary_row("raw_records", 0, len(df), "Input records")]

    df["start_time"] = pd.to_datetime(df["start_time"], errors="coerce")
    df["end_time"] = pd.to_datetime(df["end_time"], errors="coerce")
    for col in ["start_lng", "start_lat", "end_lng", "end_lat"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    required = ["start_time", "end_time", "start_lng", "start_lat", "end_lng", "end_lat"]
    missing_mask = df[required].isna().any(axis=1)
    df, removed = _drop_mask(df, missing_mask)
    summary.append(_summary_row("drop_missing_required", removed, len(df), "Missing time or coordinate"))

    df["duration_min"] = (df["end_time"] - df["start_time"]).dt.total_seconds() / 60
    duration_mask = (df["duration_min"] < min_duration_min) | (df["duration_min"] > max_duration_min)
    df, removed = _drop_mask(df, duration_mask)
    summary.append(
        _summary_row(
            "drop_invalid_duration",
            removed,
            len(df),
            f"Duration outside {min_duration_min}-{max_duration_min} minutes",
        )
    )

    coord_mask = ~(
        df["start_lng"].between(113.6, 114.8)
        & df["end_lng"].between(113.6, 114.8)
        & df["start_lat"].between(22.3, 22.9)
        & df["end_lat"].between(22.3, 22.9)
    )
    df, removed = _drop_mask(df, coord_mask)
    summary.append(_summary_row("drop_invalid_shenzhen_coordinates", removed, len(df), "Outside broad Shenzhen coordinate range"))

    df["start_in_study_area"] = _in_bbox(df["start_lng"], df["start_lat"], bbox)
    df["end_in_study_area"] = _in_bbox(df["end_lng"], df["end_lat"], bbox)
    study_area_mask = ~(df["start_in_study_area"] | df["end_in_study_area"])
    df, removed = _drop_mask(df, study_area_mask)
    summary.append(_summary_row("drop_outside_futian_bbox", removed, len(df), "Neither endpoint is inside Futian bounding box"))

    before = len(df)
    df = df.drop_duplicates(subset=["user_id", "start_time", "start_lng", "start_lat", "end_time", "end_lng", "end_lat"])
    summary.append(_summary_row("drop_duplicates", before - len(df), len(df), "Duplicate order-like records"))

    df = df.reset_index(drop=True)
    return df, pd.DataFrame(summary)


def assign_grid_columns(orders: pd.DataFrame, grid_size_m: int) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Attach start/end grid IDs and return grid metadata for active grids."""
    spec = GridSpec(size_m=grid_size_m)
    df = orders.copy()

    start = _grid_ids(df["start_lng"], df["start_lat"], spec)
    end = _grid_ids(df["end_lng"], df["end_lat"], spec)
    df["start_grid_id"] = start["grid_id"]
    df["start_grid_row"] = start["row"]
    df["start_grid_col"] = start["col"]
    df["end_grid_id"] = end["grid_id"]
    df["end_grid_row"] = end["row"]
    df["end_grid_col"] = end["col"]

    active = pd.concat(
        [
            start[["grid_id", "row", "col"]].dropna(),
            end[["grid_id", "row", "col"]].dropna(),
        ],
        ignore_index=True,
    ).drop_duplicates("grid_id")

    if active.empty:
        grid_meta = pd.DataFrame(columns=["grid_id", "row", "col", "center_lng", "center_lat", "grid_size_m"])
    else:
        active["row"] = active["row"].astype(int)
        active["col"] = active["col"].astype(int)
        active["center_lng"] = spec.min_lng + (active["col"] + 0.5) * spec.lng_step
        active["center_lat"] = spec.min_lat + (active["row"] + 0.5) * spec.lat_step
        active["grid_size_m"] = grid_size_m
        grid_meta = active.sort_values("grid_id").reset_index(drop=True)

    return df, grid_meta


def attach_peak_scenarios(
    orders: pd.DataFrame,
    start_date: str | date = "2021-05-10",
    end_date: str | date = "2021-05-14",
    peak_windows: dict[str, tuple[str, str]] | None = None,
) -> pd.DataFrame:
    """Attach date, peak_type, and scenario_id based on start_time."""
    peak_windows = peak_windows or DEFAULT_PEAK_WINDOWS
    df = orders.copy()
    dates = pd.date_range(start_date, end_date, freq="D")
    valid_dates = set(dates.date)
    df["date"] = df["start_time"].dt.date
    df = df[df["date"].isin(valid_dates)].copy()

    minute_of_day = df["start_time"].dt.hour * 60 + df["start_time"].dt.minute
    df["peak_type"] = pd.NA
    for peak_name, (start, end) in peak_windows.items():
        start_min = _hhmm_to_minutes(start)
        end_min = _hhmm_to_minutes(end)
        df.loc[(minute_of_day >= start_min) & (minute_of_day < end_min), "peak_type"] = peak_name

    df = df[df["peak_type"].notna()].copy()
    df["date"] = df["date"].astype(str)
    df["scenario_id"] = df["date"].str.replace("-", "", regex=False) + "_" + df["peak_type"].astype(str)
    return df.reset_index(drop=True)


def build_scenario_grid_demand(
    orders: pd.DataFrame,
    grid_size_m: int,
    start_date: str | date = "2021-05-10",
    end_date: str | date = "2021-05-14",
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Build scenario-level grid demand and grid metadata."""
    gridded, grid_meta = assign_grid_columns(orders, grid_size_m)
    scenario_orders = attach_peak_scenarios(gridded, start_date, end_date)
    scenarios = _scenario_frame(start_date, end_date)

    if grid_meta.empty:
        demand = pd.DataFrame(
            columns=["scenario_id", "date", "peak_type", "grid_id", "departures", "arrivals", "net_outflow", "shortage", "surplus"]
        )
        return demand, grid_meta

    full_index = scenarios.assign(key=1).merge(grid_meta[["grid_id"]].assign(key=1), on="key").drop(columns="key")

    departures = (
        scenario_orders.dropna(subset=["start_grid_id"])
        .groupby(["scenario_id", "start_grid_id"])
        .size()
        .rename("departures")
        .reset_index()
        .rename(columns={"start_grid_id": "grid_id"})
    )
    arrivals = (
        scenario_orders.dropna(subset=["end_grid_id"])
        .groupby(["scenario_id", "end_grid_id"])
        .size()
        .rename("arrivals")
        .reset_index()
        .rename(columns={"end_grid_id": "grid_id"})
    )

    demand = (
        full_index.merge(departures, on=["scenario_id", "grid_id"], how="left")
        .merge(arrivals, on=["scenario_id", "grid_id"], how="left")
        .fillna({"departures": 0, "arrivals": 0})
    )
    demand["departures"] = demand["departures"].astype(int)
    demand["arrivals"] = demand["arrivals"].astype(int)
    demand["net_outflow"] = demand["departures"] - demand["arrivals"]
    demand["shortage"] = demand["net_outflow"].clip(lower=0)
    demand["surplus"] = (-demand["net_outflow"]).clip(lower=0)
    return demand.sort_values(["scenario_id", "grid_id"]).reset_index(drop=True), grid_meta


def build_od_flow(
    orders: pd.DataFrame,
    grid_size_m: int = 1000,
    start_date: str | date = "2021-05-10",
    end_date: str | date = "2021-05-14",
) -> pd.DataFrame:
    """Build OD flows for trips with both endpoints inside the study grid."""
    gridded, _ = assign_grid_columns(orders, grid_size_m)
    scenario_orders = attach_peak_scenarios(gridded, start_date, end_date)
    both_inside = scenario_orders.dropna(subset=["start_grid_id", "end_grid_id"])
    return (
        both_inside.groupby(["scenario_id", "start_grid_id", "end_grid_id"])
        .size()
        .rename("order_count")
        .reset_index()
        .rename(columns={"start_grid_id": "start_grid_id", "end_grid_id": "end_grid_id"})
        .sort_values(["scenario_id", "start_grid_id", "end_grid_id"])
        .reset_index(drop=True)
    )


def build_distance_matrix(grid_meta: pd.DataFrame) -> pd.DataFrame:
    """Build pairwise grid-center distances in kilometers."""
    rows = []
    grids = grid_meta[["grid_id", "center_lng", "center_lat"]].to_dict("records")
    for origin in grids:
        for destination in grids:
            if origin["grid_id"] == destination["grid_id"]:
                continue
            rows.append(
                {
                    "from_grid_id": origin["grid_id"],
                    "to_grid_id": destination["grid_id"],
                    "distance_km": haversine_km(
                        origin["center_lng"],
                        origin["center_lat"],
                        destination["center_lng"],
                        destination["center_lat"],
                    ),
                }
            )
    return pd.DataFrame(rows)


def scenario_counts(orders: pd.DataFrame, start_date: str | date = "2021-05-10", end_date: str | date = "2021-05-14") -> pd.DataFrame:
    """Count cleaned orders by scenario for the quality summary."""
    gridded, _ = assign_grid_columns(orders, 1000)
    scenario_orders = attach_peak_scenarios(gridded, start_date, end_date)
    counts = scenario_orders.groupby("scenario_id").size().rename("orders").reset_index()
    return _scenario_frame(start_date, end_date).merge(counts, on="scenario_id", how="left").fillna({"orders": 0})


def haversine_km(lng1: float, lat1: float, lng2: float, lat2: float) -> float:
    """Great-circle distance between two lon/lat points."""
    radius_km = 6371.0088
    d_lng = radians(lng2 - lng1)
    d_lat = radians(lat2 - lat1)
    a = sin(d_lat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(d_lng / 2) ** 2
    return 2 * radius_km * asin(sqrt(a))


def _drop_mask(df: pd.DataFrame, mask: pd.Series) -> tuple[pd.DataFrame, int]:
    removed = int(mask.sum())
    return df.loc[~mask].copy(), removed


def _summary_row(stage: str, rows_removed: int, rows_remaining: int, notes: str) -> dict:
    return {
        "stage": stage,
        "rows_removed": int(rows_removed),
        "rows_remaining": int(rows_remaining),
        "notes": notes,
    }


def _in_bbox(lng: pd.Series, lat: pd.Series, bbox: dict[str, float]) -> pd.Series:
    return lng.between(bbox["min_lng"], bbox["max_lng"]) & lat.between(bbox["min_lat"], bbox["max_lat"])


def _grid_ids(lng: pd.Series, lat: pd.Series, spec: GridSpec) -> pd.DataFrame:
    in_area = _in_bbox(lng, lat, spec.__dict__)
    col = np.floor((lng - spec.min_lng) / spec.lng_step)
    row = np.floor((lat - spec.min_lat) / spec.lat_step)
    col = np.clip(col, 0, spec.n_cols - 1)
    row = np.clip(row, 0, spec.n_rows - 1)
    grid_id = pd.Series(pd.NA, index=lng.index, dtype="object")
    valid = in_area & row.notna() & col.notna()
    grid_id.loc[valid] = [
        f"{spec.size_m}m_r{int(r):03d}_c{int(c):03d}"
        for r, c in zip(row.loc[valid], col.loc[valid])
    ]
    return pd.DataFrame({"grid_id": grid_id, "row": row.where(valid), "col": col.where(valid)}, index=lng.index)


def _hhmm_to_minutes(value: str) -> int:
    hour, minute = value.split(":")
    return int(hour) * 60 + int(minute)


def _scenario_frame(start_date: str | date, end_date: str | date) -> pd.DataFrame:
    rows = []
    for day in pd.date_range(start_date, end_date, freq="D"):
        for peak_type in DEFAULT_PEAK_WINDOWS:
            date_text = day.date().isoformat()
            rows.append(
                {
                    "scenario_id": date_text.replace("-", "") + "_" + peak_type,
                    "date": date_text,
                    "peak_type": peak_type,
                }
            )
    return pd.DataFrame(rows)

