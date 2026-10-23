"""
forecast_retrain.py
Shared forecasting code for GRID (same pattern as anomaly_retrain.py):

    VM       : imported by main.py  (/forecast, weekly refit, refit after an anomaly-model change)
    Notebook : imported by GRID_Forecast_Check.ipynb (check only, nothing is saved)

Everything mirrors GRID_Forecasting_Pipeline_v3_2 (Step 2 tagging, Step 3 features,
LevelNormCols SVR, EWMA end-of-month projection, meter calibration):

    clean energy      readings NOT flagged by the current anomaly model
    SVR inputs        frac_day_elapsed, hour_sin, hour_cos, and four level-normalised inputs
                      (today_kwh_so_far, implied_total_profile, yesterday_total_kwh,
                      rolling_rate_1hr x288), each divided by ewm_daily_total (half-life 3 days)
    clean total       today_kwh_so_far + max(SVR remaining x level, 0)
    end of month      past days metered + clean total + anomalous so far
                      + scale x expected remaining anomalous energy + remaining days x EWMA(true daily kWh)
    billed kWh        k x projected end of month (k = Meralco kWh / IoT kWh, pooled = 1.097)

Refit (weekly, and whenever the anomaly model changes): same 7 inputs and SVR settings,
expanding window from the first training day to yesterday, thinned to <= 6,000 rows
(as in the notebook's weekly walk-forward check). When the anomaly model changed, the
history is re-flagged and the expected-anomaly profile and its base are recomputed from
the same days (Chapter III, HITL retraining); a plain weekly refit keeps them.
"""

import os
import shutil
from datetime import datetime

import joblib
import numpy as np
import pandas as pd
import sklearn
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVR

import anomaly_retrain as ar

# ======================================================================
# CONFIG (values from the v3.2 notebook)
# ======================================================================
FIRST_TRAIN_DAY = "2026-06-05"
KNOWN_PARTIAL_DAYS = ["2026-06-04", "2026-07-06", "2026-07-13", "2026-08-09", "2026-08-10",
                      "2026-09-25", "2026-09-29", "2026-10-01"]   # days the notebook excluded
FULL_DAY_ROWS = 270            # after the last listed day, any day with fewer readings is partial
EWMA_HALFLIFE = 3
ANOM_ADAPT_DAYS = 21
SVR_MAX_ROWS = 6000
REFIT_EVERY_DAYS = 7
MIN_TRAIN_DAYS = 14

LN_DEF = {"frac_day_elapsed": ("frac_day_elapsed", None), "hour_sin": ("hour_sin", None), "hour_cos": ("hour_cos", None),
          "ln_today_kwh_so_far": ("today_kwh_so_far", 1.0), "ln_implied_total_profile": ("implied_total_profile", 1.0),
          "ln_yesterday_total_kwh": ("yesterday_total_kwh", 1.0), "ln_rolling_rate_1hr": ("rolling_rate_1hr", 288.0)}


# ======================================================================
# FRAME: tag anomalies, three-way energy split, features (notebook Steps 2–3)
# ======================================================================
def _readings(raw):
    df = ar._prep(raw).drop_duplicates("timestamp")
    df = df.drop(columns=[c for c in ("id",) if c in df.columns])
    return ar.repair_gaps(df).drop(columns=["is_synthetic"], errors="ignore")


