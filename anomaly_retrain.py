"""
anomaly_retrain.py
Shared anomaly-model code for GRID. The SAME file is used in two places:

    VM       : imported by main.py (live features, drift check, refit, hot reload)
    Notebook : imported by GRID_Anomaly_Drift_Check.ipynb (check only: drift status, replay,
               and a preview of what the VM refit would produce; nothing is saved or uploaded)

Retraining happens only on the VM. Keeping one file means the notebook checks exactly
the logic the VM runs, and live features match training features.

Rules (from the anomaly pipeline, GRID_Anomaly_Pipeline_v2):
    features      12 inputs, built by add_features() exactly as in the notebook
    baseline      mean/std of power per (hour, weekday/weekend), std floored at 10% of the window std
    drift         14-day mean of full-day kWh outside ±15% of the model's reference level
    cooldown      after a refit, drift is checked only once a full 14-day window lies after it
    refit window  30 most recent full days before the trigger (about one billing cycle),
                  minus readings the owner confirmed as anomalies (acknowledged = TRUE)
    refit model   same Isolation Forest settings as the current bundle (no re-tuning)

No Firebase / FastAPI code here. Database access is optional (only the *_db helpers).
"""

import os
import shutil
from datetime import datetime

import joblib
import numpy as np
import pandas as pd
import sklearn
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler

# ======================================================================
# CONFIG
# ======================================================================
NORMAL_MIN = 5              # sampling interval (minutes)
GAP_MULT = 1.5              # a gap > 7.5 min is a gap
MAX_REPAIR_MIN = 60         # gaps up to 60 min are repaired; longer ones are left as outages
FULL_DAY_ROWS = 270         # a day with >= 270 of 288 readings is a full day
Z_THR = 3.0

DRIFT_WINDOW_DAYS = 14
DRIFT_BAND = 0.15
DRIFT_MIN_DAYS = 10         # rolling mean needs at least 10 full days in the 14
REFIT_FULL_DAYS = 30
REFIT_MAX_LOOKBACK = 60     # look back at most 60 calendar days to find the 30 full days
REFIT_MIN_FULL_DAYS = 14    # same minimum as the June training gate
REFIT_MIN_WEEKENDS = 2

ALL_FEATURES = ["Voltage (V)", "Current (A)", "Power (W)", "Interval kWh", "Roll mean 1hr", "Roll mean 24hr",
                "Dev 1hr", "Dev 24hr", "Power Delta", "hour_sin", "hour_cos", "is_weekend", "time_zscore"]

REQUIRED_KEYS = ("model", "scaler", "features", "time_baseline", "min_std_time", "drift")


# ======================================================================
# DATA PREP (identical to the pipeline notebook)
# ======================================================================
def _prep(df):
    df = df.copy()
    df["timestamp"] = pd.to_datetime(df["timestamp"])
    for c in ("voltage", "current", "power_avg", "interval_kwh", "cumul_kwh"):
        if c in df:
            df[c] = df[c].astype(float)
    return df.sort_values("timestamp").reset_index(drop=True)


def repair_gaps(df):
    """Spread the energy of a 7.5–60 min gap over the missing 5-min slots (notebook cell 'repair_gaps')."""
    df = _prep(df)
    df["is_synthetic"] = False
    gap = df.timestamp.diff().dt.total_seconds() / 60
    fix = df.index[(gap > NORMAL_MIN * GAP_MULT) & (gap <= MAX_REPAIR_MIN)]
    new_rows, drop = [], []
    for i in fix:
        p, c = df.loc[i - 1], df.loc[i]
        n = max(int(round(gap[i] / NORMAL_MIN)), 1)
        per = c.interval_kwh / n
        cum = p.cumul_kwh if "cumul_kwh" in df else 0.0
        for k in range(1, n + 1):
            f = k / n
            cum += per
            row = {
                "timestamp": p.timestamp + pd.Timedelta(minutes=NORMAL_MIN * k) if k < n else c.timestamp,
                "voltage": p.voltage + (c.voltage - p.voltage) * f,
                "current": p.current + (c.current - p.current) * f,
                "power_avg": p.power_avg + (c.power_avg - p.power_avg) * f,
                "interval_kwh": per, "cumul_kwh": cum, "is_synthetic": k < n,
            }
            if "id" in df:
                row["id"] = c["id"] if k == n else np.nan   # keep the real row's id on the real row
            new_rows.append(row)
        drop.append(i)
    out = pd.concat([df.drop(index=drop), pd.DataFrame(new_rows)], ignore_index=True)
    return out.sort_values("timestamp").reset_index(drop=True)


