"""
hitl_trigger.py — HITL retraining trigger (moved unchanged from HITL_Retraining_Check.ipynb)

Flow: flagged readings -> alert events (readings <= 10 min apart = one prompt) -> owner labels
-> DBSCAN on events labeled "normal" (false positives) -> retrain only if a recurring pattern exists.

Rule: a DBSCAN cluster of normal-labeled events whose start times are within +/-30 min (time of day,
circular) and whose peak power is within a factor of 1.25, with >= 5 events on >= 5 distinct days
inside a 14-day window.
"""
import numpy as np
import pandas as pd
from sklearn.cluster import DBSCAN

EVENT_GAP_MIN   = 10
TIME_TOL_MIN    = 30
POWER_TOL_RATIO = 1.25
MIN_EVENTS      = 5
MIN_DAYS        = 5
WINDOW_DAYS     = 14


def group_events(readings):
    """readings: flagged readings with timestamp, power_avg (and optionally time_zscore, score)."""
    d = readings.copy()
    d["timestamp"] = pd.to_datetime(d["timestamp"], format="ISO8601")
    d = d.sort_values("timestamp").reset_index(drop=True)
    for c in ("time_zscore", "score"):
        if c not in d:
            d[c] = np.nan
    gap = d["timestamp"].diff().dt.total_seconds().div(60)
    d["event_id"] = (gap.isna() | (gap > EVENT_GAP_MIN)).cumsum()
    ev = (d.groupby("event_id")
            .agg(start=("timestamp", "first"), end=("timestamp", "last"), n_readings=("timestamp", "size"),
                 peak_w=("power_avg", "max"), mean_w=("power_avg", "mean"),
                 max_z=("time_zscore", "max"), min_score=("score", "min"))
            .reset_index())
    ev["date"] = ev["start"].dt.date
    ev["minute"] = ev["start"].dt.hour * 60 + ev["start"].dt.minute
    ev["duration_min"] = (ev["end"] - ev["start"]).dt.total_seconds() / 60 + 5
    return d, ev


def pattern_distance(ev):
    t = ev["minute"].to_numpy(float)
    dt = np.abs(t[:, None] - t[None, :]); dt = np.minimum(dt, 1440 - dt)          # circular time of day
    lp = np.log(ev["peak_w"].to_numpy(float))
    dp = np.abs(lp[:, None] - lp[None, :])
    return np.maximum(dt / TIME_TOL_MIN, dp / np.log(POWER_TOL_RATIO))             # both must be within tolerance


def retrain_check(ev, label_col="owner_label"):
    fp = ev[ev[label_col] == "normal"].copy()
    if len(fp) < MIN_EVENTS:
        fp["cluster"] = -1
        return fp, pd.DataFrame(), False
    fp["cluster"] = DBSCAN(eps=1.0, min_samples=MIN_EVENTS, metric="precomputed").fit_predict(pattern_distance(fp))
    rows = []
    for c, g in fp[fp["cluster"] >= 0].groupby("cluster"):
        days = sorted(set(g["date"]))
        best = max(sum(1 for x in days if 0 <= (x - s).days < WINDOW_DAYS) for s in days)
        rows.append({"cluster": c, "events": len(g), "distinct_days": len(days), "max_days_in_window": best,
                     "time_range": f"{g['start'].dt.strftime('%H:%M').min()}–{g['start'].dt.strftime('%H:%M').max()}",
                     "peak_w_range": f"{g['peak_w'].min():.0f}–{g['peak_w'].max():.0f}",
                     "trigger": best >= MIN_DAYS})
    cl = pd.DataFrame(rows)
    return fp, cl, bool(len(cl) and cl["trigger"].any())


# ======================================================================
# OWNER LABELS (owner_labels.csv filled in by the household owner)
# ======================================================================
VALID_LABELS = {"normal", "anomaly", "unsure"}


def blank_label_form(ev, path):
    """Write the form the owner fills in: one row per event, no suggested labels (so the owner is not led)."""
    form = ev[["event_id", "start", "n_readings", "peak_w"]].copy()
    form["start"] = form["start"].dt.strftime("%Y-%m-%d %H:%M:%S")
    form["owner_label"] = ""
    form["owner_note"] = ""
    form.to_csv(path, index=False)
    return form


def apply_owner_labels(ev, path):
    """Merge the owner's labels onto the event table by start time (to the second).
    Uses ONLY the owner_label column; a blank answer counts as 'unsure' (no decision).
    Raises if events don't match, a label is not normal/anomaly/unsure, or the form is empty."""
    lab = pd.read_csv(path, dtype={"owner_label": str, "owner_note": str})
    lab["start"] = pd.to_datetime(lab["start"], format="ISO8601").dt.floor("s")
    lab["owner_label"] = lab["owner_label"].fillna("").str.strip().str.lower()
    if (lab["owner_label"] == "").all():
        raise ValueError("owner_label is empty for every event: the form has not been filled in by the owner")
    bad = sorted(set(lab["owner_label"]) - VALID_LABELS - {""})
    if bad:
        raise ValueError(f"unknown labels {bad}; use normal / anomaly / unsure")
    ev = ev.copy()
    ev["_start"] = ev["start"].dt.floor("s")
    m = ev.merge(lab[["start", "owner_label", "owner_note"]].rename(columns={"start": "_start"}),
                 on="_start", how="left", validate="one_to_one")
    missing = m["owner_label"].isna().sum()
    if missing or len(lab) != len(ev):
        raise ValueError(f"{missing} events have no row in {path} ({len(lab)} rows for {len(ev)} events)")
    m["owner_label"] = m["owner_label"].replace("", "unsure")
    return m.drop(columns="_start")


