from fastapi import FastAPI, HTTPException, Query, Header
from typing import Optional, List
from meralco_engine import compute_bill, RATE_SCHEDULE_DIR, peso_to_kwh
from pydantic import BaseModel
from datetime import datetime, timedelta, time as dtime
from zoneinfo import ZoneInfo
import psycopg2
import psycopg2.extras
import joblib
import numpy as np
import pandas as pd
import calendar
import os
import re
import random
import firebase_admin
from firebase_admin import credentials, db as firebase_db, messaging
import asyncio
import threading
import anomaly_retrain as ar    # shared with GRID_Anomaly_Drift_Check.ipynb
import forecast_retrain as fr   # shared with GRID_Forecast_Check.ipynb
import hitl_trigger as hitl     # HITL retraining trigger (shared with HITL_Retraining_Check.ipynb)
import advisory_rules as nlg    # Tagalog NLG advisories (pure, no I/O)
import rate_compare             # month-over-month rate effect (linear rates, pure)

app = FastAPI()

# ── Timezone ───────────────────────────────────────────────────────────────────
PH_TZ = ZoneInfo("Asia/Manila")

# ── Firebase Setup ─────────────────────────────────────────────────────────────
FIREBASE_KEY_PATH = os.path.join(os.path.dirname(__file__), "firebase_key.json")
FIREBASE_DB_URL   = "https://kuro-ec80f-default-rtdb.firebaseio.com"

cred = credentials.Certificate(FIREBASE_KEY_PATH)
firebase_admin.initialize_app(cred, {"databaseURL": FIREBASE_DB_URL})

# ── Database Config ────────────────────────────────────────────────────────────
DB_CONFIG = {
    "dbname":   "energy_db",
    "user":     "energy_user",
    "password": "thesis1234",
    "host":     "localhost",
    "port":     5432,
}

# ── Load ML Models ─────────────────────────────────────────────────────────────
MODEL_DIR = os.path.join(os.path.dirname(__file__), "models")

# Forecast model (SVR, level-normalised inputs) + end-of-month settings in ONE bundle,
# swapped in one assignment like the anomaly model.
FORECAST_BUNDLE = fr.load_bundle(MODEL_DIR)
fr.validate_bundle(FORECAST_BUNDLE)
# ['today_kwh_so_far', 'frac_day_elapsed', 'Interval kWh', 'Hour', 'dow', 'Weekend']

# Anomaly model: the whole bundle is kept in ONE global and swapped in one assignment
# when a new model is installed (hot reload, no API restart). run_anomaly() reads it once
# per call, so a reading is always scored by a single, complete model.
# Features (12): Power Delta, Dev 1hr, is_weekend, Roll mean 1hr, time_zscore, Current (A),
#                Dev 24hr, Interval kWh, Power (W), hour_cos, hour_sin, Roll mean 24hr
ANOMALY_BUNDLE = joblib.load(os.path.join(MODEL_DIR, "anomaly_model.pkl"))
ar.validate_bundle(ANOMALY_BUNDLE)

AUTO_REFIT_FORECAST   = True   # weekly SVR refit + refit after an anomaly-model change
AUTO_REFIT            = True   # False = only report drift; refit manually on the VM: python anomaly_retrain.py --refit
AUTO_REFIT_HITL       = True   # False = only report recurring false alarms (no refit)
MODEL_WATCH_SECONDS   = 60     # how often models/incoming/ is checked
DRIFT_CHECK_HOUR      = 0      # daily drift check at 00:15 PH time (yesterday is complete)
DRIFT_CHECK_MINUTE    = 15
last_drift_check_date = ""

# ── In-Memory 5-Minute Buffer ──────────────────────────────────────────────────
reading_buffer = []   # list of dicts: {voltage, current, power, cumul_kwh, ts}
BUFFER_SECONDS = 300  # 5 minutes
last_pushed_hour = -1    # tracks last hour pushed to Firebase
last_pushed_date = ""    # tracks current date for midnight reset


# ── Billing Baseline ───────────────────────────────────────────────────────────
# Meralco billing cycle: 28th of month → 27th of next month
# BILLING_BASELINE_KWH is an ACCUMULATED value: it grows every cutover by
# adding that cycle's adjusted consumption on top of the previous baseline.
# It is persisted to Firebase (/billing/state) so a server restart never
# loses the running total.
BILLING_BASELINE_KWH  = 0.0
BILLING_CUTOFF_DATE   = ""
BILLING_COMPUTED = 0.0
BILLING_STATE_REF      = "/billing/state"

# ── Sync Watchdog ──────────────────────────────────────────────────────────────
last_reading_ts      = None   # updated on every /reading POST
SYNC_TIMEOUT_SECONDS = 60     # seconds before sync = false
last_sync_state = True        # tracks previous sync state to detect transition

# ── Meralco Rates ──────────────────────────────────────────────────────────────
MERALCO_RATES = None  # loaded once on startup from Firebase

#---- Tracking current kwh ------------
today_total_kwh = 0.0

# ── Flush Lock ─────────────────────────────────────────────────────────────────
_flush_lock = threading.Lock()

# ── NLG Advisories ─────────────────────────────────────────────────────────────
ADVISORY_REF        = "/advisories"            # /advisories/{category}
BRACKET_STATE_REF   = "/advisories_state/bracket"
ANOMALY_EVENT       = None                     # current anomaly event (in memory)
LAST_PUSH           = {}                       # category -> datetime of last push

# ── Scheduled forecasts ────────────────────────────────────────────────────────
# One automatic forecast per intra-day window of the study (Table 20), at the
# window's middle. Early (12–6 AM) is skipped: lowest R² in the study (SVR 0.393).
# Afternoon (3 PM) is also the study's end-of-month checkpoint.
# (name, run from, window end). A missed run (API down) still runs later in its window.
FORECAST_SCHEDULE = [
    ("Mid-morning", dtime(9, 0),  dtime(12, 0)),
    ("Afternoon",   dtime(15, 0), dtime(18, 0)),
    ("Evening",     dtime(21, 0), dtime(23, 59, 59)),
]
FORECAST_STALE_MIN = 30          # skip (retry next minute) if no reading in the last 30 min
_forecast_lock = threading.Lock()
last_true_fill_date = ""

# ── CMS + monthly rates (written by Update_Meralco_Firebase.ipynb, outside the VM) ─
RATES_HISTORY_REF   = "/meralco_rates_history"   # {YYYY-MM: {fixed_charge, brackets, ...}}
CMS_INBOX_REF       = "/cms/inbox"                # facts + headline + link + image (notebook)
CMS_PUBLISHED_REF   = "/cms/published"            # GRID-written items the app reads (VM)
RATES_PUSHED_REF    = "/advisories_state/rates_pushed_period"
# Optional shared secret for POST /refresh-rates. Set the same value in the notebook.
REFRESH_TOKEN       = os.environ.get("GRID_REFRESH_TOKEN")


def calibration_k() -> float:
    """Meter calibration (Meralco meter ÷ device), from the forecast bundle.
    Displayed kWh stays raw; pricing and brackets use kWh × k."""
    try:
        return float(FORECAST_BUNDLE["eom"]["k_pooled"])
    except Exception:
        return 1.0

def compute_billing_cutoff() -> str:
    """
    Auto-compute the billing cutoff date (27th of current or previous month).

    Logic:
    - If today >= 28th → cutoff = 27th of THIS month (new cycle started)
    - If today < 28th  → cutoff = 27th of PREVIOUS month
    """
    now = datetime.now(PH_TZ)

    if now.day >= 28:
        # New billing cycle started — use 27th of this month
        cutoff = now.replace(day=27)
    else:
        # Still in previous cycle — use 27th of last month
        first_of_month = now.replace(day=1)
        last_month     = first_of_month - timedelta(days=1)
        cutoff         = last_month.replace(day=27)

    return cutoff.strftime("%Y-%m-%d")


def fetch_billing_baseline(cutoff_date: str) -> float:
    """
    Query the last (billing-adjusted) cumul_kwh on the cutoff date.
    This is the DELTA accumulated since the previous baseline was set —
    it must be ADDED to BILLING_BASELINE_KWH, never used to replace it.
    Falls back to closest reading BEFORE cutoff if no readings on that date.
    Returns 0.0 if no readings found at all.
    """
    with get_conn() as conn:
        with conn.cursor() as cur:

            # Try exact date first
            cur.execute(
                """
                SELECT cumul_kwh FROM readings
                WHERE DATE(timestamp) = %s
                ORDER BY timestamp DESC
                LIMIT 1
                """,
                (cutoff_date,)
            )
            row = cur.fetchone()

            if row:
                return float(row[0])

            # Fallback — closest reading before cutoff date
            cur.execute(
                """
                SELECT cumul_kwh FROM readings
                WHERE DATE(timestamp) < %s
                ORDER BY timestamp DESC
                LIMIT 1
                """,
                (cutoff_date,)
            )
            row = cur.fetchone()
            return float(row[0]) if row else 0.0


def load_billing_state():
    """Read persisted {billing_cutoff_date, billing_baseline_kwh} from Firebase."""
    try:
        return firebase_db.reference(BILLING_STATE_REF).get()
    except Exception:
        return None


def save_billing_state(cutoff_date: str, baseline_kwh: float, billing_computed: float):
    """Persist billing state to Firebase so restarts don't lose the running total."""
    firebase_db.reference(BILLING_STATE_REF).set({
        "billing_cutoff_date":  cutoff_date,
        "billing_baseline_kwh": baseline_kwh,
        "billing_computed": billing_computed
    })