def add_features(df):
    """All 13 candidate features (notebook cell 'add_features'). time_zscore is added by zscore()."""
    df = _prep(df)
    s = df.set_index("timestamp")["power_avg"]
    df["Roll mean 1hr"] = s.rolling("1h", min_periods=1).mean().values
    df["Roll mean 24hr"] = s.rolling("24h", min_periods=1).mean().values
    df["Dev 1hr"] = df.power_avg - df["Roll mean 1hr"]
    df["Dev 24hr"] = df.power_avg - df["Roll mean 24hr"]
    gap = df.timestamp.diff().dt.total_seconds() / 60
    df["Power Delta"] = df.power_avg.diff().where(gap <= MAX_REPAIR_MIN, 0).fillna(0)
    h = df.timestamp.dt.hour
    df["hour_sin"], df["hour_cos"] = np.sin(2 * np.pi * h / 24), np.cos(2 * np.pi * h / 24)
    df["is_weekend"] = (df.timestamp.dt.dayofweek >= 5).astype(int)
    df["Voltage (V)"], df["Current (A)"] = df.voltage, df.current
    df["Power (W)"], df["Interval kWh"] = df.power_avg, df.interval_kwh
    return df


def fit_baseline(train):
    t = train.assign(hour=train.timestamp.dt.hour, wk=(train.timestamp.dt.dayofweek >= 5).astype(int))
    b = t.groupby(["hour", "wk"]).power_avg.agg(mu="mean", sd="std")
    floor = float(train.power_avg.std() * 0.1)
    b["sd"] = b.sd.fillna(floor).clip(lower=floor)
    base = {(int(k[0]), int(k[1])): (float(r.mu), float(r.sd)) for k, r in b.iterrows()}
    # a bucket with no readings in the window keeps a safe default (window mean, floor)
    for hr in range(24):
        for wk in (0, 1):
            base.setdefault((hr, wk), (float(train.power_avg.mean()), floor))
    return base, floor


def zscore(df, base):
    keys = zip(df.timestamp.dt.hour, (df.timestamp.dt.dayofweek >= 5).astype(int))
    mu_sd = np.array([base[(int(h), int(w))] for h, w in keys])
    return (df.power_avg.values - mu_sd[:, 0]) / mu_sd[:, 1]


# ======================================================================
# LIVE SCORING (used by main.py run_anomaly)
# ======================================================================
def score_latest(rows, bundle):
    """rows: readings covering at least the last 24 h, oldest first, the newest row last
    (dicts or a DataFrame with timestamp, voltage, current, power_avg, interval_kwh).
    Returns the same keys main.py already logs to anomaly_logs."""
    df = add_features(pd.DataFrame(rows))
    df["time_zscore"] = zscore(df, bundle["time_baseline"])
    last = df.iloc[[-1]]
    X = bundle["scaler"].transform(last[bundle["features"]])
    pred = bundle["model"].predict(X)[0]
    score = bundle["model"].score_samples(X)[0]
    r = last.iloc[0]
    return {
        "status": "ok",
        "is_anomaly": bool(pred == -1),
        "score": round(float(score), 4),
        "roll_mean_1hr": round(float(r["Roll mean 1hr"]), 4),
        "roll_mean_24hr": round(float(r["Roll mean 24hr"]), 4),
        "dev_1hr": round(float(r["Dev 1hr"]), 4),
        "dev_24hr": round(float(r["Dev 24hr"]), 4),
        "power_delta": round(float(r["Power Delta"]), 4),
        "time_zscore": round(float(r["time_zscore"]), 4),
        "model_version": bundle.get("version", "june-v2"),
    }


# ======================================================================
# DRIFT CHECK
# ======================================================================
def daily_full_totals(readings):
    df = _prep(readings)
    g = df.groupby(df.timestamp.dt.normalize()).interval_kwh.agg(["sum", "size"])
    return g.loc[g["size"] >= FULL_DAY_ROWS, "sum"]