def build_frame(raw, anomaly_bundle, fb, today=None):
    """Returns dict(df_full, df, daily). `today` (date) is kept even though it is partial.
    fb supplies train_mean_total (cap for the profile-implied total)."""
    readings = _readings(raw)
    tag = ar.add_features(readings)
    tag["time_zscore"] = ar.zscore(tag, anomaly_bundle["time_baseline"])
    tag["is_anom"] = anomaly_bundle["model"].predict(
        anomaly_bundle["scaler"].transform(tag[anomaly_bundle["features"]])) == -1
    tag["date"] = tag.timestamp.dt.date
    today = pd.Timestamp(today).date() if today is not None else tag.date.max()

    n = tag.groupby("date").size()
    known = {pd.Timestamp(d).date() for d in KNOWN_PARTIAL_DAYS}
    cutoff = max(known)                                   # the notebook's list covers days up to here
    partial = known | {d for d in n.index[n < FULL_DAY_ROWS] if d > cutoff}
    partial.discard(today)
    df_full = tag[~tag.date.isin(partial)].reset_index(drop=True)
    df_full["clean_kwh"] = df_full.interval_kwh.where(~df_full.is_anom, 0.0)
    df_full["anom_kwh"] = df_full.interval_kwh.where(df_full.is_anom, 0.0)
    g = df_full.groupby("date")
    df_full["today_kwh_so_far"] = g.clean_kwh.cumsum()
    df_full["anomaly_kwh_so_far"] = g.anom_kwh.cumsum()
    df_full["true_kwh_so_far"] = df_full.today_kwh_so_far + df_full.anomaly_kwh_so_far
    daily = df_full.groupby("date").agg(true=("interval_kwh", "sum"), clean=("clean_kwh", "sum"),
                                        anom=("anom_kwh", "sum"), n=("interval_kwh", "size"))

    df = df_full[~df_full.is_anom].reset_index(drop=True).copy()
    df = df.merge(daily[["true", "clean"]].rename(columns={"true": "day_true", "clean": "day_clean"}),
                  left_on="date", right_index=True)
    df["remaining"] = df.day_clean - df.today_kwh_so_far
    df["Hour"] = df.timestamp.dt.hour
    df["frac_day_elapsed"] = (df.Hour * 60 + df.timestamp.dt.minute) / 1440.0
    df["rolling_rate_1hr"] = df.groupby("date").interval_kwh.transform(lambda s: s.rolling(12, min_periods=1).mean())

    train_mean_total = float(fb["train_mean_total"])
    s_level = pd.Series(daily.clean.values, index=pd.to_datetime(daily.index)).asfreq("D")
    prev_level = s_level.shift(1).ewm(halflife=EWMA_HALFLIFE, min_periods=1).mean().fillna(train_mean_total)
    hist = pd.DataFrame({"date": s_level.index.date, "ewm_daily_total": prev_level.values,
                         "yesterday_total_kwh": s_level.shift(1).fillna(prev_level).values})
    df = df.merge(hist, on="date", how="left")
    df["slot"] = (df.Hour * 60 + df.timestamp.dt.minute) // 15
    share = (df.assign(_s=df.today_kwh_so_far / df.day_clean.replace(0, np.nan)).groupby(["date", "slot"])._s.last()
               .unstack("slot").reindex(columns=range(96)).sort_index().ffill(axis=1).fillna(0.0))
    prof = share.shift(1).expanding(min_periods=1).mean().rename_axis(index="date")
    prof_long = prof.reset_index().melt(id_vars="date", var_name="slot", value_name="hist_cum_share")
    prof_long["slot"] = prof_long.slot.astype(int)
    df = df.merge(prof_long, on=["date", "slot"], how="left")
    df["hist_cum_share"] = df.hist_cum_share.fillna(df.frac_day_elapsed)
    df["implied_total_profile"] = (df.today_kwh_so_far / df.hist_cum_share.clip(lower=0.05)).clip(upper=3 * train_mean_total)
    return {"df_full": df_full, "df": df, "daily": daily, "today": today}


def add_ln(frame):
    lvl = frame.ewm_daily_total.clip(lower=1.0)
    for col, (src, mult) in LN_DEF.items():
        if mult is not None:
            frame[col] = frame[src] * mult / lvl
    return frame


def predict_clean_total(fb, rows):
    """rows: frame rows with the source columns. Returns today_kwh_so_far + max(remaining, 0)."""
    X = add_ln(rows.copy())
    lvl = X.ewm_daily_total.to_numpy().clip(min=1.0)
    rem = fb["svr"].predict(fb["scaler"].transform(X[fb["ln_columns"]])) * lvl
    return X.today_kwh_so_far.to_numpy() + np.maximum(rem, 0)