# ── Startup ────────────────────────────────────
@app.on_event("startup")
def startup_event():
    global BILLING_BASELINE_KWH, BILLING_CUTOFF_DATE, BILLING_COMPUTED, today_total_kwh
    global last_pushed_hour, last_pushed_date
    global MERALCO_RATES
    global reading_buffer

    reading_buffer = []   # ← add at the very start

    # Load Meralco rates once from Firebase
    MERALCO_RATES = firebase_db.reference("/meralco_rates").get()

    # Push today's running total
    today_total_kwh = get_today_total_kwh()

    # Set sync = false immediately on startup
    firebase_db.reference("/sync").set(False)

    computed_cutoff = compute_billing_cutoff()
    state = load_billing_state()

    asyncio.create_task(sync_watchdog())
    asyncio.create_task(anomaly_model_watcher())

    ensure_anomaly_review_schema()   # event_id + reviewed_at on anomaly_logs
    ensure_forecast_log_schema()     # true_day_total_kwh + trigger_source on forecast_logs
    try:
        print(f"📊 true_day_total_kwh filled for {fill_true_day_totals()} forecast log(s)")
    except Exception as e:
        print(f"❌ true_day_total_kwh backfill failed: {e}")

    if state and state.get("billing_cutoff_date") == computed_cutoff:
        # Same billing cycle as before restart — resume as-is
        BILLING_CUTOFF_DATE  = computed_cutoff
        BILLING_BASELINE_KWH = float(state["billing_baseline_kwh"])
        BILLING_COMPUTED = float(state["billing_computed"])

    elif state:
        # Cycle rolled over while the server was down — accumulate once
        delta = fetch_billing_baseline(computed_cutoff)
        BILLING_CUTOFF_DATE  = computed_cutoff
        BILLING_BASELINE_KWH = float(state["billing_baseline_kwh"]) + delta
        BILLING_COMPUTED = delta
        save_billing_state(BILLING_CUTOFF_DATE, BILLING_BASELINE_KWH, BILLING_COMPUTED)

    else:
        # No persisted state yet (first run after this change).
        # NOTE: seed /billing/state manually in Firebase before deploying,
        # e.g. {"billing_cutoff_date": "2026-06-27", "billing_baseline_kwh": 208.593}
        # so this branch doesn't silently start the accumulation from 0.
        BILLING_CUTOFF_DATE  = computed_cutoff
        BILLING_BASELINE_KWH = fetch_billing_baseline(computed_cutoff)
        BILLING_COMPUTED = BILLING_BASELINE_KWH
        save_billing_state(BILLING_CUTOFF_DATE, BILLING_BASELINE_KWH, BILLING_COMPUTED)

    # --- Recover hourly-push state so a restart doesn't wipe today's data ---
    try:
        existing_date = firebase_db.reference("/history/today/date").get()
    except Exception:
        existing_date = None

    today_str = datetime.now(PH_TZ).strftime("%Y-%m-%d")

    if existing_date == today_str:
        # Same calendar day as before restart — resume, don't wipe
        last_pushed_date = existing_date
        last_pushed_hour = datetime.now(PH_TZ).hour
    # else: leave last_pushed_hour = -1, last_pushed_date = "" (their existing
    # global defaults) so push_hourly_history() takes the normal reset path
    

# ── Helpers ────────────────────────────────────────────────────────────────────
def get_conn():
    return psycopg2.connect(**DB_CONFIG)

async def sync_watchdog():
    """
    Background task — runs every 10 seconds.
    Sets Firebase /sync to false if no reading received recently.
    Triggers FCM notification when device goes offline.
    """
    global last_sync_state

    while True:
        await asyncio.sleep(10)

        if last_reading_ts is None:
            continue

        elapsed   = (datetime.now(PH_TZ) - last_reading_ts).total_seconds()
        is_synced = elapsed <= SYNC_TIMEOUT_SECONDS

        firebase_db.reference("/sync").set(is_synced)

        # Only trigger notification on TRANSITION from true → false
        # Avoids sending repeated notifications every 10 seconds
        if not is_synced and last_sync_state:
            publish_advisory(nlg.build_device_advisory(
                online=False, since=last_reading_ts, timeout_s=SYNC_TIMEOUT_SECONDS,
                avoid_id=last_template_id("device")))
        elif is_synced and not last_sync_state:
            publish_advisory(nlg.build_device_advisory(online=True))   # in-app only

        last_sync_state = is_synced

def get_recent_averaged_readings(n: int):
    """Return last n averaged rows from DB, oldest first."""
    with get_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT * FROM (
                    SELECT * FROM readings
                    ORDER BY timestamp DESC
                    LIMIT %s
                ) sub ORDER BY timestamp ASC
                """,
                (n,),
            )
            return cur.fetchall()


def get_latest_averaged_reading():
    rows = get_recent_averaged_readings(1)
    return rows[0] if rows else None


def get_hourly_kwh_today(hour: int):
    """Return total interval_kwh for a specific hour today."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT ROUND(SUM(interval_kwh)::numeric, 4)
                FROM readings
                WHERE DATE(timestamp) = (now() AT TIME ZONE 'Asia/Manila')::date
                AND EXTRACT(HOUR FROM timestamp) = %s
                """,
                (hour,)
            )
            row = cur.fetchone()
    return float(row[0]) if row and row[0] else 0.0

def get_hourly_kwh_by_date(date_str: str):
    """
    Return hourly aggregated interval_kwh for a specific past date.
    Returns list of {hour, total_kwh} dicts.
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    EXTRACT(HOUR FROM timestamp)::int AS hour,
                    ROUND(SUM(interval_kwh)::numeric, 4) AS total_kwh
                FROM readings
                WHERE DATE(timestamp) = %s
                GROUP BY EXTRACT(HOUR FROM timestamp)
                ORDER BY hour ASC
                """,
                (date_str,)
            )
            return cur.fetchall()
        
def get_today_total_kwh() -> float:
    """Return total interval_kwh for today so far."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT COALESCE(ROUND(SUM(interval_kwh)::numeric, 4), 0)
                FROM readings
                WHERE DATE(timestamp) = (now() AT TIME ZONE 'Asia/Manila')::date
                """
            )
            row = cur.fetchone()
    return float(row[0]) if row else 0.0

def adjust_cumul(raw_cumul: float) -> float:
    """
    Deduct billing baseline from raw ESP32 cumul_kwh.
    Returns current billing cycle consumption only.
    """
    adjusted = raw_cumul - BILLING_BASELINE_KWH
    return round(max(adjusted, 0.0), 4)  # prevent negative values

def log_anomaly(reading_id: int, anomaly_result: dict, avg_power: float,
                window_ts: datetime):
    """
    Log only detected anomalies to anomaly_logs (every row is a flagged reading,
    so the table needs no is_anomaly column).
    acknowledged = NULL and reviewed_at = NULL by default (pending user review).
    event_id groups flagged readings <= 10 min apart into one event (one prompt):
    it continues the previous row's event if that row is within 10 min and not
    yet reviewed, otherwise the new row starts its own event (event_id = id).
    Returns (log_id, event_id). Universal — works for IsolationForest, OneClassSVM, LOF.
    """
    if not anomaly_result.get("is_anomaly"):
        return None, None

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT event_id FROM anomaly_logs
                WHERE timestamp < %s AND timestamp >= %s
                  AND reviewed_at IS NULL AND event_closed_at IS NULL
                ORDER BY timestamp DESC LIMIT 1
                """,
                (window_ts, window_ts - nlg.ANOMALY_EVENT_GAP),
            )
            prev = cur.fetchone()
            cur.execute(
                """
                INSERT INTO anomaly_logs
                    (timestamp, reading_id,
                     anomaly_score, power_avg, roll_mean_1hr, roll_mean_24hr,
                     dev_1hr, dev_24hr, acknowledged, power_delta, time_zscore)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
                """,
                (
                    window_ts,
                    reading_id,
                    anomaly_result["score"],
                    avg_power,
                    anomaly_result["roll_mean_1hr"],
                    anomaly_result["roll_mean_24hr"],
                    anomaly_result["dev_1hr"],
                    anomaly_result["dev_24hr"],
                    None,   # NULL = pending user review ✅
                    anomaly_result["power_delta"],
                    anomaly_result["time_zscore"],
                )
            )
            log_id = cur.fetchone()[0]
            event_id = prev[0] if prev and prev[0] is not None else log_id
            cur.execute("UPDATE anomaly_logs SET event_id = %s WHERE id = %s",
                        (event_id, log_id))
        conn.commit()
    return log_id, event_id


def ph_now_naive() -> datetime:
    """Manila wall-clock time without a zone: the convention every timestamp
    column in this database uses (flush_buffer saves window_ts the same way).
    SQL now() would give the server's UTC clock instead."""
    return datetime.now(PH_TZ).replace(tzinfo=None)