def _last_refit(bundle):
    """Date after which drift may be checked. For the original June model: day after training ends."""
    d = bundle["drift"]
    if d.get("last_refit"):
        return pd.Timestamp(d["last_refit"])
    return pd.Timestamp(bundle["train_window"][1]) + pd.Timedelta(days=1)


def check_drift(readings, bundle, as_of=None):
    """Return a dict: drift (bool), 14-day mean, reference level, band, reason."""
    daily = daily_full_totals(readings)
    as_of = pd.Timestamp(as_of).normalize() if as_of is not None else daily.index.max()
    daily = daily[daily.index <= as_of]
    level = float(bundle["drift"]["train_mean_daily_kwh"])
    band = float(bundle["drift"].get("band", DRIFT_BAND))
    win = int(bundle["drift"].get("window_days", DRIFT_WINDOW_DAYS))
    since = _last_refit(bundle)
    out = {"as_of": str(as_of.date()), "level": round(level, 3), "band": band,
           "low": round(level * (1 - band), 3), "high": round(level * (1 + band), 3),
           "checks_allowed_from": str((since + pd.Timedelta(days=win - 1)).date())}
    recent = daily[daily.index > as_of - pd.Timedelta(days=win)]
    out["full_days_in_window"] = int(len(recent))
    if as_of - pd.Timedelta(days=win - 1) < since:
        return {**out, "drift": False, "mean_14d": None, "reason": "cooldown after last refit"}
    if len(recent) < DRIFT_MIN_DAYS:
        return {**out, "drift": False, "mean_14d": None, "reason": f"only {len(recent)} full days in window"}
    m = float(recent.mean())
    dev = (m - level) / level
    return {**out, "drift": abs(dev) > band, "mean_14d": round(m, 3), "deviation_pct": round(dev * 100, 1),
            "reason": "outside band" if abs(dev) > band else "inside band"}


def replay_drift(readings, bundle, end=None):
    """Replay the rule day by day (refit simulated by moving the reference level). Used by the check notebook."""
    daily = daily_full_totals(readings)
    end = pd.Timestamp(end) if end is not None else daily.index.max()
    level = float(bundle["drift"]["train_mean_daily_kwh"])
    since = _last_refit(bundle)
    r14 = daily.rolling(f"{DRIFT_WINDOW_DAYS}D", min_periods=DRIFT_MIN_DAYS).mean()
    events = []
    for d, v in r14.items():
        if d > end or d < since + pd.Timedelta(days=DRIFT_WINDOW_DAYS - 1) or np.isnan(v):
            continue
        if abs(v - level) / level > DRIFT_BAND:
            days = refit_days(daily, d)
            new = float(daily[daily.index.isin(days)].mean())
            events.append({"trigger": d.date(), "mean_14d": round(v, 2), "old_level": round(level, 2),
                           "change_pct": round((v - level) / level * 100, 1),
                           "refit_from": days[0].date(), "refit_to": days[-1].date(), "full_days": len(days),
                           "new_level": round(new, 2)})
            level, since = new, d
    return pd.DataFrame(events), r14


# ======================================================================
# REFIT
# ======================================================================
def refit_days(daily, trigger):
    """30 most recent full days before the trigger day (outage days are skipped)."""
    trigger = pd.Timestamp(trigger).normalize()
    cand = daily[(daily.index < trigger) & (daily.index >= trigger - pd.Timedelta(days=REFIT_MAX_LOOKBACK))]
    return list(cand.index[-REFIT_FULL_DAYS:])