# ======================================================================
# EXPECTED ANOMALOUS ENERGY (notebook make_ctx)
# ======================================================================
def make_ctx(F, train_dates):
    tf = F["df_full"][F["df_full"].date.isin(set(train_dates))]
    tod = (tf.timestamp.dt.hour * 60 + tf.timestamp.dt.minute).values
    per_min = np.bincount(tod, weights=tf.anom_kwh.values, minlength=1440) / max(tf.date.nunique(), 1)
    exp = per_min[::-1].cumsum()[::-1] - per_min
    anom = F["daily"].anom
    base = float(anom[anom.index.isin(set(train_dates))].mean())
    return exp, base


def anomaly_scale(daily, day, base, adapt_days=ANOM_ADAPT_DAYS):
    prev = daily.anom[daily.index < day].tail(adapt_days)
    return float(prev.mean() / base) if len(prev) >= 3 and base > 0 else 1.0


# ======================================================================
# /forecast: today's prediction + end-of-month projection
# ======================================================================
def bracket_of(kwh, edges=(200, 300, 400)):
    labels = ["0-200", "201-300", "301-400", "over-400"]
    return labels[sum(kwh > e for e in edges)]


def forecast_now(F, fb, cycle_kwh_so_far, now, cycle_end):
    """F: build_frame(...) for data up to now. cycle_kwh_so_far: metered kWh since the cycle start
    (main.py's adjusted cumul_kwh). cycle_end: last day of the billing cycle (date)."""
    eom = fb["eom"]
    today = F["today"]
    d_full = F["df_full"][F["df_full"].date == today]
    d_clean = F["df"][F["df"].date == today]
    minute = now.hour * 60 + now.minute
    true_so_far = float(d_full.interval_kwh.sum())
    anom_so_far = float(d_full.anom_kwh.sum())

    if len(d_clean):
        row = d_clean.iloc[[-1]].copy()
        clean_total = float(predict_clean_total(fb, row)[0])
        level = float(row.ewm_daily_total.iloc[0])
    else:                                          # no clean reading yet today: level only
        daily = F["daily"]
        prev = daily.clean[daily.index < today]
        level = float(pd.Series(prev.values).ewm(halflife=EWMA_HALFLIFE).mean().iloc[-1]) if len(prev) else fb["train_mean_total"]
        clean_total = level

    scale = anomaly_scale(F["daily"], today, eom["anomaly_train_mean_kwh_day"])
    exp_rest = float(eom["exp_remaining_anomaly_kwh_by_minute"][min(minute, 1439)])
    day_total = clean_total + anom_so_far + scale * exp_rest

    day_true = F["daily"]["true"]
    hist = day_true[day_true.index < today]
    ewma_daily = float(hist.ewm(halflife=eom["ewma_halflife"]).mean().iloc[-1]) if len(hist) else day_total
    days_remaining = max((cycle_end - today).days, 0)
    past = max(cycle_kwh_so_far - true_so_far, 0.0)
    projected = past + day_total + days_remaining * ewma_daily
    k = float(eom["k_pooled"])
    calibrated = projected * k
    return {
        "predicted_clean_kWh": round(clean_total, 4),
        "anomalous_so_far_kWh": round(anom_so_far, 4),
        "expected_rest_anomalous_kWh": round(scale * exp_rest, 4),
        "predicted_day_total_kWh": round(day_total, 4),
        "today_so_far_kWh": round(true_so_far, 4),
        "accumulated_past_kWh": round(past, 4),
        "combined_kWh": round(past + day_total, 4),
        "ewma_daily_kWh": round(ewma_daily, 4),
        "days_remaining": days_remaining,
        "projected_eom_kWh": round(projected, 4),
        "calibration_k": k,
        "projected_eom_calibrated_kWh": round(calibrated, 4),
        "bracket": bracket_of(calibrated, eom.get("tier_edges", (200, 300, 400))),
        "level_kWh": round(level, 4),
        "forecast_version": fb.get("version", "v3.2-june"),
    }


# ======================================================================
# CACHED FRAME for /forecast (same result as build_frame, much less work per request)
#   build_history : everything forecast_now needs from the days BEFORE today.
#                   Built once per day, and again when a model or the stored past readings change.
#   build_today   : only today's readings (plus 48 h before, for the 24 h rolling features),
#                   combined with the stored history. Runs on every request.
# ======================================================================
WINDOW_HOURS_BEFORE_TODAY = 48


