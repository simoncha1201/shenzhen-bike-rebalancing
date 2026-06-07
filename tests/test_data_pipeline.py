from __future__ import annotations

import pandas as pd

from bike_rebalancing.data_pipeline import (
    build_distance_matrix,
    build_od_flow,
    build_scenario_grid_demand,
    clean_orders,
    normalize_orders,
)


def test_normalize_orders_maps_api_columns() -> None:
    df = normalize_orders(
        [
            {
                "USER_ID": "u1",
                "COM_ID": "c1",
                "START_TIME": "2021-05-10 07:00:00.0",
                "START_LNG": "114.01",
                "START_LAT": "22.52",
                "END_TIME": "2021-05-10 07:15:00.0",
                "END_LNG": "114.02",
                "END_LAT": "22.53",
            }
        ]
    )

    assert list(df.columns) == [
        "user_id",
        "company_id",
        "start_time",
        "start_lng",
        "start_lat",
        "end_time",
        "end_lng",
        "end_lat",
    ]
    assert df.loc[0, "company_id"] == "c1"


def test_clean_orders_filters_invalid_records() -> None:
    raw = pd.DataFrame(
        [
            _order("u1", "2021-05-10 07:00:00", "2021-05-10 07:10:00", 114.01, 22.52, 114.02, 22.53),
            _order("u2", "2021-05-10 07:00:00", "2021-05-10 06:59:00", 114.01, 22.52, 114.02, 22.53),
            _order("u3", "2021-05-10 07:00:00", "2021-05-10 10:00:01", 114.01, 22.52, 114.02, 22.53),
            _order("u4", "bad", "2021-05-10 07:10:00", 114.01, 22.52, 114.02, 22.53),
            _order("u5", "2021-05-10 07:00:00", "2021-05-10 07:10:00", 115.01, 22.52, 115.02, 22.53),
            _order("u1", "2021-05-10 07:00:00", "2021-05-10 07:10:00", 114.01, 22.52, 114.02, 22.53),
        ]
    )

    clean, quality = clean_orders(raw)

    assert len(clean) == 1
    assert quality["rows_removed"].sum() == 5


def test_scenario_grid_demand_includes_ten_peak_scenarios() -> None:
    clean, _ = clean_orders(
        pd.DataFrame(
            [
                _order("u1", "2021-05-10 07:05:00", "2021-05-10 07:15:00", 114.010, 22.520, 114.020, 22.530),
                _order("u2", "2021-05-10 17:05:00", "2021-05-10 17:15:00", 114.020, 22.530, 114.010, 22.520),
                _order("u3", "2021-05-11 08:05:00", "2021-05-11 08:15:00", 114.010, 22.520, 114.010, 22.520),
            ]
        )
    )

    demand, grid_meta = build_scenario_grid_demand(clean, 1000)

    assert demand["scenario_id"].nunique() == 10
    assert not grid_meta.empty
    row = demand[(demand["scenario_id"] == "20210510_am_peak") & (demand["departures"] == 1)].iloc[0]
    assert row["net_outflow"] == row["departures"] - row["arrivals"]
    assert row["shortage"] == max(row["net_outflow"], 0)
    assert row["surplus"] == max(-row["net_outflow"], 0)


def test_od_flow_and_distance_matrix_are_model_ready() -> None:
    clean, _ = clean_orders(
        pd.DataFrame(
            [
                _order("u1", "2021-05-10 07:05:00", "2021-05-10 07:15:00", 114.000, 22.500, 114.020, 22.520),
                _order("u2", "2021-05-10 07:10:00", "2021-05-10 07:20:00", 114.000, 22.500, 114.020, 22.520),
            ]
        )
    )
    _, grid_meta = build_scenario_grid_demand(clean, 1000)
    od = build_od_flow(clean, 1000)
    distances = build_distance_matrix(grid_meta)

    assert od.loc[0, "scenario_id"] == "20210510_am_peak"
    assert od.loc[0, "order_count"] == 2
    assert {"from_grid_id", "to_grid_id", "distance_km"} <= set(distances.columns)
    assert (distances["distance_km"] > 0).all()


def _order(user_id: str, start_time: str, end_time: str, start_lng: float, start_lat: float, end_lng: float, end_lat: float) -> dict:
    return {
        "USER_ID": user_id,
        "COM_ID": "",
        "START_TIME": start_time,
        "START_LNG": start_lng,
        "START_LAT": start_lat,
        "END_TIME": end_time,
        "END_LNG": end_lng,
        "END_LAT": end_lat,
    }