def refit(readings, bundle, trigger=None, confirmed_ids=(), confirmed_ts=(), seed=42):
    """Build a new bundle from the 30 full days before `trigger` (default: tomorrow of last reading).
    readings      : all readings (needs >= 24 h before the window for the rolling features)
    confirmed_ids : reading ids the owner confirmed as anomalies (anomaly_logs.acknowledged = TRUE)
    confirmed_ts  : alternatively, their timestamps (used when ids are not available, e.g. a CSV export)
    Returns (new_bundle, report). Raises ValueError if the window fails the gate."""
    raw = _prep(readings)
    trigger = (pd.Timestamp(trigger).normalize() if trigger is not None
               else raw.timestamp.max().normalize())
    daily = daily_full_totals(raw)
    days = refit_days(daily, trigger)
    weekends = sum(1 for d in days if d.dayofweek == 5 and d + pd.Timedelta(days=1) in days)
    if len(days) < REFIT_MIN_FULL_DAYS or weekends < REFIT_MIN_WEEKENDS:
        raise ValueError(f"refit gate failed: {len(days)} full days, {weekends} full weekends")

    clean = repair_gaps(raw)
    feat = add_features(clean)                           # features on the full series first
    in_win = feat.timestamp.dt.normalize().isin(days)
    drop = np.zeros(len(feat), bool)
    if len(confirmed_ids) and "id" in feat:
        drop |= feat["id"].isin(set(int(i) for i in confirmed_ids)).values
    if len(confirmed_ts):
        drop |= feat.timestamp.isin(pd.to_datetime(list(confirmed_ts))).values
    win = feat[in_win & ~drop].copy()

    base, floor = fit_baseline(win)
    win["time_zscore"] = zscore(win, base)
    feats = list(bundle["features"])
    sc = StandardScaler().fit(win[feats])
    p = bundle["model"].get_params()
    model = IsolationForest(n_estimators=p["n_estimators"], contamination=p["contamination"],
                            max_features=p["max_features"], random_state=seed, n_jobs=-1).fit(sc.transform(win[feats]))
    level = float(daily[daily.index.isin(days)].mean())
    now = datetime.now()
    new = {
        "model": model, "scaler": sc, "features": feats, "model_name": "Isolation Forest",
        "time_baseline": base, "min_std_time": floor, "zscore_threshold": Z_THR, "max_repair_gap_min": MAX_REPAIR_MIN,
        "train_window": (str(days[0].date()), str(days[-1].date())),
        "val_window": None,                               # refit keeps the validated June settings
        "gate": {"full_days": len(days), "full_weekends": weekends, "rows": int(len(win)),
                 "confirmed_removed": int((in_win & drop).sum()), "passed": True},
        "drift": {"train_mean_daily_kwh": level, "band": DRIFT_BAND, "window_days": DRIFT_WINDOW_DAYS,
                  "last_refit": str(trigger.date())},
        "params_from": bundle.get("version", "june-v2"),
        "version": f"refit-{trigger:%Y%m%d}",
        "trained_at": now.isoformat(timespec="seconds"),
        "sklearn_version": sklearn.__version__,
        "seed": seed,
    }
    report = {"trigger": str(trigger.date()), "window": new["train_window"], **new["gate"],
              "old_level": round(float(bundle["drift"]["train_mean_daily_kwh"]), 3), "new_level": round(level, 3)}
    return new, report


# ======================================================================
# SAVE / LOAD / VALIDATE
# ======================================================================
def validate_bundle(bundle, sample_rows=None):
    """Raise if the bundle cannot be used live. sample_rows: recent readings for a smoke test."""
    missing = [k for k in REQUIRED_KEYS if k not in bundle]
    if missing:
        raise ValueError(f"bundle missing keys: {missing}")
    bad = [f for f in bundle["features"] if f not in ALL_FEATURES]
    if bad:
        raise ValueError(f"unknown features: {bad}")
    if len(bundle["time_baseline"]) != 48:
        raise ValueError("time_baseline must have 48 (hour, weekend) buckets")
    if sample_rows is not None and len(sample_rows) >= 2:
        score_latest(sample_rows, bundle)
    return True


def save_incoming(bundle, models_dir):
    """Write the new bundle to models/incoming/ (atomic). main.py's watcher installs it."""
    inc = os.path.join(models_dir, "incoming")
    os.makedirs(inc, exist_ok=True)
    tmp = os.path.join(inc, ".anomaly_model.pkl.tmp")
    joblib.dump(bundle, tmp)
    final = os.path.join(inc, "anomaly_model.pkl")
    os.replace(tmp, final)
    return final