def ensure_anomaly_review_schema():
    """One-time migration (safe to run every startup):
    - event_id    groups flagged rows into one event / one prompt
    - reviewed_at set when the user answers; NULL = still pending.
    - event_closed_at = when the event ended (last flagged reading + 10 min).
    - review_notified_at = when its review push was actually sent; NULL = never.
    - expired_at = when an unanswered event left the list (last reading + 7 days).
      "Hindi sigurado" sets reviewed_at but leaves acknowledged NULL (unlabeled),
      so it leaves the pending list without becoming a training label.
    Existing rows get event_ids by the same 10-minute rule; rows already answered
    get reviewed_at so they don't reappear as pending. Old events are closed and
    expired by close_finished_events() with computed times, never with "now"."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("ALTER TABLE anomaly_logs ADD COLUMN IF NOT EXISTS event_id INTEGER")
            cur.execute("ALTER TABLE anomaly_logs ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMP")
            cur.execute("ALTER TABLE anomaly_logs ADD COLUMN IF NOT EXISTS event_closed_at TIMESTAMP")
            cur.execute("ALTER TABLE anomaly_logs ADD COLUMN IF NOT EXISTS review_notified_at TIMESTAMP")
            cur.execute("ALTER TABLE anomaly_logs ADD COLUMN IF NOT EXISTS expired_at TIMESTAMP")
            cur.execute("CREATE INDEX IF NOT EXISTS anomaly_logs_event_idx ON anomaly_logs (event_id)")
            cur.execute(
                """
                WITH o AS (
                    SELECT id, timestamp,
                           CASE WHEN timestamp - LAG(timestamp) OVER (ORDER BY timestamp, id)
                                     <= %s THEN 0 ELSE 1 END AS brk
                    FROM anomaly_logs),
                g AS (SELECT id, timestamp, SUM(brk) OVER (ORDER BY timestamp, id) AS grp FROM o),
                f AS (SELECT id, FIRST_VALUE(id) OVER (PARTITION BY grp ORDER BY timestamp, id) AS ev
                      FROM g)
                UPDATE anomaly_logs a SET event_id = f.ev
                FROM f WHERE a.id = f.id AND a.event_id IS NULL
                """,
                (nlg.ANOMALY_EVENT_GAP,),
            )
            cur.execute(
                "UPDATE anomaly_logs SET reviewed_at = %s "
                "WHERE acknowledged IS NOT NULL AND reviewed_at IS NULL", (ph_now_naive(),))
        conn.commit()

def log_forecast(result: dict, window_ts: datetime, trigger_source: str = "user"):
    """
    Log every forecast prediction to forecast_logs.
    trigger_source: "user" (POST /forecast) or "scheduled" (FORECAST_SCHEDULE).
    true_day_total_kwh stays NULL until the day is over (fill_true_day_totals).
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO forecast_logs
                    (timestamp, trigger_source, billing_cycle_start,
                     predicted_day_total_kwh, accumulated_past_kwh,
                     combined_kwh, days_so_far, avg_daily_kwh,
                     days_remaining, projected_eom_kwh)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    window_ts,
                    trigger_source,
                    result["billing_cycle_start"],
                    result["predicted_day_total_kWh"],
                    result["accumulated_past_kWh"],
                    result["combined_kWh"],
                    result["days_so_far"],
                    result["avg_daily_kWh"],
                    result["days_remaining"],
                    result["projected_eom_kWh"],
                )
            )
        conn.commit()

def ensure_forecast_log_schema():
    """Safe every startup. true_day_total_kwh = the day's metered total (sum of
    interval_kwh, anomalous readings included: the study's "true" total), filled
    once the day is over. trigger_source tells user runs from scheduled ones;
    existing rows were all user-triggered, hence the default."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("ALTER TABLE forecast_logs ADD COLUMN IF NOT EXISTS true_day_total_kwh DOUBLE PRECISION")
            cur.execute("ALTER TABLE forecast_logs ADD COLUMN IF NOT EXISTS trigger_source TEXT NOT NULL DEFAULT 'user'")
        conn.commit()


def fill_true_day_totals() -> int:
    """Fill true_day_total_kwh for every log whose day is over (date < today, PH).
    Runs at startup (backfills old logs) and once a day after midnight.
    Same definition as the v3.2 notebook: SUM(interval_kwh) per calendar date.
    A day with no readings at all stays NULL."""
    today = datetime.now(PH_TZ).date()
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE forecast_logs f
                SET true_day_total_kwh = d.kwh
                FROM (SELECT DATE(timestamp) AS day, SUM(interval_kwh) AS kwh
                      FROM readings WHERE DATE(timestamp) < %s
                      GROUP BY DATE(timestamp)) d
                WHERE DATE(f.timestamp) = d.day AND f.true_day_total_kwh IS NULL
                """,
                (today,),
            )
            n = cur.rowcount
        conn.commit()
    return n


def run_scheduled_forecasts_if_due():
    """Called every minute. Runs a slot's forecast once per day, inside its window,
    only if the device sent data recently. Restart-safe: "already ran" is read
    from forecast_logs, not from memory."""
    now = datetime.now(PH_TZ)
    now_n = now.replace(tzinfo=None)
    for name, start, end in FORECAST_SCHEDULE:
        if not (start <= now.time() < end):
            continue
        day = now_n.date()
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT 1 FROM forecast_logs WHERE trigger_source = 'scheduled' "
                    "AND timestamp >= %s AND timestamp < %s LIMIT 1",
                    (datetime.combine(day, start), datetime.combine(day, end)),
                )
                done = cur.fetchone() is not None
        if done:
            continue
        if last_reading_ts is None or (now - last_reading_ts).total_seconds() > FORECAST_STALE_MIN * 60:
            continue                               # device offline: try again next minute
        try:
            run_forecast("scheduled")
            print(f"📈 Scheduled forecast ({name}) done")
        except Exception as e:
            print(f"❌ Scheduled forecast ({name}) failed: {e}")


def push_to_firebase(raw: dict, adjusted_cumul: float, est_cost: float,
                     billed_kwh: float = None, bracket: str = None):
    """Push all 6 live measurements to Firebase /live_reading."""
    firebase_db.reference("/live_reading").set({
        "voltage":      raw["voltage"],
        "current":      raw["current"],
        "power":        raw["power"],
        "cumul_kwh":    adjusted_cumul,   # ← adjusted (current cycle only), shown as "Total Used"
        "billed_kwh":   billed_kwh,       # ← cumul_kwh × k, used for bracket and cost
        "bracket":      bracket,
        "power_factor": raw["power_factor"],
        "frequency":    raw["frequency"],
        "timestamp":    raw["timestamp"],
        "estimated_cost": est_cost,
    })

# ── FCM Push Notification ──────────────────────────────────────────────────────
def send_fcm_alert(
    title: str,
    body: str,
    channel_id: str = "high_channel",
    data: dict = None
):
    """
    Sends FCM push notification to ALL registered devices.
    channel_id maps to Flutter AndroidNotificationChannel:
      - high_channel   → Anomaly Alerts (urgent)
      - medium_channel → Billing Warnings (important)
      - low_channel    → Bill Forecasts (informational)
    """
    try:
        tokens_ref = firebase_db.reference("/device_tokens").get()

        if not tokens_ref:
            print("❌ No device tokens registered")
            return False

        tokens = list(tokens_ref.values())

        if not tokens:
            print("❌ Token list is empty")
            return False

        message = messaging.MulticastMessage(
            notification=messaging.Notification(
                title=title,
                body=body,
            ),
            android=messaging.AndroidConfig(
                notification=messaging.AndroidNotification(
                    channel_id=channel_id,
                    priority="high" if channel_id == "high_channel" else "default",
                )
            ),
            data={k: str(v) for k, v in (data or {}).items()},
            tokens=tokens,
        )

        response = messaging.send_each_for_multicast(message)
        print(f"✅ FCM sent to {response.success_count}/{len(tokens)} devices "
              f"via {channel_id}")

        # Clean up invalid/expired tokens automatically
        if response.failure_count > 0:
            for idx, result in enumerate(response.responses):
                if not result.success:
                    failed_token = tokens[idx]
                    safe_key = failed_token[-20:].replace(
                        ":", "_").replace("-", "_")
                    firebase_db.reference(
                        f"/device_tokens/{safe_key}").delete()
                    print(f"🗑️ Removed invalid token: {safe_key}")

        return response.success_count > 0

    except Exception as e:
        print(f"❌ FCM error: {e}")
        return False


# ── NLG advisory I/O (advisory_rules.py stays pure; all writes happen here) ───
def last_template_id(category: str):
    """Last template_id shown for this category, passed back as avoid_id."""
    try:
        return firebase_db.reference(f"{ADVISORY_REF}/{category}/template_id").get()
    except Exception:
        return None


def publish_advisory(adv: dict) -> bool:
    """Write an advisory to RTDB /advisories/{category} and push it if flagged.
    Returns True only if a push actually reached at least one device."""
    if not adv:
        return False
    now = datetime.now(PH_TZ)
    record = {k: v for k, v in adv.items() if k not in ("data", "push") and v is not None}
    record.update({k: v for k, v in adv["data"].items() if v is not None})
    record["timestamp"] = now.isoformat()
    try:
        firebase_db.reference(f"{ADVISORY_REF}/{adv['category']}").set(record)
    except Exception as e:
        print(f"❌ Advisory write failed: {e}")

    if adv["push"] and adv["channel"]:
        payload = {"type": adv["category"], "template_id": adv["template_id"],
                   "timestamp": now.isoformat()}
        d = adv["data"]
        if "log_ids" in d:
            payload["log_ids"] = ",".join(str(i) for i in d["log_ids"])
        if d.get("event_id") is not None:
            payload["event_id"] = d["event_id"]                     # anomaly: open this card
        if d.get("event_ids"):
            payload["event_ids"] = ",".join(str(i) for i in d["event_ids"])   # review push
        sent = send_fcm_alert(adv["title_tl"], adv["message_tl"], adv["channel"], payload)
        if sent:
            LAST_PUSH[adv["category"]] = now
        return bool(sent)
    return False


def billing_cycle_end(now: datetime):
    """The 27th that closes the current cycle (same rule as /forecast)."""
    if now.day <= 27:
        return now.replace(day=27).date()
    if now.month < 12:
        return now.replace(month=now.month + 1, day=27).date()
    return now.replace(year=now.year + 1, month=1, day=27).date()


def handle_bracket_advisory(adjusted_cumul: float):
    """Tier alert on BILLED kWh (adjusted cumul × k): once when approaching
    (>=90% of the bracket's upper bound) and once when a new bracket is entered,
    per bracket per billing cycle."""
    k = calibration_k()
    billed_kwh = adjusted_cumul * k
    ref = firebase_db.reference(BRACKET_STATE_REF)
    state = ref.get()
    event, new_state = nlg.check_bracket_event(billed_kwh, BILLING_CUTOFF_DATE, state)
    if new_state != state:
        ref.set(new_state)
    if event:
        days_left = (billing_cycle_end(datetime.now(PH_TZ)) - datetime.now(PH_TZ).date()).days
        publish_advisory(nlg.build_bracket_advisory(
            event, billed_kwh, days_left, calibration_k=k,
            avoid_id=last_template_id("bracket")))


def household_rate_advisory(billed_kwh: float, basis: str = "so_far",
                            push: bool = False):
    """This month's Meralco rates vs last month's, on the household's billed kWh.
    basis "so_far" = billed kWh this cycle; "projected" = calibrated month-end."""
    try:
        history = firebase_db.reference(RATES_HISTORY_REF).get() or {}
        cmp_ = rate_compare.compare_with_previous(MERALCO_RATES, history, billed_kwh, basis)
    except Exception as e:
        print(f"❌ Rate comparison failed: {e}")
        return None
    adv = nlg.build_rate_change_advisory(cmp_, avoid_id=last_template_id("rates"))
    if adv:
        adv["push"] = push
    return adv


