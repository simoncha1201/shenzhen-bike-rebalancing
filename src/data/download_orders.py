"""Download paginated Shenzhen open-data bike order API responses."""

from __future__ import annotations

import argparse
import json
import math
import os
import time
from pathlib import Path

import requests


DEFAULT_ENDPOINT = "https://opendata.sz.gov.cn/api/29200_00403627/1/service.xhtml"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-key", default=os.getenv("SHENZHEN_OPEN_DATA_APP_KEY"), help="API appKey. Defaults to SHENZHEN_OPEN_DATA_APP_KEY.")
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--start-date", default="20210510", help="Inclusive date filter, format yyyymmdd.")
    parser.add_argument("--end-date", default="20210514", help="Inclusive date filter, format yyyymmdd.")
    parser.add_argument("--rows", type=int, default=10000, help="Rows per page. The platform caps this at 10000.")
    parser.add_argument("--start-page", type=int, default=1)
    parser.add_argument("--max-pages", type=int, default=1, help="Safety limit for pages to download. Increase after sample verification.")
    parser.add_argument("--sleep-seconds", type=float, default=0.2)
    parser.add_argument("--out-dir", default="data/raw")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.app_key:
        raise SystemExit("Missing appKey. Pass --app-key or set SHENZHEN_OPEN_DATA_APP_KEY.")
    if args.rows > 10000:
        raise SystemExit("--rows cannot exceed the platform limit of 10000.")

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"bike_orders_{args.start_date}_{args.end_date}_p{args.start_page}.jsonl"

    total_pages = None
    pages_written = 0
    with out_path.open("w", encoding="utf-8") as fh:
        for page in range(args.start_page, args.start_page + args.max_pages):
            payload = {
                "page": page,
                "rows": args.rows,
                "appKey": args.app_key,
                "startDate": args.start_date,
                "endDate": args.end_date,
            }
            response = requests.post(
                args.endpoint,
                data=payload,
                headers={
                    "Content-Type": "application/x-www-form-urlencoded",
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) data-course-project",
                },
                timeout=60,
            )
            response.raise_for_status()
            data = response.json()
            fh.write(json.dumps(data, ensure_ascii=False) + "\n")
            pages_written += 1

            total = int(data.get("total") or 0)
            if total_pages is None and total:
                total_pages = math.ceil(total / args.rows)
                print(f"total={total} rows={args.rows} estimated_pages={total_pages}")
            print(f"downloaded_page={page} records={len(data.get('data', []))}")

            if not data.get("data") or (total_pages is not None and page >= total_pages):
                break
            time.sleep(args.sleep_seconds)

    print(f"saved={out_path} pages_written={pages_written}")


if __name__ == "__main__":
    main()