# ======================================================================
# VM: daily HITL check + automatic refit (same pattern as the drift refit)
# ======================================================================
def _labels_from_db(any_true, any_false):
    if any_true:
        return "anomaly"          # owner answered "real anomaly" (acknowledged = TRUE)
    if any_false:
        return "normal"           # owner answered "normal use"   (acknowledged = FALSE)
    return "unsure"               # "Hindi sigurado" or no answer  (acknowledged = NULL)


def fetch_labeled_events_db(conn, since):
    """One row per alert event in anomaly_logs since `since`, with the owner's answer as a label.
    The app writes the same answer to every row of an event, so any TRUE/FALSE decides the label."""
    q = """SELECT event_id, MIN(timestamp) AS start, MAX(timestamp) AS "end", COUNT(*) AS n_readings,
                  MAX(power_avg) AS peak_w, BOOL_OR(acknowledged) AS any_true,
                  BOOL_OR(NOT acknowledged) AS any_false
           FROM anomaly_logs WHERE event_id IS NOT NULL AND timestamp >= %s
           GROUP BY event_id ORDER BY start"""
    with conn.cursor() as cur:
        cur.execute(q, (pd.Timestamp(since).to_pydatetime(),))
        rows = cur.fetchall()
    ev = pd.DataFrame(rows, columns=["event_id", "start", "end", "n_readings", "peak_w", "any_true", "any_false"])
    return prepare_events(ev)


def prepare_events(ev):
    ev = ev.copy()
    ev["start"] = pd.to_datetime(ev["start"], format="ISO8601")
    ev["peak_w"] = ev["peak_w"].astype(float)
    if "owner_label" not in ev:
        ev["owner_label"] = [_labels_from_db(t, f) for t, f in zip(ev["any_true"], ev["any_false"])]
    ev["date"] = ev["start"].dt.date
    ev["minute"] = ev["start"].dt.hour * 60 + ev["start"].dt.minute
    return ev


def events_in_window(ev, since, as_of):
    """Events the rule may use today: after the last refit (so events already learned cannot
    trigger again) and inside the last WINDOW_DAYS days up to and including as_of."""
    as_of = pd.Timestamp(as_of).normalize()
    start = max(pd.Timestamp(since).normalize(), as_of - pd.Timedelta(days=WINDOW_DAYS - 1))
    keep = (ev["start"] >= start) & (ev["start"] < as_of + pd.Timedelta(days=1))
    return ev[keep].copy(), start


def check_hitl(ev, since, as_of):
    """Pure decision for one day. Returns a status dict like anomaly_retrain.check_drift()."""
    win, start = events_in_window(ev, since, as_of)
    fp, cl, trigger = retrain_check(win)
    return {"as_of": str(pd.Timestamp(as_of).date()), "window_start": str(start.date()),
            "events": int(len(win)), "normal_events": int(len(fp)),
            "anomaly_events": int((win["owner_label"] == "anomaly").sum()),
            "clusters": cl.to_dict("records") if len(cl) else [], "trigger": bool(trigger),
            "reason": ("recurring false alarms" if trigger else
                       f"no recurring pattern ({len(fp)} normal-labeled events)")}


def run_hitl_check(conn, bundle, models_dir, auto_refit=True, as_of=None):
    """Daily on the VM, after the drift check. If owner-labeled normal events recur (the rule above)
    and auto_refit: refit the anomaly model on the latest 30 full days and drop the pkl in incoming/.
    The recurring events lie inside those 30 days and are not confirmed anomalies, so the refit learns
    them as normal (Chapter III); confirmed anomalies are still removed. The forecast refit follows the
    install automatically ('anomaly model changed'), exactly as after a drift refit."""
    import anomaly_retrain as ar
    as_of = pd.Timestamp(as_of) if as_of is not None else pd.Timestamp.now(tz="Asia/Manila").tz_localize(None)
    since = ar._last_refit(bundle)
    ev = fetch_labeled_events_db(conn, max(since, as_of.normalize() - pd.Timedelta(days=WINDOW_DAYS)))
    status = {**check_hitl(ev, since, as_of), "since_last_refit": str(since.date()),
              "model_version": bundle.get("version", "june-v2")}
    if status["trigger"] and auto_refit:
        new, report = ar.refit(ar.fetch_readings_db(conn), bundle, confirmed_ids=ar.fetch_confirmed_ids_db(conn))
        new["refit_reason"] = "hitl: recurring false alarms"
        new["hitl"] = status["clusters"]
        ar.validate_bundle(new, ar.fetch_recent_rows_db(conn))
        ar.save_incoming(new, models_dir)
        status["refit"] = {**report, "reason": "hitl"}
    return status
