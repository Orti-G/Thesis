"""
GRID - ML inference timing on the pilot VM (read-only).

Measures how long the deployed models take to produce results, using the same
functions main.py calls:
  - model loading (startup / hot reload)
  - anomaly detection per 5-minute reading: DB fetch, features + scoring, model call only
  - forecast per POST /forecast: DB fetch, feature frame, SVR + end-of-month projection, itemized bill
  - optional: refit time and peak memory (--refit), never saved or installed
  - optional: full POST /forecast round trip on the running API (--http)

It does not write to PostgreSQL, Firebase or the models folder.

Run on the VM, from the folder that holds main.py (e.g. ~/energy_app):
    source ~/energy_env/bin/activate
    export GRID_DB_PASSWORD=...          # same value as in main.py's DB_CONFIG
    python ml_timing.py                  # inference only (about 1-3 minutes)
    python ml_timing.py --refit          # also time both refits (heavier; run off-peak)
    python ml_timing.py --http           # also time POST /forecast on the live API
Results: printed table + ml_timing_results.json
"""
import argparse, json, os, platform, resource, statistics, sys, time
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd
import joblib
import sklearn

import anomaly_retrain as ar
import forecast_retrain as fr

PH_TZ = ZoneInfo("Asia/Manila")
MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")


def ms(f, *a, **k):
    t0 = time.perf_counter()
    out = f(*a, **k)
    return (time.perf_counter() - t0) * 1000, out


def summarize(xs):
    xs = sorted(xs)
    return {"n": len(xs), "median_ms": round(statistics.median(xs), 2), "mean_ms": round(statistics.fmean(xs), 2),
            "p95_ms": round(float(np.percentile(xs, 95)), 2), "min_ms": round(xs[0], 2), "max_ms": round(xs[-1], 2)}


def repeat(n, f, *a, warmup=3, label=None, **k):
    print(f"  timing {label or getattr(f, '__name__', 'step')} x{n} ...", flush=True)
    for _ in range(warmup):
        f(*a, **k)
    return summarize([ms(f, *a, **k)[0] for _ in range(n)])


def peak_rss_mb():
    return round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024, 1)   # Linux: KiB


def environment():
    env = {"python": platform.python_version(), "sklearn": sklearn.__version__, "pandas": pd.__version__,
           "numpy": np.__version__, "os": platform.platform(), "cpu_count": os.cpu_count()}
    try:
        with open("/proc/cpuinfo") as f:
            env["cpu_model"] = next(l.split(":", 1)[1].strip() for l in f if l.startswith("model name"))
        with open("/proc/meminfo") as f:
            env["mem_total_mb"] = round(int(next(l for l in f if l.startswith("MemTotal")).split()[1]) / 1024)
    except Exception:
        pass
    return env


def get_conn():
    import psycopg2
    pw = os.environ.get("GRID_DB_PASSWORD")
    if not pw:
        sys.exit("Set GRID_DB_PASSWORD first (export GRID_DB_PASSWORD=...).")
    return psycopg2.connect(dbname="energy_db", user="energy_user", password=pw, host="localhost", port=5432)


