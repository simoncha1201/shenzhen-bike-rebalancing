"""Download representative peak-period pages for the Futian data deliverable.

The full target week has about 7.86 million records. This script downloads
time-sorted page windows around each weekday AM/PM peak so the data owner can
produce a balanced, reproducible course-project sample without pulling the
entire platform extract.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


PEAK_PAGE_STARTS = [
    45,   # 2021-05-10 AM peak
    100,  # 2021-05-10 PM peak
    175,  # 2021-05-11 AM peak
    260,  # 2021-05-11 PM peak
    350,  # 2021-05-12 AM peak
    440,  # 2021-05-12 PM peak
    500,  # 2021-05-13 AM peak
    595,  # 2021-05-13 PM peak
    650,  # 2021-05-14 AM peak
    745,  # 2021-05-14 PM peak
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pages-per-window", type=int, default=2, help="Pages to download from each peak window.")
    parser.add_argument("--rows", type=int, default=10000)
    parser.add_argument("--app-key", default=os.getenv("SHENZHEN_OPEN_DATA_APP_KEY"))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.app_key:
        raise SystemExit("Missing appKey. Pass --app-key or set SHENZHEN_OPEN_DATA_APP_KEY.")

    script = Path(__file__).with_name("download_orders.py")
    for start_page in PEAK_PAGE_STARTS:
        cmd = [
            sys.executable,
            str(script),
            "--start-page",
            str(start_page),
            "--max-pages",
            str(args.pages_per_window),
            "--rows",
            str(args.rows),
            "--app-key",
            args.app_key,
        ]
        print(f"downloading_peak_window_start_page={start_page}")
        subprocess.run(cmd, check=True)


if __name__ == "__main__":
    main()

