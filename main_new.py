from fastapi import FastAPI, HTTPException, Query
from typing import Optional
from meralco_engine import compute_bill, RATE_SCHEDULE_DIR, peso_to_kwh
from pydantic import BaseModel
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import psycopg2
import psycopg2.extras
import joblib
import numpy as np
import pandas as pd
import calendar
import os
import re
import firebase_admin
from firebase_admin import credentials, db as firebase_db, messaging
import asyncio
import threading
import anomaly_retrain as ar    # shared with GRID_Anomaly_Drift_Check.ipynb
import forecast_retrain as fr   # shared with GRID_Forecast_Check.ipynb

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
            send_fcm_alert(
                title="⚠️ Device Offline",
                body="Ang IoT device ay hindi na naka-konekta. "
                     "Mangyaring suriin ang inyong koneksyon.",
                channel_id="high_channel",
                data={
                    "type":      "sync_lost",
                    "timestamp": datetime.now(PH_TZ).isoformat(),
                }
            )

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
    Log only detected anomalies (is_anomaly = True) to anomaly_logs.
    acknowledged = NULL by default (pending user review).
    Universal — works for IsolationForest, OneClassSVM, LOF.
    """
    if not anomaly_result.get("is_anomaly"):
        return
 
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO anomaly_logs
                    (timestamp, reading_id, is_anomaly,
                     anomaly_score, power_avg, roll_mean_1hr, roll_mean_24hr,
                     dev_1hr, dev_24hr, acknowledged, power_delta, time_zscore)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    window_ts,
                    reading_id,
                    True,
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
        conn.commit()

def log_forecast(result: dict, window_ts: datetime):
    """
    Log every forecast prediction to forecast_logs.
    Universal — works for Random Forest, LR, SVR.
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO forecast_logs
                    (timestamp, billing_cycle_start,
                     predicted_day_total_kwh, accumulated_past_kwh,
                     combined_kwh, days_so_far, avg_daily_kwh,
                     days_remaining, projected_eom_kwh)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    window_ts,
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