def publish_cms() -> dict:
    """Rebuild /cms/published from the notebook's /cms/inbox (small set, full rewrite).
    Only status "approved" items are published; "archived" ones drop out."""
    inbox = firebase_db.reference(CMS_INBOX_REF).get() or {}
    published, failed = {}, []
    for item_id, item in inbox.items():
        if not isinstance(item, dict) or item.get("status") != "approved":
            continue
        try:
            published[item_id] = nlg.build_cms_published(item)
        except Exception as e:
            failed.append(item_id)
            print(f"❌ CMS item {item_id} skipped: {e}")
    firebase_db.reference(CMS_PUBLISHED_REF).set(published)
    return {"published": len(published), "failed": failed}


def handle_anomaly_advisory(anomaly_result: dict, avg_power: float,
                            window_ts: datetime, log_id, event_id):
    """One advisory + HITL prompt per anomaly event. The DB event_id (log_anomaly)
    decides the grouping; the in-memory event only tracks severity for escalation
    and push throttling. A later reading in the same event only adds its log_id,
    unless the severity rises (escalation)."""
    global ANOMALY_EVENT
    z = anomaly_result.get("time_zscore")
    if ANOMALY_EVENT and ANOMALY_EVENT.get("event_id") != event_id:
        ANOMALY_EVENT = None            # DB says this is a different event
    ANOMALY_EVENT, action = nlg.update_anomaly_event(ANOMALY_EVENT, window_ts, log_id, z)
    if ANOMALY_EVENT.get("event_id") not in (None, event_id):
        action = "new"
    ANOMALY_EVENT["event_id"] = event_id

    if action == "extended":
        firebase_db.reference(f"{ADVISORY_REF}/anomaly/log_ids").set(ANOMALY_EVENT["log_ids"])
        return

    adv = nlg.build_anomaly_advisory(
        power_avg=avg_power,
        roll_mean_1hr=anomaly_result.get("roll_mean_1hr"),
        time_zscore=z,
        event=ANOMALY_EVENT,
        escalated=(action == "escalated"),
        avoid_id=last_template_id("anomaly"),
    )
    adv["data"]["event_id"] = event_id   # the app opens the event card with this id
    # While an event is open only a SEVERE one pushes (safety: something may be
    # left on or faulty). Others show in-app and get one review push when they end.
    adv["push"] = ANOMALY_EVENT["severity"] == "severe"
    publish_advisory(adv)


_review_lock = threading.Lock()

def close_finished_events():
    """Runs at every 5-min flush and every minute in the background (so events
    still close while the device is offline). Every stamp it writes is the time
    the thing actually happened:
    1. Close events with no flagged reading for ANOMALY_EVENT_GAP:
       event_closed_at = last flagged reading + gap.
    2. Expire unanswered events older than REVIEW_EXPIRY:
       expired_at = last flagged reading + 7 days (acknowledged stays NULL).
    3. ONE review push for events that ended within REVIEW_NOTIFY_WINDOW, are
       unanswered and not yet pushed (bundled; at most one per REVIEW_PUSH_COOLDOWN).
       review_notified_at is set only for events in a push that was sent. Quiet
       one-reading blips and events that ended long ago keep it NULL."""
    if not _review_lock.acquire(blocking=False):
        return
    try:
        now = datetime.now(PH_TZ)
        now_n = now.replace(tzinfo=None)                 # DB timestamps are naive PH time
        with get_conn() as conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute(
                    """
                    UPDATE anomaly_logs a SET event_closed_at = e.last_ts + %s
                    FROM (SELECT event_id, MAX(timestamp) AS last_ts FROM anomaly_logs
                          WHERE event_closed_at IS NULL
                          GROUP BY event_id HAVING MAX(timestamp) <= %s) e
                    WHERE a.event_id = e.event_id AND a.event_closed_at IS NULL
                    """,
                    (nlg.ANOMALY_EVENT_GAP, now_n - nlg.ANOMALY_EVENT_GAP),
                )
                cur.execute(
                    """
                    UPDATE anomaly_logs a SET expired_at = e.last_ts + %s
                    FROM (SELECT event_id, MAX(timestamp) AS last_ts FROM anomaly_logs
                          WHERE reviewed_at IS NULL AND expired_at IS NULL
                          GROUP BY event_id HAVING MAX(timestamp) <= %s) e
                    WHERE a.event_id = e.event_id
                      AND a.reviewed_at IS NULL AND a.expired_at IS NULL
                    """,
                    (nlg.REVIEW_EXPIRY, now_n - nlg.REVIEW_EXPIRY),
                )
                cur.execute(
                    """
                    SELECT event_id, MIN(timestamp) AS first_ts, MAX(timestamp) AS last_ts,
                           COUNT(*) AS readings, MAX(time_zscore) AS peak_z
                    FROM anomaly_logs
                    WHERE event_closed_at IS NOT NULL AND review_notified_at IS NULL
                      AND reviewed_at IS NULL AND expired_at IS NULL
                    GROUP BY event_id HAVING MAX(event_closed_at) >= %s
                    ORDER BY MIN(timestamp)
                    """,
                    (now_n - nlg.REVIEW_NOTIFY_WINDOW,),
                )
                due = cur.fetchall()
            conn.commit()

        events = [{"event_id": r["event_id"],
                   "start": r["first_ts"] - timedelta(seconds=BUFFER_SECONDS),
                   "end": r["last_ts"], "readings": r["readings"],
                   "severity": nlg.anomaly_severity(
                       float(r["peak_z"]) if r["peak_z"] is not None else None)}
                  for r in due]
        loud = [e for e in events if not nlg.is_quiet_event(e["severity"], e["readings"])]
        if not loud or not nlg.push_allowed(LAST_PUSH.get("review"), now, nlg.REVIEW_PUSH_COOLDOWN):
            return
        adv = nlg.build_review_push(loud, now.date())
        if not adv:
            return
        if not publish_advisory(adv):
            return                                   # not delivered: stays NULL, retried next tick
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE anomaly_logs SET review_notified_at = %s "
                            "WHERE event_id = ANY(%s) AND review_notified_at IS NULL",
                            (now_n, [e["event_id"] for e in loud]))
            conn.commit()
    except Exception as e:
        print(f"❌ Event close/review push failed: {e}")
    finally:
        _review_lock.release()


def event_cost_php(event_kwh: float, current_billed_kwh: float) -> Optional[float]:
    """Billing side: the event's energy (× k, as Meralco meters it) at the rate of
    the bracket the household is in now. Approximate: it ignores a bracket change
    caused by the event itself, so the card says "humigit-kumulang"."""
    try:
        k = calibration_k()
        rate = float(MERALCO_RATES["brackets"][nlg.bracket_label(current_billed_kwh)])
        return round(event_kwh * k * rate, 2)
    except Exception:
        return None

# ── Device Token Registration ──────────────────────────────────────────────────
class DeviceToken(BaseModel):
    token: str

@app.post("/register-token")
def register_token(data: DeviceToken):
    """
    Stores each phone's token under its own unique key.
    Multiple phones can register without overwriting each other.
    """
    # Use the token itself as the key — unique per device
    safe_key = data.token[-20:].replace(":", "_").replace("-", "_")
    firebase_db.reference(f"/device_tokens/{safe_key}").set(data.token)
    return {"status": "ok", "message": "Device token registered"}


def push_hourly_history(now: datetime):
    """
    Option C — Hybrid hourly history push to Firebase /history/today.
    - Current hour → pushed every 5-min flush (live running total)
    - Previous hour → pushed ONCE when hour changes (final value)
    - Midnight reset → clears /history/today/hourly and updates date
    """
    global last_pushed_hour, last_pushed_date, today_total_kwh

    today        = now.strftime("%Y-%m-%d")
    current_hour = now.hour

    # Midnight reset
    if today != last_pushed_date:
        today_total_kwh = 0.0
        firebase_db.reference("/history/today/hourly").delete()
        firebase_db.reference("/history/today/date").set(today)
        last_pushed_date = today
        last_pushed_hour = -1

        # Check if billing cycle changed on this new date
        refresh_billing_baseline_if_needed()

    # Always push current hour's running total
    current_kwh = get_hourly_kwh_today(current_hour)
    firebase_db.reference(f"/history/today/hourly/{current_hour}").set(current_kwh)

    # Push completed previous hour ONCE when hour changes
    if last_pushed_hour != -1 and last_pushed_hour != current_hour:
        completed_kwh = get_hourly_kwh_today(last_pushed_hour)
        firebase_db.reference(f"/history/today/hourly/{last_pushed_hour}").set(completed_kwh)

    last_pushed_hour = current_hour


def refresh_billing_baseline_if_needed():
    """
    Check if billing cutoff date has changed (new billing cycle).
    Called every flush_buffer() (via push_hourly_history's midnight check) —
    updates baseline automatically on July 28, August 28, etc. without needing
    a FastAPI restart.

    fetch_billing_baseline() returns a DELTA (this cycle's adjusted
    consumption), so it must be ADDED to the existing baseline, not used to
    replace it — otherwise the deduction resets every month instead of
    tracking the real, continually-incrementing PZEM/ESP32 counter.
    """
    global BILLING_BASELINE_KWH, BILLING_CUTOFF_DATE, BILLING_COMPUTED

    new_cutoff = compute_billing_cutoff()

    if new_cutoff != BILLING_CUTOFF_DATE:
        delta = fetch_billing_baseline(new_cutoff)
        BILLING_BASELINE_KWH = BILLING_BASELINE_KWH + delta
        BILLING_CUTOFF_DATE  = new_cutoff
        BILLING_COMPUTED = delta
        save_billing_state(BILLING_CUTOFF_DATE, BILLING_BASELINE_KWH, BILLING_COMPUTED)