def install_incoming(models_dir, sample_rows=None):
    """If models/incoming/anomaly_model.pkl exists: load, validate, archive the live one, move it in.
    Returns the new bundle, or None if there was nothing to install. A bad file is moved to rejected/."""
    inc = os.path.join(models_dir, "incoming", "anomaly_model.pkl")
    if not os.path.exists(inc):
        return None
    try:
        bundle = joblib.load(inc)
        validate_bundle(bundle, sample_rows)
    except Exception as e:
        rej = os.path.join(models_dir, "rejected")
        os.makedirs(rej, exist_ok=True)
        shutil.move(inc, os.path.join(rej, f"anomaly_model_{datetime.now():%Y%m%d_%H%M%S}.pkl"))
        raise ValueError(f"incoming model rejected: {e}")
    live = os.path.join(models_dir, "anomaly_model.pkl")
    arch = os.path.join(models_dir, "archive")
    os.makedirs(arch, exist_ok=True)
    if os.path.exists(live):
        shutil.copy2(live, os.path.join(arch, f"anomaly_model_{datetime.now():%Y%m%d_%H%M%S}.pkl"))
    os.replace(inc, live)
    return bundle


# ======================================================================
# DATABASE HELPERS (VM only; psycopg2 connection passed in)
# ======================================================================
def _query_df(conn, q, params):
    """Run a query with a plain psycopg2 cursor (avoids pandas' SQLAlchemy warning)."""
    with conn.cursor() as cur:
        cur.execute(q, params)
        cols = [d[0] for d in cur.description]
        return pd.DataFrame(cur.fetchall(), columns=cols)


def fetch_readings_db(conn, days_back=75):
    q = """SELECT id, timestamp, voltage, current, power_avg, interval_kwh, cumul_kwh
           FROM readings WHERE timestamp >= (now() AT TIME ZONE 'Asia/Manila') - %s * interval '1 day'
           ORDER BY timestamp"""
    return _query_df(conn, q, (days_back,))


def fetch_recent_rows_db(conn, hours=25):
    q = """SELECT timestamp, voltage, current, power_avg, interval_kwh FROM readings
           WHERE timestamp >= (SELECT MAX(timestamp) FROM readings) - %s * interval '1 hour'
           ORDER BY timestamp"""
    return _query_df(conn, q, (hours,))


def fetch_confirmed_ids_db(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT reading_id FROM anomaly_logs WHERE acknowledged IS TRUE AND reading_id IS NOT NULL")
        return [r[0] for r in cur.fetchall()]


def run_daily_check(conn, bundle, models_dir, auto_refit=True):
    """One drift check on the VM. If drift and auto_refit: refit and drop the new pkl in incoming/.
    Returns a status dict (main.py pushes it to Firebase /anomaly_model/status)."""
    readings = fetch_readings_db(conn)
    status = check_drift(readings, bundle)
    status["model_version"] = bundle.get("version", "june-v2")
    if status["drift"] and auto_refit:
        new, report = refit(readings, bundle, confirmed_ids=fetch_confirmed_ids_db(conn))
        validate_bundle(new, fetch_recent_rows_db(conn))
        save_incoming(new, models_dir)
        status["refit"] = report
    return status


if __name__ == "__main__":
    # Manual use on the VM:  GRID_DB_PASSWORD=... python anomaly_retrain.py [--refit]
    import sys
    import psycopg2
    # DB settings from environment variables (same values as DB_CONFIG in main.py)
    DB_CONFIG = {"dbname": os.getenv("GRID_DB_NAME", "energy_db"), "user": os.getenv("GRID_DB_USER", "energy_user"),
                 "password": os.environ["GRID_DB_PASSWORD"], "host": os.getenv("GRID_DB_HOST", "localhost"),
                 "port": int(os.getenv("GRID_DB_PORT", "5432"))}
    MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")
    conn = psycopg2.connect(**DB_CONFIG)
    b = joblib.load(os.path.join(MODEL_DIR, "anomaly_model.pkl"))
    if "--refit" in sys.argv:
        r = fetch_readings_db(conn)
        new, rep = refit(r, b, confirmed_ids=fetch_confirmed_ids_db(conn))
        validate_bundle(new, fetch_recent_rows_db(conn))
        print(rep, "->", save_incoming(new, MODEL_DIR))
    else:
        print(check_drift(fetch_readings_db(conn), b))