def next_cycle_end(today):
    if today.day <= 27:
        return today.replace(day=27)
    return (today.replace(day=1) + timedelta(days=32)).replace(day=27)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200, help="repetitions for the anomaly timings")
    ap.add_argument("--nf", type=int, default=30, help="repetitions for the forecast timings")
    ap.add_argument("--refit", action="store_true", help="also time both refits (not saved)")
    ap.add_argument("--http", action="store_true", help="also time POST /forecast on the running API")
    ap.add_argument("--url", default="http://127.0.0.1:8000/forecast")
    ap.add_argument("--csv", help="use a readings CSV instead of PostgreSQL (for testing off the VM)")
    args = ap.parse_args()

    R = {"run_at": datetime.now(PH_TZ).isoformat(), "environment": environment()}
    print("Environment:", json.dumps(R["environment"]))

    # ---------- model loading ----------
    R["load_anomaly_model"] = repeat(10, joblib.load, os.path.join(MODEL_DIR, "anomaly_model.pkl"), warmup=1, label="load_anomaly_model")
    R["load_forecast_model"] = repeat(10, fr.load_bundle, MODEL_DIR, warmup=1, label="load_forecast_model")
    ab = joblib.load(os.path.join(MODEL_DIR, "anomaly_model.pkl"))
    fb = fr.load_bundle(MODEL_DIR)
    R["model_versions"] = {"anomaly": ab.get("version", "june-v2"), "forecast": fb.get("version")}

    # ---------- data access ----------
    if args.csv:
        csv = pd.read_csv(args.csv, parse_dates=["timestamp"]).sort_values("timestamp")
        end = csv.timestamp.max()
        fetch_recent = lambda: csv[csv.timestamp >= end - pd.Timedelta(hours=25)].reset_index(drop=True)
        start = pd.Timestamp(fr.FIRST_TRAIN_DAY) - pd.Timedelta(days=1)
        fetch_all = lambda: csv[csv.timestamp >= start].reset_index(drop=True)
        fetch_refit = fetch_all
        today = end.date()
        now = end.to_pydatetime()
        conn = None
    else:
        conn = get_conn()
        fetch_recent = lambda: ar.fetch_recent_rows_db(conn, hours=25)
        fetch_all = lambda: fr.fetch_all_readings_db(conn)
        fetch_refit = lambda: ar.fetch_readings_db(conn, days_back=75)
        now = datetime.now(PH_TZ).replace(tzinfo=None)
        today = now.date()

    # ---------- anomaly detection (what flush_buffer -> run_anomaly does every 5 minutes) ----------
    R["anomaly_db_fetch_25h"] = repeat(min(args.n, 50), fetch_recent, label="anomaly_db_fetch_25h")
    rows = fetch_recent()
    R["anomaly_rows_scored_from"] = len(rows)
    R["anomaly_score_latest"] = repeat(args.n, ar.score_latest, rows, ab, label="anomaly_score_latest")        # features + z-score + IF
    df = ar.add_features(pd.DataFrame(rows))
    df["time_zscore"] = ar.zscore(df, ab["time_baseline"])
    X = ab["scaler"].transform(df.iloc[[-1]][ab["features"]])
    R["anomaly_model_call_only"] = repeat(args.n, lambda: (ab["model"].predict(X), ab["model"].score_samples(X)), label="anomaly_model_call_only")
    R["anomaly_total_per_reading_median_ms"] = round(
        R["anomaly_db_fetch_25h"]["median_ms"] + R["anomaly_score_latest"]["median_ms"], 2)

    # ---------- forecast (what POST /forecast does) ----------
    R["forecast_db_fetch_all"] = repeat(min(args.nf, 10), fetch_all, warmup=1, label="forecast_db_fetch_all")
    raw = fetch_all()
    R["forecast_rows"] = len(raw)
    R["forecast_build_frame"] = repeat(args.nf, fr.build_frame, raw, ab, fb, today=today, warmup=1, label="forecast_build_frame")
    F = fr.build_frame(raw, ab, fb, today=today)
    d = F["df_full"][F["df_full"].date == F["today"]]
    cycle_kwh = float(raw["cumul_kwh"].iloc[-1]) if "cumul_kwh" in raw else 100.0
    cycle_end = next_cycle_end(today)
    R["forecast_now_svr_eom"] = repeat(args.nf, fr.forecast_now, F, fb, cycle_kwh, now, cycle_end, label="forecast_now_svr_eom")
    if hasattr(fr, "build_today"):                   # cached /forecast path (forecast_retrain.py with the cache)
        t, hist = ms(fr.build_history, raw, ab, fb, today)
        R["forecast_cached_history_build_ms"] = round(t, 1)
        if args.csv:
            win = raw[raw.timestamp >= pd.Timestamp(today) - pd.Timedelta(hours=fr.WINDOW_HOURS_BEFORE_TODAY)]
            fetch_win = lambda: win
        else:
            fetch_win = lambda: fr.fetch_window_readings_db(conn, today)
        R["forecast_cached_window_fetch"] = repeat(min(args.nf, 10), fetch_win, label="forecast_cached_window_fetch")
        win = fetch_win()
        R["forecast_cached_build_today"] = repeat(args.nf, fr.build_today, win, ab, fb, hist, label="forecast_cached_build_today")
    f = fr.forecast_now(F, fb, cycle_kwh, now, cycle_end)
    try:
        from meralco_engine import compute_bill, RATE_SCHEDULE_DIR
        pdfs = sorted(p for p in os.listdir(RATE_SCHEDULE_DIR) if p.endswith(".pdf"))
        if pdfs:
            R["forecast_compute_bill"] = repeat(min(args.nf, 10), compute_bill, pdfs[-1],
                                                round(f["projected_eom_calibrated_kWh"]), warmup=1)
    except Exception as e:
        R["forecast_compute_bill"] = {"skipped": str(e)}
    parts = ["forecast_db_fetch_all", "forecast_build_frame", "forecast_now_svr_eom", "forecast_compute_bill"]
    R["forecast_total_median_ms"] = round(sum(R[p]["median_ms"] for p in parts if "median_ms" in R.get(p, {})), 2)
    R["peak_memory_mb_inference"] = peak_rss_mb()

    # ---------- optional: full API round trip ----------
    if args.http:
        import urllib.request
        def call():
            req = urllib.request.Request(args.url, data=b"", method="POST")
            with urllib.request.urlopen(req, timeout=120) as r:
                r.read()
        R["forecast_http_round_trip"] = repeat(min(args.nf, 10), call, warmup=1, label="forecast_http_round_trip")

    # ---------- optional: refits (computed, never saved) ----------
    if args.refit:
        print("  timing anomaly refit ...", flush=True)
        readings = fetch_refit()
        t, _ = ms(ar.refit, readings, ab)
        R["anomaly_refit_ms"] = round(t, 1)
        print("  timing forecast refit ...", flush=True)
        t, _ = ms(fr.refit, raw, fb, ab, today=today, reason="timing")
        R["forecast_refit_ms"] = round(t, 1)
        R["peak_memory_mb_with_refit"] = peak_rss_mb()

    if conn is not None:
        conn.close()

    with open("ml_timing_results.json", "w") as fo:
        json.dump(R, fo, indent=2, default=str)

    print("\nStage                                   median     p95      max   (ms)")
    for k, v in R.items():
        if isinstance(v, dict) and "median_ms" in v:
            print(f"{k:<38}{v['median_ms']:>9.2f}{v['p95_ms']:>9.2f}{v['max_ms']:>9.2f}")
    for k in ("anomaly_total_per_reading_median_ms", "forecast_total_median_ms", "forecast_cached_history_build_ms", "anomaly_refit_ms",
              "forecast_refit_ms", "peak_memory_mb_inference", "peak_memory_mb_with_refit"):
        if k in R:
            print(f"{k}: {R[k]}")
    print("\nSaved ml_timing_results.json")


if __name__ == "__main__":
    main()