def _profile_share(df):
    """Cumulative share of the day's clean energy reached by each 15-min slot, one row per date
    (identical to the 'share' table inside build_frame)."""
    return (df.assign(_s=df.today_kwh_so_far / df.day_clean.replace(0, np.nan)).groupby(["date", "slot"])._s.last()
              .unstack("slot").reindex(columns=range(96)).sort_index().ffill(axis=1).fillna(0.0))


def build_history(raw, anomaly_bundle, fb, today):
    """raw: all readings (fetch_all_readings_db). today: date the cache is for.
    Returns the past-day summary used by build_today."""
    today = pd.Timestamp(today).date()
    F = build_frame(raw, anomaly_bundle, fb, today=today)
    daily = F["daily"][F["daily"].index < today]
    past = F["df"][F["df"].date < today]
    share = _profile_share(past) if len(past) else pd.DataFrame(columns=range(96))
    hist_share = share.mean(axis=0).reindex(range(96))       # = expanding mean of all earlier days at `today`

    # level and yesterday's total for `today`, exactly as build_frame computes them
    train_mean_total = float(fb["train_mean_total"])
    idx = pd.to_datetime(list(daily.index) + [today])
    s_level = pd.Series(list(daily.clean.values) + [np.nan], index=idx).asfreq("D")
    prev_level = s_level.shift(1).ewm(halflife=EWMA_HALFLIFE, min_periods=1).mean().fillna(train_mean_total)
    yesterday = s_level.shift(1).fillna(prev_level)
    t = pd.Timestamp(today)
    return {"today": today, "daily": daily, "hist_share": hist_share,
            "ewm_daily_total": float(prev_level.loc[t]), "yesterday_total_kwh": float(yesterday.loc[t]),
            "train_mean_total": train_mean_total,
            "anomaly_version": anomaly_bundle.get("version", "june-v2"), "forecast_version": fb.get("version")}


def build_today(raw_window, anomaly_bundle, fb, hist):
    """raw_window: readings from (today - 48 h) up to now. Returns the same dict shape as build_frame,
    restricted to what forecast_now uses (today's rows + the past daily table)."""
    today = hist["today"]
    tag = ar.add_features(_readings(raw_window))
    tag["time_zscore"] = ar.zscore(tag, anomaly_bundle["time_baseline"])
    tag["is_anom"] = anomaly_bundle["model"].predict(
        anomaly_bundle["scaler"].transform(tag[anomaly_bundle["features"]])) == -1
    tag["date"] = tag.timestamp.dt.date
    d = tag[tag.date == today].reset_index(drop=True)
    d["clean_kwh"] = d.interval_kwh.where(~d.is_anom, 0.0)
    d["anom_kwh"] = d.interval_kwh.where(d.is_anom, 0.0)
    d["today_kwh_so_far"] = d.clean_kwh.cumsum()
    d["anomaly_kwh_so_far"] = d.anom_kwh.cumsum()
    d["true_kwh_so_far"] = d.today_kwh_so_far + d.anomaly_kwh_so_far

    df = d[~d.is_anom].reset_index(drop=True).copy()
    df["Hour"] = df.timestamp.dt.hour
    df["frac_day_elapsed"] = (df.Hour * 60 + df.timestamp.dt.minute) / 1440.0
    df["rolling_rate_1hr"] = df.interval_kwh.rolling(12, min_periods=1).mean()
    df["ewm_daily_total"] = hist["ewm_daily_total"]
    df["yesterday_total_kwh"] = hist["yesterday_total_kwh"]
    df["slot"] = (df.Hour * 60 + df.timestamp.dt.minute) // 15
    df["hist_cum_share"] = df.slot.map(hist["hist_share"]).astype(float).fillna(df.frac_day_elapsed)
    df["implied_total_profile"] = (df.today_kwh_so_far / df.hist_cum_share.clip(lower=0.05)).clip(
        upper=3 * hist["train_mean_total"])
    return {"df_full": d, "df": df, "daily": hist["daily"], "today": today}