def push_to_firebase(raw: dict, adjusted_cumul: float, est_cost: float):
    """Push all 6 live measurements to Firebase /live_reading."""
    firebase_db.reference("/live_reading").set({
        "voltage":      raw["voltage"],
        "current":      raw["current"],
        "power":        raw["power"],
        "cumul_kwh":    adjusted_cumul,   # ← adjusted (current cycle only)
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
            return

        tokens = list(tokens_ref.values())

        if not tokens:
            print("❌ Token list is empty")
            return

        message = messaging.MulticastMessage(
            notification=messaging.Notification(
                title=title,
                body=body,
            ),
            android=messaging.AndroidConfig(
                notification=messaging.AndroidNotification(
                    channel_id=channel_id,
                    priority="high" if channel_id == "high_channel" else "normal",
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

    except Exception as e:
        print(f"❌ FCM error: {e}")

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
    global BILLING_BASELINE_KWH, BILLING_CUTOFF_DATE

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

        # Log anomaly to DB if detected (acknowledged = NULL)
        if anomaly_result.get("is_anomaly"):
            log_anomaly(
                reading_id=reading_id,
                anomaly_result=anomaly_result,
                avg_power=avg_power,
                window_ts=window_ts,
            )

        # Push anomaly result to Firebase
        if anomaly_result["is_anomaly"]:
            firebase_db.reference("/anomaly_alert").set({
                "is_anomaly": True,
                "score":      anomaly_result["score"],
                "timestamp":  window_ts.isoformat(),
                "power_avg":  avg_power,
                "power_delta": anomaly_result["power_delta"],
            })
            send_fcm_alert(
                title="⚠️ Anomalya Natukoy",
                body=f"Hindi karaniwan ang kuryente: {avg_power:.1f}W. "
                f"Suriin at kumpirmahin kung normal ito.",
                channel_id="high_channel",
                    data={
                        "type":      "anomaly",
                        "power_avg": str(avg_power),
                        "timestamp": window_ts.isoformat(),
                    }
                )
        else:
            firebase_db.reference("/anomaly_alert").set({
                "is_anomaly": False,
                "score":      anomaly_result["score"],
                "timestamp":  window_ts.isoformat(),
                "power_avg":  avg_power,
                "power_delta": anomaly_result["power_delta"],
            })
            

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
    # If the anomaly model was refit, the forecast refit follows its install (next tick).
    # Otherwise check the weekly forecast refit now.
    if not status.get("refit"):
        _forecast_refit_if_due()


async def anomaly_model_watcher():
    """Background task. Every minute: install a waiting model (hot reload).
    Once a day after midnight: drift check; a refit drops its pkl in incoming/,
    which the next tick installs. Heavy work runs in a thread, not on the event loop."""
    global last_drift_check_date
    while True:
        await asyncio.sleep(MODEL_WATCH_SECONDS)
        try:
            await asyncio.to_thread(_install_new_model_if_any)
        except Exception as e:
            print(f"❌ Model install failed (old model kept): {e}")

        now = datetime.now(PH_TZ)
        today = now.strftime("%Y-%m-%d")
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

    bracket = "0-200" if adjusted_cumul <= 200 else "201-300" if adjusted_cumul <= 300 else "301-400" if adjusted_cumul <= 400 else "over-400"

    rate_per_kwh = MERALCO_RATES["brackets"][bracket]
    fixed_charge = MERALCO_RATES["fixed_charge"]

    estimated_cost = adjusted_cumul * rate_per_kwh + fixed_charge

    # 1. Push all 6 to Firebase (adjusted cumul_kwh)
    push_to_firebase({
        "voltage":      data.voltage,
        "current":      data.current,
        "power":        data.power,
        "power_factor": data.power_factor,
        "frequency":    data.frequency,
        "timestamp":    now.isoformat(),
    }, adjusted_cumul, estimated_cost)

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
def refresh_rates():
    global MERALCO_RATES
    MERALCO_RATES = firebase_db.reference("/meralco_rates").get()
    return {"status": "ok", "message": "Meralco rates refreshed"}

# ── Forecast Endpoint ──────────────────────────────────────────────────────────
@app.post("/forecast")
def forecast():
    """
    User-triggered endpoint. Same computation as the paper (Chapter III) and
    GRID_Forecast_Check.ipynb, via forecast_retrain.py:
      clean total today  = SVR on level-normalised inputs (anomalous readings excluded)
      day total          = clean total + anomalous so far + expected anomalous energy still to come
      projected EOM      = past days metered + day total + remaining days x EWMA(true daily kWh)
      calibrated EOM     = k x projected EOM  ->  bracket and itemized bill
    """
    latest = get_latest_averaged_reading()
    if latest is None:
        raise HTTPException(status_code=503, detail="No data available yet.")

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
    }

    firebase_db.reference("/forecast").set(result)
    log_forecast(result, now.replace(tzinfo=None))
    return result


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
 
    return {
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
    Returns all anomaly logs where acknowledged IS NULL.
    These are the unreviewed alerts shown on mobile UI.
    """
    with get_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT * FROM anomaly_logs
                WHERE acknowledged IS NULL
                ORDER BY timestamp DESC
                """
            )
            rows = cur.fetchall()
 
    return {
        "status": "ok",
        "count":  len(rows),
        "data":   [dict(r) for r in rows]
    }
 

class AcknowledgeRequest(BaseModel):
    acknowledged: bool   # true = real anomaly | false = false alarm
 
@app.patch("/anomaly-logs/{log_id}/acknowledge")
def acknowledge_anomaly(log_id: int, body: AcknowledgeRequest):
    """
    User reviews an anomaly alert on mobile.
    Sets acknowledged = true (real) or false (false alarm).
    Record disappears from pending UI after this. ✅
    Used for HITL retraining later.
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE anomaly_logs
                SET acknowledged = %s
                WHERE id = %s
                RETURNING id
                """,
                (body.acknowledged, log_id)
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