def flush_buffer():
    """
    Average the 5-min buffer, save to PostgreSQL, run anomaly detection.
    Called automatically when buffer covers >= 5 minutes.
    """
    global reading_buffer, today_total_kwh

    if not _flush_lock.acquire(blocking=False):
        return   
           
    # Snapshot and clear buffer immediately ✅
    snapshot       = reading_buffer[:]
    reading_buffer = []
    
    try:
        if len(snapshot) < 2:
            return

        voltages  = [r["voltage"]   for r in snapshot]
        currents  = [r["current"]   for r in snapshot]
        powers    = [r["power"]     for r in snapshot]
        cumuls    = [r["cumul_kwh"] for r in snapshot]

        avg_voltage  = round(float(np.mean(voltages)), 2)
        avg_current  = round(float(np.mean(currents)), 3)
        avg_power    = round(float(np.mean(powers)),   2)
        window_ts    = snapshot[-1]["ts"].replace(tzinfo=None)

        # cumul_kwh — continue from last DB value if ESP32 reset detected
        last_db_row = get_latest_averaged_reading()
        if last_db_row and float(cumuls[-1]) < float(last_db_row["cumul_kwh"]):
            raw_cumul = round(float(last_db_row["cumul_kwh"]) + float(cumuls[-1]), 4)
        else:
            raw_cumul = round(float(cumuls[-1]), 4)

        # Adjust cumul_kwh for current billing cycle
        adjusted_cumul = adjust_cumul(raw_cumul)

        # ── Time-based gap detection for interval_kwh ──────────────────────────
        buffer_start_ts = snapshot[0]["ts"].replace(tzinfo=None)

        GAP_THRESHOLD = BUFFER_SECONDS + 60

        if last_db_row:
            gap_seconds = (buffer_start_ts - last_db_row["timestamp"]).total_seconds()

            if gap_seconds > GAP_THRESHOLD:

                # ── Check if billing cutoff falls within the gap ──────────────────
                last_db_date   = last_db_row["timestamp"].date()
                current_date   = buffer_start_ts.date()

                # Parse billing cutoff date from saved state
                billing_state  = firebase_db.reference("/billing/state").get() or {}
                cutoff_str     = billing_state.get("billing_cutoff_date", None)

                cutoff_crossed = False

                if cutoff_str:
                    try:
                        cutoff_date = datetime.strptime(cutoff_str, "%Y-%m-%d").date()
                        # Cutoff falls between last DB row and current buffer
                        if last_db_date < cutoff_date <= current_date:
                            cutoff_crossed = True
                    except ValueError:
                        cutoff_crossed = False

                if cutoff_crossed:
                    # New billing cycle started during the gap
                    # PZEM reset to near-zero — use adjusted_cumul directly
                    interval_kwh = 0.0

                else:
                    # Normal reconnection — no cutoff crossed
                    interval_kwh = round(
                        float(adjusted_cumul) - float(last_db_row["cumul_kwh"]), 4
                    )
            else:
                # Normal 5-min window
                interval_kwh = round(float(cumuls[-1] - cumuls[0]), 4)

        else:
            # No DB rows yet — use buffer difference
            interval_kwh = round(float(cumuls[-1] - cumuls[0]), 4)

        # ── Safety clamp — interval_kwh should never be negative ─────────────────
        if interval_kwh < 0:
            interval_kwh = 0.0

        today_total_kwh = round(today_total_kwh + interval_kwh, 4)

        # Save to PostgreSQL (adjusted cumul_kwh)
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO readings
                        (timestamp, voltage, current, power_avg, interval_kwh, cumul_kwh)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    RETURNING id
                    """,
                    (window_ts, avg_voltage, avg_current,
                    avg_power, interval_kwh, adjusted_cumul),
                )
                reading_id = cur.fetchone()[0]
            conn.commit()

        # Run anomaly detection
        anomaly_result = run_anomaly()

        is_anomaly = bool(anomaly_result.get("is_anomaly"))

        # Log anomaly to DB if detected (acknowledged = NULL)
        log_id, event_id = None, None
        if is_anomaly:
            log_id, event_id = log_anomaly(
                reading_id=reading_id,
                anomaly_result=anomaly_result,
                avg_power=avg_power,
                window_ts=window_ts,
            )

        # Raw detector output for the dashboard (.get: "collecting_data" has no power_delta)
        firebase_db.reference("/anomaly_alert").set({
            "is_anomaly":  is_anomaly,
            "score":       anomaly_result.get("score"),
            "timestamp":   window_ts.isoformat(),
            "power_avg":   avg_power,
            "power_delta": anomaly_result.get("power_delta"),
        })

        # NLG: one advisory + HITL prompt per anomaly event (replaces the
        # hardcoded per-reading FCM)
        if is_anomaly:
            try:
                handle_anomaly_advisory(anomaly_result, avg_power, window_ts, log_id, event_id)
            except Exception as e:
                print(f"❌ Anomaly advisory failed: {e}")

        # NLG: close finished anomaly events and send their review push
        close_finished_events()

        # NLG: tier alerts (approaching / crossed), once per bracket per cycle
        try:
            handle_bracket_advisory(adjusted_cumul)
        except Exception as e:
            print(f"❌ Bracket advisory failed: {e}")


        # Push today's hourly history to Firebase (Option C)
        push_hourly_history(datetime.now(PH_TZ))

        firebase_db.reference("/history/today/total_kwh").set(today_total_kwh)
        return anomaly_result
    
    finally:
        _flush_lock.release()      # always releases the lock

def run_anomaly():
    """
    Score the newest 5-min reading with the current anomaly bundle.
    Features are built by anomaly_retrain.score_latest(), the same code the
    VM refit trains with (time-based 1 h / 24 h rolling means, Power Delta = 0
    after a gap > 60 min, time_zscore from the bundle's 48-bucket baseline).

    The current reading has already been saved to the DB before this runs,
    so the last 25 h of rows include it as the most recent row.
    """
    bundle = ANOMALY_BUNDLE          # read once: a hot reload mid-call cannot mix two models

    with get_conn() as conn:
        rows = ar.fetch_recent_rows_db(conn, hours=25)

    if len(rows) < 2:
        return {"status": "collecting_data", "is_anomaly": False, "score": None}

    return ar.score_latest(rows, bundle)


# ── Forecast frame cache ───────────────────────────────────────────────────────
# /forecast used to rebuild features for ALL readings since June 5 on every request.
# Now the past-day summary is built once (per day, per model, per change in past readings)
# and each request processes only today's readings. Result is identical (forecast_cache_check.py).
_fc_lock  = threading.Lock()
_fc_cache = {"key": None, "hist": None}


def _forecast_history(conn, fb, ab, today):
    """Past-day summary for `today`, rebuilt only when the day, a model or the past readings change."""
    sig = fr.past_readings_signature_db(conn, today)
    key = (today, id(fb), fb.get("version"), id(ab), ab.get("version"), sig)
    with _fc_lock:
        if _fc_cache["key"] != key:
            t0 = datetime.now()
            raw = fr.fetch_all_readings_db(conn)
            _fc_cache.update(key=key, hist=fr.build_history(raw, ab, fb, today))
            print(f"🔁 Forecast history rebuilt for {today} in {(datetime.now() - t0).total_seconds():.1f} s")
        return _fc_cache["hist"]


def _forecast_frame(fb, ab, today):
    with get_conn() as conn:
        hist = _forecast_history(conn, fb, ab, today)
        window = fr.fetch_window_readings_db(conn, today)
    return fr.build_today(window, ab, fb, hist)


def _warm_forecast_cache():
    """Called by the background watcher so the first tap of the day does not pay for the rebuild."""
    with get_conn() as conn:
        _forecast_history(conn, FORECAST_BUNDLE, ANOMALY_BUNDLE, datetime.now(PH_TZ).date())


# ── Anomaly model: hot reload + daily drift check ──────────────────────────────
def _install_new_model_if_any():
    """Install waiting models from models/incoming/ (written by the refits on this VM).
    Anomaly first; a new anomaly model changes what counts as clean energy, so the
    forecasting model is refit right after (it lands in incoming/ and installs next tick)."""
    global ANOMALY_BUNDLE, FORECAST_BUNDLE
    with get_conn() as conn:
        sample = ar.fetch_recent_rows_db(conn, hours=25)
    new = ar.install_incoming(MODEL_DIR, sample)      # None if nothing is waiting
    if new is not None:
        ANOMALY_BUNDLE = new                         # single assignment = atomic swap
        firebase_db.reference("/anomaly_model/version").set(new.get("version", "unknown"))
        firebase_db.reference("/anomaly_model/train_window").set(list(new["train_window"]))
        print(f"✅ Anomaly model installed: {new.get('version')} {new['train_window']}")
        _forecast_refit_if_due()

    fnew = fr.install_incoming(MODEL_DIR)
    if fnew is not None:
        FORECAST_BUNDLE = fnew
        firebase_db.reference("/forecast_model").set({
            "version": fnew.get("version"), "train_window": list(fnew["train_window"]),
            "anomaly_version": fnew.get("anomaly_version"), "reason": fnew.get("refit_reason")})
        print(f"✅ Forecast model installed: {fnew.get('version')} {fnew['train_window']} ({fnew.get('refit_reason')})")


def _forecast_refit_if_due(force_reason=None):
    """Weekly, or when the anomaly model changed. Writes to incoming/; the watcher installs it."""
    if not AUTO_REFIT_FORECAST and not force_reason:
        return
    today = datetime.now(PH_TZ).date()
    with get_conn() as conn:
        status = fr.run_refit_if_due(conn, FORECAST_BUNDLE, ANOMALY_BUNDLE, MODEL_DIR, today, force_reason)
    print(f"📈 Forecast refit check: {status}")


def _daily_drift_check():
    with get_conn() as conn:
        status = ar.run_daily_check(conn, ANOMALY_BUNDLE, MODEL_DIR, auto_refit=AUTO_REFIT)
    firebase_db.reference("/anomaly_model/drift").set({k: str(v) for k, v in status.items()})
    print(f"🔎 Drift check: {status}")
    refit_done = bool(status.get("refit"))
    # A drift refit already trains on the newest 30 days, so the HITL check waits for the next day.
    if not refit_done:
        refit_done = _hitl_check()
    # If the anomaly model was refit, the forecast refit follows its install (next tick).
    # Otherwise check the weekly forecast refit now.
    if not refit_done:
        _forecast_refit_if_due()


def _hitl_check() -> bool:
    """Recurring owner-labeled false alarms -> refit (same path as a drift refit). Returns True if refit."""
    with get_conn() as conn:
        h = hitl.run_hitl_check(conn, ANOMALY_BUNDLE, MODEL_DIR, auto_refit=AUTO_REFIT_HITL)
    firebase_db.reference("/anomaly_model/hitl").set({k: str(v) for k, v in h.items()})
    print(f"🧑 HITL check: {h}")
    return bool(h.get("refit"))


async def anomaly_model_watcher():
    """Background task. Every minute: install a waiting model (hot reload).
    Once a day after midnight: drift check; a refit drops its pkl in incoming/,
    which the next tick installs. Heavy work runs in a thread, not on the event loop."""
    global last_drift_check_date, last_true_fill_date
    while True:
        await asyncio.sleep(MODEL_WATCH_SECONDS)
        try:
            await asyncio.to_thread(_install_new_model_if_any)
        except Exception as e:
            print(f"❌ Model install failed (old model kept): {e}")

        await asyncio.to_thread(close_finished_events)   # events close even while offline

        try:
            await asyncio.to_thread(run_scheduled_forecasts_if_due)
        except Exception as e:
            print(f"❌ Forecast schedule check failed: {e}")

        now = datetime.now(PH_TZ)
        today = now.strftime("%Y-%m-%d")

        # First tick of a new day: yesterday is complete, fill its true total
        if today != last_true_fill_date:
            last_true_fill_date = today
            try:
                n = await asyncio.to_thread(fill_true_day_totals)
                if n:
                    print(f"📊 true_day_total_kwh filled for {n} forecast log(s)")
            except Exception as e:
                print(f"❌ true_day_total_kwh fill failed: {e}")

        due = (now.hour, now.minute) >= (DRIFT_CHECK_HOUR, DRIFT_CHECK_MINUTE)
        if due and today != last_drift_check_date:
            last_drift_check_date = today
            try:
                await asyncio.to_thread(_daily_drift_check)
            except Exception as e:
                print(f"❌ Drift check failed: {e}")

        try:
            await asyncio.to_thread(_warm_forecast_cache)
        except Exception as e:
            print(f"❌ Forecast cache warm-up failed: {e}")


@app.get("/anomaly-model")
def anomaly_model_info():
    """Which anomaly model is live, and the latest drift check (for debugging / the app)."""
    b = ANOMALY_BUNDLE
    return {
        "version":      b.get("version", "june-v2"),
        "train_window": b.get("train_window"),
        "drift_level":  b["drift"]["train_mean_daily_kwh"],
        "last_refit":   b["drift"].get("last_refit"),
        "features":     b["features"],
        "drift":        firebase_db.reference("/anomaly_model/drift").get(),
    }


@app.post("/anomaly-model/check-drift")
def anomaly_model_check_now():
    """Run the drift check now (same as the daily job)."""
    _daily_drift_check()
    return firebase_db.reference("/anomaly_model/drift").get()


@app.post("/anomaly-model/check-hitl")
def anomaly_model_check_hitl_now():
    """Run only the HITL check now (refits if owner-labeled false alarms recur)."""
    _hitl_check()
    return firebase_db.reference("/anomaly_model/hitl").get()

def get_current_schedule_filename():
    """Picks the PDF whose filename encodes the latest year-month, e.g.
    '08-2026_rate_schedule.pdf' -> (2026, 8). More reliable than file
    modification time, which can be misleading after any copy/restore/
    re-sync operation touches an older file more recently than a newer one."""
    pdfs = [f for f in os.listdir(RATE_SCHEDULE_DIR) if f.lower().endswith(".pdf")]
    if not pdfs:
        raise HTTPException(status_code=500, detail="No rate schedule PDF found in meralco_rates/")
 
    def year_month(filename):
        match = re.match(r"(\d{2})-(\d{4})", filename)
        if not match:
            return (0, 0)  # unrecognized naming sorts first, never wins
        month, year = int(match.group(1)), int(match.group(2))
        return (year, month)
 
    return max(pdfs, key=year_month)

# ── ESP32 Ingestion Endpoint ───────────────────────────────────────────────────
class Reading(BaseModel):
    voltage:      float
    current:      float
    power:        float
    cumul_kwh:    float
    power_factor: float
    frequency:    float


@app.post("/reading")
def post_reading(data: Reading):
    """
    Receives all 6 measurements from ESP32 every 2 seconds.
    1. Adjusts cumul_kwh for current billing cycle
    2. Pushes all 6 to Firebase /live_reading (adjusted cumul_kwh)
    3. Buffers for 5-min averaging
    4. Every 5 minutes: flush → PostgreSQL → anomaly → Firebase history
    """
    global reading_buffer, MERALCO_RATES, last_reading_ts

    now            = datetime.now(PH_TZ)
    last_reading_ts = now   # ← update on every reading
    adjusted_cumul = adjust_cumul(data.cumul_kwh)

    # Set sync = true immediately on every reading
    firebase_db.reference("/sync").set(True)

    # Pricing and bracket on calibrated kWh (Meralco-meter equivalent); display stays raw
    billed_kwh = round(adjusted_cumul * calibration_k(), 4)
    bracket    = nlg.bracket_label(billed_kwh)    # whole-kWh rule, same as the alerts

    rate_per_kwh = MERALCO_RATES["brackets"][bracket]
    fixed_charge = MERALCO_RATES["fixed_charge"]

    estimated_cost = billed_kwh * rate_per_kwh + fixed_charge

    # 1. Push all 6 to Firebase (adjusted cumul_kwh)
    push_to_firebase({
        "voltage":      data.voltage,
        "current":      data.current,
        "power":        data.power,
        "power_factor": data.power_factor,
        "frequency":    data.frequency,
        "timestamp":    now.isoformat(),
    }, adjusted_cumul, estimated_cost, billed_kwh, bracket)

    # 2. Add to 5-min buffer (raw cumul for interval_kwh calculation)
    reading_buffer.append({
        "voltage":   data.voltage,
        "current":   data.current,
        "power":     data.power,
        "cumul_kwh": data.cumul_kwh,   # raw — interval_kwh needs raw values
        "ts":        now,
    })

    # 3. Check if 5-minute window has elapsed
    anomaly_result = None
    if len(reading_buffer) >= 2:
        elapsed = (reading_buffer[-1]["ts"] - reading_buffer[0]["ts"]).total_seconds()
        if elapsed >= BUFFER_SECONDS:
            anomaly_result = flush_buffer()

    return {
        "status":         "ok",
        "timestamp":      now.isoformat(),
        "buffer_size":    len(reading_buffer),
        "adjusted_cumul": adjusted_cumul,
        "anomaly":        anomaly_result,
    }


# ── reset rates ──────────────────────────────────────────────────────────
@app.post("/refresh-rates")
def refresh_rates(x_grid_token: Optional[str] = Header(None)):
    """Called by Update_Meralco_Firebase.ipynb after it writes Firebase.
    1. Reload the live linear rates
    2. Rebuild /cms/published from /cms/inbox (Tagalog text realized here)
    3. Rate-change advisory on the household's billed kWh so far; pushed once per period
    """
    global MERALCO_RATES
    if REFRESH_TOKEN and x_grid_token != REFRESH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid refresh token")

    MERALCO_RATES = firebase_db.reference("/meralco_rates").get()
    cms_result = publish_cms()

    period = rate_compare.period_of(MERALCO_RATES)
    pushed_ref = firebase_db.reference(RATES_PUSHED_REF)
    first_time = bool(period) and pushed_ref.get() != period

    latest = get_latest_averaged_reading()
    billed_kwh = float(latest["cumul_kwh"]) * calibration_k() if latest else 0.0
    adv = household_rate_advisory(billed_kwh, "so_far", push=first_time)
    publish_advisory(adv)
    if adv and first_time:
        pushed_ref.set(period)

    return {
        "status":        "ok",
        "message":       "Meralco rates refreshed",
        "period":        period,
        "cms":           cms_result,
        "rate_advisory": adv["message_tl"] if adv else
                         "none (no previous month in /meralco_rates_history, or no kWh yet)",
        "pushed":        bool(adv and first_time),
    }

# ── Forecast Endpoint ──────────────────────────────────────────────────────────
@app.post("/forecast")
def forecast():
    """User-triggered forecast (the app's refresh). Scheduled runs use the same
    computation: see FORECAST_SCHEDULE."""
    return run_forecast("user")


def run_forecast(trigger_source: str = "user") -> dict:
    """
    Same computation as the paper (Chapter III) and
    GRID_Forecast_Check.ipynb, via forecast_retrain.py:
      clean total today  = SVR on level-normalised inputs (anomalous readings excluded)
      day total          = clean total + anomalous so far + expected anomalous energy still to come
      projected EOM      = past days metered + day total + remaining days x EWMA(true daily kWh)
      calibrated EOM     = k x projected EOM  ->  bracket and itemized bill
    """
    latest = get_latest_averaged_reading()
    if latest is None:
        raise HTTPException(status_code=503, detail="No data available yet.")
    with _forecast_lock:                              # one forecast at a time (user + scheduled)
        return _run_forecast_locked(latest, trigger_source)


def _run_forecast_locked(latest, trigger_source: str) -> dict:
    fb, ab = FORECAST_BUNDLE, ANOMALY_BUNDLE          # read once (hot reload safe)
    now = datetime.now(PH_TZ)

    F = _forecast_frame(fb, ab, now.date())          # cached history + today's readings only

    # Billing cycle: 28th -> 27th. accumulated = adjusted cumul_kwh (same as the dashboard)
    cutoff_dt   = datetime.strptime(BILLING_CUTOFF_DATE, "%Y-%m-%d").date()
    days_so_far = (now.date() - cutoff_dt).days
    billing_end = now.replace(day=27) if now.day <= 27 else (
        now.replace(month=now.month + 1, day=27) if now.month < 12
        else now.replace(year=now.year + 1, month=1, day=27)
    )
    accumulated_kwh = float(latest["cumul_kwh"])

    f = fr.forecast_now(F, fb, accumulated_kwh, now.replace(tzinfo=None), billing_end.date())

    # Itemized bill on the calibrated, whole-kWh projection (as on the actual bill)
    try:
        bill = compute_bill(get_current_schedule_filename(), round(f["projected_eom_calibrated_kWh"]))
    except Exception as e:
        bill = {"error": str(e)}

    result = {
        "status":                  "ok",
        "timestamp":               now.isoformat(),
        "billing_cycle_start":     BILLING_CUTOFF_DATE,
        "days_so_far":             days_so_far,
        # same keys the app already reads
        "predicted_day_total_kWh": f["predicted_day_total_kWh"],
        "accumulated_past_kWh":    f["accumulated_past_kWh"],
        "combined_kWh":            f["combined_kWh"],
        "avg_daily_kWh":           f["ewma_daily_kWh"],      # now the EWMA used for the remaining days
        "days_remaining":          f["days_remaining"],
        "projected_eom_kWh":       f["projected_eom_kWh"],
        # new
        "predicted_clean_kWh":          f["predicted_clean_kWh"],
        "anomalous_so_far_kWh":         f["anomalous_so_far_kWh"],
        "expected_rest_anomalous_kWh":  f["expected_rest_anomalous_kWh"],
        "calibration_k":                f["calibration_k"],
        "projected_eom_calibrated_kWh": f["projected_eom_calibrated_kWh"],
        "bracket":                      f["bracket"],
        "projected_bill":               bill,
        "forecast_version":             f["forecast_version"],
        "anomaly_version":              ab.get("version", "june-v2"),
        "trigger_source":               trigger_source,
    }

    firebase_db.reference("/forecast").set(result)
    log_forecast(result, now.replace(tzinfo=None), trigger_source)

    # NLG: cycle status + projection (one merged message), this month's rate
    # effect on the household, and the daily advisory
    advisories = nlg.plan_advisories([
        nlg.build_cycle_advisory(
            accumulated_kwh=accumulated_kwh * f["calibration_k"],   # billed kWh so far
            projected_kwh=f["projected_eom_calibrated_kWh"],
            days_so_far=days_so_far,
            days_left=f["days_remaining"],
            projected_bill_php=bill_total(bill),
            calibration_k=f["calibration_k"],
            avoid_id=last_template_id("cycle"),
        ),
        household_rate_advisory(f["projected_eom_calibrated_kWh"], "projected", push=False),
        nlg.build_daily_advisory(
            predicted_total_kwh=f["predicted_day_total_kWh"],
            typical_daily_kwh=f["ewma_daily_kWh"],
            anomalous_kwh=f["anomalous_so_far_kWh"] + f["expected_rest_anomalous_kWh"],
            avoid_id=last_template_id("daily"),
        ),
    ])
    for adv in advisories:
        publish_advisory(adv)

    result["advisories"] = advisories
    return result


def bill_total(bill) -> Optional[float]:
    """Total amount from compute_bill(). The notebook's version returns
    "total_energy_amount"; the other keys are fallbacks."""
    if not isinstance(bill, dict) or "error" in bill:
        return None
    for key in ("total_energy_amount", "total_bill", "total", "total_amount"):
        if isinstance(bill.get(key), (int, float)):
            return float(bill[key])
    return None


@app.get("/forecast-model")
def forecast_model_info():
    b = FORECAST_BUNDLE
    return {"version": b.get("version"), "train_window": b.get("train_window"),
            "last_refit": b.get("last_refit"), "refit_reason": b.get("refit_reason"),
            "anomaly_version": b.get("anomaly_version"), "inputs": b["ln_columns"],
            "svr": {k: b["svr"].get_params()[k] for k in ("C", "epsilon", "gamma")},
            "calibration_k": b["eom"]["k_pooled"]}


@app.post("/forecast-model/check-refit")
def forecast_model_check_now(force: bool = False):
    """Same as the nightly job: refits only if due (weekly, or the anomaly model changed).
    force=true refits regardless. A refit installs within a minute."""
    today = datetime.now(PH_TZ).date()
    due, reason = fr.refit_due(FORECAST_BUNDLE, ANOMALY_BUNDLE, today)
    if not due and not force:
        return {"refit": False, "reason": reason, "version": FORECAST_BUNDLE.get("version"),
                "last_refit": FORECAST_BUNDLE.get("last_refit")}
    with get_conn() as conn:
        status = fr.run_refit_if_due(conn, FORECAST_BUNDLE, ANOMALY_BUNDLE, MODEL_DIR, today,
                                     force_reason=None if due else "manual")
    print(f"📈 Forecast refit check: {status}")
    return status


# ── Weekly Comparison Endpoint ────────────────────────────────────────────────
@app.get("/history/weekly-comparison")
def get_weekly_comparison():
    """
    Returns daily kWh for current week (Sun→today) and last week (Sun→Sat).
    Week landmark: Sunday to Saturday.
    No date params needed — auto-computed from today's PH date.
    One call covers both weeks. ✅
    """
    today = datetime.now(PH_TZ).date()
 
    # Find this week's Sunday
    days_since_sunday  = (today.weekday() + 1) % 7
    this_sunday        = today - timedelta(days=days_since_sunday)
 
    # Current week: this Sunday → today (may be incomplete)
    current_week_start = this_sunday
    current_week_end   = today
 
    # Last week: previous Sunday → previous Saturday (always complete)
    last_week_start    = this_sunday - timedelta(days=7)
    last_week_end      = this_sunday - timedelta(days=1)
 
    def fetch_week(start, end):
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT
                        DATE(timestamp)                       AS day,
                        ROUND(SUM(interval_kwh)::numeric, 4) AS daily_kwh
                    FROM readings
                    WHERE DATE(timestamp) BETWEEN %s AND %s
                    GROUP BY DATE(timestamp)
                    ORDER BY day ASC
                    """,
                    (str(start), str(end))
                )
                rows = cur.fetchall()
 
        # Build full week map (missing days = 0.0)
        result = {}
        for row in rows:
            result[str(row[0])] = float(row[1])
 
        # Fill missing days with 0.0
        current = start
        while current <= end:
            if str(current) not in result:
                result[str(current)] = 0.0
            current += timedelta(days=1)
 
        return [
            {"date": d, "daily_kwh": result[d]}
            for d in sorted(result)
        ]
 
    current_week_data = fetch_week(current_week_start, current_week_end)
    last_week_data    = fetch_week(last_week_start, last_week_end)

    # NLG: completed days of this week vs the same weekdays of last week (in-app only)
    weekly_adv = nlg.build_weekly_advisory(
        current_week_data, last_week_data, str(today),
        avoid_id=last_template_id("weekly"))
    publish_advisory(weekly_adv)

    return {
        "advisory": weekly_adv,
        "status": "ok",
        "current_week": {
            "start":      str(current_week_start),
            "end":        str(current_week_end),
            "total_kwh":  round(sum(d["daily_kwh"] for d in current_week_data), 4),
            "is_complete": today.weekday() == 5,  # True only on Saturday
            "data":       current_week_data,
        },
        "last_week": {
            "start":      str(last_week_start),
            "end":        str(last_week_end),
            "total_kwh":  round(sum(d["daily_kwh"] for d in last_week_data), 4),
            "is_complete": True,
            "data":       last_week_data,
        },
    }

# ── Historical Data Endpoint ───────────────────────────────────────────────────
@app.get("/history/{date_str}")
def get_history(date_str: str):
    global MERALCO_RATES
    """
    Returns hourly aggregated interval_kwh for any past date.
    Queries PostgreSQL directly.
    date_str format: YYYY-MM-DD
    """

    bracket = "0-200"
    rate_per_kwh = MERALCO_RATES["brackets"][bracket]
    fixed_charge = MERALCO_RATES["fixed_charge"]
    
    try:
        datetime.strptime(date_str, "%Y-%m-%d")
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="Invalid date format. Use YYYY-MM-DD (e.g. 2026-07-08)"
        )

    rows = get_hourly_kwh_by_date(date_str)

    if not rows:
        raise HTTPException(
            status_code=404,
            detail=f"No data found for {date_str}"
        )

    data = [
        {
            "hour":       row[0],
            "hour_label": f"{row[0]:02d}:00",
            "total_kwh":  float(row[1])
        }
        for row in rows
    ]

    daily_total = round(sum(d["total_kwh"] for d in data), 4)
    estimated_cost = daily_total * rate_per_kwh + fixed_charge

    return {
        "status":          "ok",
        "date":            date_str,
        "daily_total_kwh": daily_total,
        "estimated_cost":  estimated_cost,
        "data":            data
    }