# ======================================================================
# REFIT
# ======================================================================
def refit_due(fb, anomaly_bundle, today):
    if fb.get("anomaly_version") != anomaly_bundle.get("version", "june-v2"):
        return True, "anomaly model changed"
    last = pd.Timestamp(fb.get("last_refit") or fb["train_window"][1]).date()
    if (pd.Timestamp(today).date() - last).days >= REFIT_EVERY_DAYS:
        return True, "weekly refit"
    return False, "not due"


def refit(raw, fb, anomaly_bundle, today=None, reason="manual"):
    """Expanding window FIRST_TRAIN_DAY .. yesterday, same inputs and settings. Returns (new_fb, report)."""
    stub = {**fb}
    F = build_frame(raw, anomaly_bundle, stub, today=today)
    today = F["today"]
    first = pd.Timestamp(FIRST_TRAIN_DAY).date()
    tr = F["df"][(F["df"].date >= first) & (F["df"].date < today)]
    days = sorted(tr.date.unique())
    if len(days) < MIN_TRAIN_DAYS:
        raise ValueError(f"forecast refit gate failed: only {len(days)} full days")

    # train_mean_total stays the June value: it only caps the profile-implied total
    tr = add_ln(tr.copy())
    rows = tr.iloc[::int(np.ceil(len(tr) / SVR_MAX_ROWS))] if len(tr) > SVR_MAX_ROWS else tr
    cols = list(fb["ln_columns"])
    lvl = rows.ewm_daily_total.to_numpy().clip(min=1.0)
    sc = StandardScaler().fit(rows[cols])
    p = fb["svr"].get_params()
    svr = SVR(kernel=p["kernel"], C=p["C"], epsilon=p["epsilon"], gamma=p["gamma"]).fit(
        sc.transform(rows[cols]), rows.remaining.to_numpy() / lvl)

    eom = dict(fb["eom"])
    anomaly_changed = fb.get("anomaly_version") != anomaly_bundle.get("version", "june-v2")
    if anomaly_changed:            # new definition of "anomalous": recompute the expected-anomaly profile
        exp, base = make_ctx(F, days)
        eom.update({"exp_remaining_anomaly_kwh_by_minute": exp, "anomaly_train_mean_kwh_day": base})
    new = {**{k: v for k, v in fb.items() if k not in ("scaler", "svr")},
           "scaler": sc, "svr": svr, "eom": eom,
           "train_window": (str(days[0]), str(days[-1])),
           "train_rows": int(len(rows)), "train_days": len(days),
           "anomaly_version": anomaly_bundle.get("version", "june-v2"),
           "last_refit": str(today), "refit_reason": reason,
           "version": f"svr-{pd.Timestamp(today):%Y%m%d}",
           "trained_at": datetime.now().isoformat(timespec="seconds"),
           "sklearn_version": sklearn.__version__}
    report = {"reason": reason, "window": new["train_window"], "days": len(days), "rows": int(len(rows)),
              "anomaly_version": new["anomaly_version"], "anomaly_profile_recomputed": anomaly_changed,
              "anomaly_base_kwh_day": round(float(eom["anomaly_train_mean_kwh_day"]), 4)}
    return new, report, F


# ======================================================================
# BUNDLE: load (merge the two notebook files), validate, save/install
# ======================================================================
JUNE_TRAIN_MEAN_TOTAL = 8.26165   # mean clean daily kWh, Jun 5–24 (v3.2 notebook, June anomaly model)


def load_bundle(models_dir="."):
    """Loads the forecast bundle. Works with the combined bundle (forecast_model_v32.pkl or a VM refit)
    and with the two original notebook files (forecast_model.pkl + eom_projection.pkl)."""
    fb = joblib.load(os.path.join(models_dir, "forecast_model.pkl"))
    if "eom" not in fb:                                   # original notebook output: two files
        eom_path = os.path.join(models_dir, "eom_projection.pkl")
        if not os.path.exists(eom_path):
            raise ValueError("forecast_model.pkl is the original notebook file: put eom_projection.pkl next to it, "
                             "or use the combined forecast_model_v32.pkl")
        fb["eom"] = joblib.load(eom_path)
    fb.setdefault("version", "v3.2-june")
    fb.setdefault("anomaly_version", "june-v2")
    fb.setdefault("train_mean_total", JUNE_TRAIN_MEAN_TOTAL)
    return fb


