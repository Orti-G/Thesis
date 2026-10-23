"""
GRID - check that the cached forecast frame gives the same /forecast result as the full rebuild.
Read-only: it does not write to PostgreSQL, Firebase or the models folder.

For each test day it builds the history once, as the server would shortly after midnight
(readings up to 00:20), then compares forecast_now() at several times of that day:
    full    = build_frame(all readings up to that time)                (current /forecast)
    cached  = build_today(last 48 h up to that time, history)          (new /forecast)

Run on the VM, from ~/energy_app (with energy_env active and GRID_DB_PASSWORD set):
    python forecast_cache_check.py               # 5 most recent full days
    python forecast_cache_check.py --days 8
Or off the VM with a CSV export:  python forecast_cache_check.py --csv readings.csv
"""
import argparse, os, sys, time
from datetime import timedelta

import joblib
import numpy as np
import pandas as pd

import forecast_retrain as fr

MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")
TIMES = ["00:30", "03:00", "06:30", "09:00", "12:00", "15:30", "18:00", "21:00", "23:50"]
NUM_KEYS = ["predicted_clean_kWh", "anomalous_so_far_kWh", "expected_rest_anomalous_kWh", "predicted_day_total_kWh",
            "today_so_far_kWh", "accumulated_past_kWh", "combined_kWh", "ewma_daily_kWh", "days_remaining",
            "projected_eom_kWh", "projected_eom_calibrated_kWh", "level_kWh"]


def load_raw(args):
    if args.csv:
        return pd.read_csv(args.csv, parse_dates=["timestamp"]).sort_values("timestamp").reset_index(drop=True)
    import psycopg2
    pw = os.environ.get("GRID_DB_PASSWORD") or sys.exit("Set GRID_DB_PASSWORD first.")
    with psycopg2.connect(dbname="energy_db", user="energy_user", password=pw, host="localhost", port=5432) as conn:
        return fr.fetch_all_readings_db(conn)


def cycle_end(day):
    return day.replace(day=27) if day.day <= 27 else (day.replace(day=1) + timedelta(days=32)).replace(day=27)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv")
    ap.add_argument("--days", type=int, default=5)
    ap.add_argument("--dates", nargs="*", help="specific days to test, e.g. 2026-08-11 2026-10-02")
    args = ap.parse_args()

    ab = joblib.load(os.path.join(MODEL_DIR, "anomaly_model.pkl"))
    fb = fr.load_bundle(MODEL_DIR)
    raw = load_raw(args)
    raw["timestamp"] = pd.to_datetime(raw["timestamp"])
    n_day = raw.groupby(raw.timestamp.dt.date).size()
    last = raw.timestamp.max().date()
    days = [d for d in n_day.index if n_day[d] >= fr.FULL_DAY_ROWS and d < last][-args.days:]
    if args.dates:
        days = [pd.Timestamp(x).date() for x in args.dates]
    print(f"{len(raw)} readings; test days: {', '.join(map(str, days))}\n")

    worst, t_full, t_cached, n = 0.0, [], [], 0
    for day in days:
        d0 = pd.Timestamp(day)
        hist = fr.build_history(raw[raw.timestamp < d0 + pd.Timedelta(minutes=20)], ab, fb, day)
        for hhmm in TIMES:
            now = pd.Timestamp(f"{day} {hhmm}")
            upto = raw[raw.timestamp <= now]
            if (upto.timestamp.dt.date == day).sum() == 0:
                continue
            cyc_kwh = float(upto.cumul_kwh.iloc[-1])
            t0 = time.perf_counter()
            a = fr.forecast_now(fr.build_frame(upto, ab, fb, today=day), fb, cyc_kwh, now.to_pydatetime(), cycle_end(day))
            t1 = time.perf_counter()
            win = upto[upto.timestamp >= d0 - pd.Timedelta(hours=fr.WINDOW_HOURS_BEFORE_TODAY)]
            b = fr.forecast_now(fr.build_today(win, ab, fb, hist), fb, cyc_kwh, now.to_pydatetime(), cycle_end(day))
            t2 = time.perf_counter()
            t_full.append((t1 - t0) * 1000); t_cached.append((t2 - t1) * 1000); n += 1
            diff = max(abs(float(a[k]) - float(b[k])) for k in NUM_KEYS)
            same = diff < 1e-6 and a["bracket"] == b["bracket"]
            worst = max(worst, diff)
            print(f"{day} {hhmm}  day total {a['predicted_day_total_kWh']:7.3f} vs {b['predicted_day_total_kWh']:7.3f}  "
                  f"EOM {a['projected_eom_calibrated_kWh']:8.3f} vs {b['projected_eom_calibrated_kWh']:8.3f}  "
                  f"max diff {diff:.2e}  {'OK' if same else 'MISMATCH'}")
            if not same:
                for k in NUM_KEYS:
                    if abs(float(a[k]) - float(b[k])) >= 1e-6:
                        print(f"      {k}: full {a[k]}  cached {b[k]}")

    print(f"\n{n} checkpoints, largest difference {worst:.2e} kWh -> "
          f"{'IDENTICAL (safe to deploy)' if worst < 1e-6 else 'DIFFERENT (do not deploy, send this output)'}")
    print(f"median time per forecast: full {np.median(t_full):.0f} ms, cached {np.median(t_cached):.0f} ms")


if __name__ == "__main__":
    main()