# ── Anomaly Logs Endpoints ─────────────────────────────────────────────────────
@app.get("/anomaly-logs/pending")
def get_pending_anomalies():
    """
    Unreviewed anomaly rows, one per 5-min reading (kept for compatibility).
    The app should use GET /anomaly-events/pending (one card per event) instead.
    """
    with get_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT * FROM anomaly_logs
                WHERE reviewed_at IS NULL AND expired_at IS NULL
                ORDER BY timestamp DESC
                """
            )
            rows = cur.fetchall()

    return {
        "status": "ok",
        "count":  len(rows),
        "data":   [dict(r) for r in rows]
    }


@app.get("/anomaly-events/pending")
def get_pending_anomaly_events():
    """
    One card per unanswered anomaly event from the last 7 days, newest first.
      status "open"   -> still happening: message only, no answer buttons
      status "closed" -> past-tense message, summary (minutes, kWh, ≈ ₱),
                         the three answers, and chart data for the app to draw
    Each row's timestamp is the END of its 5-minute window.
    """
    now = datetime.now(PH_TZ)
    now_n = now.replace(tzinfo=None)
    with get_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT a.event_id,
                       MIN(a.timestamp)                                   AS first_ts,
                       MAX(a.timestamp)                                   AS last_ts,
                       COUNT(*)                                           AS readings,
                       ARRAY_AGG(a.id ORDER BY a.timestamp)               AS log_ids,
                       MAX(a.power_avg)                                   AS peak_power,
                       MAX(a.time_zscore)                                 AS peak_z,
                       (ARRAY_AGG(a.roll_mean_1hr ORDER BY a.power_avg DESC))[1] AS baseline_1hr,
                       (ARRAY_AGG(a.power_avg ORDER BY ABS(a.power_avg - a.roll_mean_1hr)
                                  DESC NULLS LAST))[1]                   AS dev_power,
                       (ARRAY_AGG(a.roll_mean_1hr ORDER BY ABS(a.power_avg - a.roll_mean_1hr)
                                  DESC NULLS LAST))[1]                   AS dev_baseline,
                       SUM(r.interval_kwh)                                AS event_kwh,
                       MAX(a.event_closed_at)                             AS closed_at
                FROM anomaly_logs a
                LEFT JOIN readings r ON r.id = a.reading_id
                WHERE a.reviewed_at IS NULL AND a.expired_at IS NULL
                GROUP BY a.event_id
                HAVING MAX(a.timestamp) >= %s
                ORDER BY MIN(a.timestamp) DESC
                """,
                (now_n - nlg.REVIEW_EXPIRY,),
            )
            rows = cur.fetchall()

            charts = {}
            pad = timedelta(minutes=30)
            for r in rows:
                cur.execute(
                    """
                    SELECT r.timestamp, r.power_avg, (a.id IS NOT NULL) AS flagged
                    FROM readings r
                    LEFT JOIN anomaly_logs a ON a.reading_id = r.id
                    WHERE r.timestamp BETWEEN %s AND %s
                    ORDER BY r.timestamp
                    """,
                    (r["first_ts"] - pad, r["last_ts"] + pad),
                )
                charts[r["event_id"]] = [
                    {"t": p["timestamp"].isoformat(), "w": round(float(p["power_avg"] or 0), 1),
                     "flagged": bool(p["flagged"])}
                    for p in cur.fetchall()
                ]

    latest = get_latest_averaged_reading()
    current_billed = float(latest["cumul_kwh"]) * calibration_k() if latest else 0.0

    events = []
    for r in rows:
        start = r["first_ts"] - timedelta(seconds=BUFFER_SECONDS)   # rows mark the window END
        end = r["last_ts"]
        z = float(r["peak_z"]) if r["peak_z"] is not None else None
        status = nlg.event_status(r["last_ts"], now_n, r["closed_at"])
        kwh = float(r["event_kwh"]) if r["event_kwh"] is not None else None
        # State the reading that explains the flag: the highest one when the event is
        # high for this hour (z >= 3), else the one furthest from its last-hour mean
        # (a sudden rise or drop).
        if z is not None and z >= nlg.SEVERITY_BANDS[-1][1]:
            say_power, say_base = r["peak_power"], r["baseline_1hr"]
        else:
            say_power, say_base = r["dev_power"], r["dev_baseline"]
        card = nlg.build_anomaly_review(
            event_id=r["event_id"],
            peak_power=float(say_power or 0),
            baseline_1hr=float(say_base) if say_base is not None else None,
            peak_z=z, start=start, end=end, today=now.date(), status=status,
            event_kwh=kwh,
            event_cost_php=event_cost_php(kwh, current_billed) if kwh else None,
        )
        events.append({
            "event_id":     r["event_id"],
            "start":        start.isoformat(),
            "end":          end.isoformat(),
            "duration_min": int((end - start).total_seconds() // 60),
            "readings":     r["readings"],
            "log_ids":      list(r["log_ids"]),
            "peak_power_w": float(r["peak_power"] or 0),
            "peak_zscore":  z,
            "event_kwh":    round(kwh, 4) if kwh is not None else None,
            "chart": {
                "baseline_w": float(r["baseline_1hr"]) if r["baseline_1hr"] is not None else None,
                "baseline_label_tl": "Karaniwan sa nakaraang 1 oras",
                "points": charts.get(r["event_id"], []),
            },
            **card,
        })

    return {"status": "ok", "count": len(events), "data": events}


class ReviewRequest(BaseModel):
    answer: str   # "real" (Totoong kakaiba) | "normal" (Normal na gamit) | "unsure" (Hindi sigurado)

REVIEW_ANSWERS = {o["answer"]: o["acknowledged"] for o in nlg.HITL_OPTIONS}

@app.post("/anomaly-events/{event_id}/review")
def review_anomaly_event(event_id: int, body: ReviewRequest):
    """
    HITL answer for a whole event (all its 5-min rows at once).
      real   -> acknowledged = TRUE   (label: real anomaly)
      normal -> acknowledged = FALSE  (label: normal use)
      unsure -> acknowledged = NULL   (left unlabeled, as in the paper)
    All three set reviewed_at, so the event leaves the pending list.
    """
    global ANOMALY_EVENT
    if body.answer not in REVIEW_ANSWERS:
        raise HTTPException(status_code=422,
                            detail=f"answer must be one of {sorted(REVIEW_ANSWERS)}")
    acknowledged = REVIEW_ANSWERS[body.answer]

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE anomaly_logs
                SET acknowledged = %s, reviewed_at = %s
                WHERE event_id = %s AND reviewed_at IS NULL
                RETURNING id
                """,
                (acknowledged, ph_now_naive(), event_id),
            )
            updated = [r[0] for r in cur.fetchall()]
            if not updated:
                cur.execute("SELECT 1 FROM anomaly_logs WHERE event_id = %s LIMIT 1", (event_id,))
                exists = cur.fetchone()
        conn.commit()

    if not updated:
        if not exists:
            raise HTTPException(status_code=404, detail=f"Anomaly event {event_id} not found")
        return {"status": "already_reviewed", "event_id": event_id, "updated": []}

    # Answered: later flagged readings start a new event (and a new prompt)
    if ANOMALY_EVENT and ANOMALY_EVENT.get("event_id") == event_id:
        ANOMALY_EVENT = None
    try:
        firebase_db.reference(f"{ADVISORY_REF}/anomaly/answered").set(
            {"event_id": event_id, "answer": body.answer})
    except Exception as e:
        print(f"❌ Advisory answer write failed: {e}")

    return {"status": "ok", "event_id": event_id, "answer": body.answer,
            "acknowledged": acknowledged, "updated": updated}


class AcknowledgeRequest(BaseModel):
    acknowledged: bool   # true = real anomaly | false = false alarm

@app.patch("/anomaly-logs/{log_id}/acknowledge")
def acknowledge_anomaly(log_id: int, body: AcknowledgeRequest):
    """
    Single-row answer (kept for compatibility; the app should review whole
    events via POST /anomaly-events/{event_id}/review).
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE anomaly_logs
                SET acknowledged = %s, reviewed_at = %s
                WHERE id = %s
                RETURNING id
                """,
                (body.acknowledged, ph_now_naive(), log_id)
            )
            updated = cur.fetchone()
        conn.commit()

    if not updated:
        raise HTTPException(status_code=404, detail=f"Anomaly log {log_id} not found")

    return {
        "status":        "ok",
        "id":            log_id,
        "acknowledged":  body.acknowledged,
    }

# ── Billing Info Endpoint ──────────────────────────────────────────────────────
@app.get("/billing-info")
def billing_info():
    """
    Returns current billing baseline info.
    Useful for debugging and mobile app display.
    """
    return {
        "billing_cutoff_date":  BILLING_CUTOFF_DATE,
        "billing_baseline_kwh": BILLING_BASELINE_KWH,
        "billing_computed": BILLING_COMPUTED
    }

#GET /bill/breakdown?kwh=219
@app.get("/bill/breakdown")
def get_bill_breakdown(
    kwh: float = Query(..., gt=0, description="Consumption in kWh"),
):
    """On-demand itemized bill breakdown for a given consumption value.
    NOT part of the 2-second loop — that reads cached rates from Firebase
    instead. This endpoint is for when a user actually wants to see
    Generation/Transmission/VAT/etc. broken out."""
    pdf_filename = get_current_schedule_filename()

    try:
        result = compute_bill(pdf_filename, kwh)
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except ValueError as e:
        raise HTTPException(status_code=500, detail=f"Could not parse rate schedule: {e}")

    return {
        "kwh": kwh,
        "source_file": "https://company.meralco.com.ph/news-and-advisories/rates-archives/",
        **result,
    }



@app.get("/calculator/convert")
def convert(
    period: str = Query(..., description="Rate schedule PDF filename, e.g. '08-2026_rate_schedule.pdf'"),
    kwh: Optional[float] = Query(None, gt=0, description="Consumption in kWh — returns itemized peso breakdown"),
    peso: Optional[float] = Query(None, gt=0, description="Peso amount — returns the equivalent kWh"),
):
    """Calculator for the app. Exactly one of kwh/peso must be given:
    kwh -> full itemized peso breakdown (reuses compute_bill directly).
    peso -> just the equivalent kWh (uses the inverse formula above)."""
    if (kwh is None) == (peso is None):
        raise HTTPException(status_code=422, detail="Provide exactly one of 'kwh' or 'peso', not both or neither.")

    try:
        if kwh is not None:
            result = compute_bill(period, kwh)
            return {"kwh": kwh, "period": period, **result}
        else:
            result_kwh = peso_to_kwh(period, peso)
            return {"peso": peso, "period": period, "kwh": result_kwh}
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except ValueError as e:
        raise HTTPException(status_code=500, detail=f"Could not compute: {e}")

# ── Health Check ───────────────────────────────────────────────────────────────
@app.get("/")
def root():
    return {"status": "Energy Monitor API running"}