def validate_bundle(fb, F=None):
    for k in ("scaler", "svr", "ln_columns", "eom", "train_mean_total"):
        if k not in fb:
            raise ValueError(f"forecast bundle missing {k}")
    if F is not None:
        last = F["df"][F["df"].date < F["today"]].tail(288)
        if len(last):
            p = predict_clean_total(fb, last)
            if not np.all(np.isfinite(p)) or (p < 0).any():
                raise ValueError("forecast bundle gives invalid predictions on recent days")
    return True


def save_incoming(fb, models_dir):
    inc = os.path.join(models_dir, "incoming")
    os.makedirs(inc, exist_ok=True)
    tmp = os.path.join(inc, ".forecast_model.pkl.tmp")
    joblib.dump(fb, tmp, compress=3)
    final = os.path.join(inc, "forecast_model.pkl")
    os.replace(tmp, final)
    return final


def install_incoming(models_dir):
    inc = os.path.join(models_dir, "incoming", "forecast_model.pkl")
    if not os.path.exists(inc):
        return None
    try:
        fb = joblib.load(inc)
        validate_bundle(fb)
    except Exception as e:
        rej = os.path.join(models_dir, "rejected")
        os.makedirs(rej, exist_ok=True)
        shutil.move(inc, os.path.join(rej, f"forecast_model_{datetime.now():%Y%m%d_%H%M%S}.pkl"))
        raise ValueError(f"incoming forecast model rejected: {e}")
    live = os.path.join(models_dir, "forecast_model.pkl")
    arch = os.path.join(models_dir, "archive")
    os.makedirs(arch, exist_ok=True)
    if os.path.exists(live):
        shutil.copy2(live, os.path.join(arch, f"forecast_model_{datetime.now():%Y%m%d_%H%M%S}.pkl"))
    os.replace(inc, live)
    return fb


# ======================================================================
# DATABASE (VM)
# ======================================================================
def fetch_all_readings_db(conn):
    q = """SELECT timestamp, voltage, current, power_avg, interval_kwh, cumul_kwh
           FROM readings WHERE timestamp >= %s ORDER BY timestamp"""
    start = pd.Timestamp(FIRST_TRAIN_DAY) - pd.Timedelta(days=1)    # 24 h before, for rolling features
    return ar._query_df(conn, q, (start.to_pydatetime(),))


def fetch_window_readings_db(conn, today):
    """Readings from (today - 48 h) to now, for build_today."""
    q = """SELECT timestamp, voltage, current, power_avg, interval_kwh, cumul_kwh
           FROM readings WHERE timestamp >= %s ORDER BY timestamp"""
    start = pd.Timestamp(today) - pd.Timedelta(hours=WINDOW_HOURS_BEFORE_TODAY)
    return ar._query_df(conn, q, (start.to_pydatetime(),))


def past_readings_signature_db(conn, today):
    """(count, last timestamp) of the readings before today that the history is built from.
    If either changes (e.g. the last 5-min row of yesterday is written after midnight), the cache is rebuilt."""
    start = pd.Timestamp(FIRST_TRAIN_DAY) - pd.Timedelta(days=1)
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*), MAX(timestamp) FROM readings WHERE timestamp >= %s AND timestamp < %s",
                    (start.to_pydatetime(), pd.Timestamp(today).to_pydatetime()))
        n, last = cur.fetchone()
    return int(n), str(last)


def run_refit_if_due(conn, fb, anomaly_bundle, models_dir, today, force_reason=None):
    due, reason = (True, force_reason) if force_reason else refit_due(fb, anomaly_bundle, today)
    if not due:
        return {"refit": False, "reason": reason}
    new, report, F = refit(fetch_all_readings_db(conn), fb, anomaly_bundle, today=today, reason=reason)
    validate_bundle(new, F)
    save_incoming(new, models_dir)
    return {"refit": True, **report}
