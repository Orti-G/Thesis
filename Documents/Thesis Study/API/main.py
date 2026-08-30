from fastapi import FastAPI, HTTPException
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
import firebase_admin
from firebase_admin import credentials, db as firebase_db, messaging

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

forecast_bundle   = joblib.load(os.path.join(MODEL_DIR, "forecast_model.pkl"))
FORECAST_MODEL    = forecast_bundle["model"]
FORECAST_SCALER   = forecast_bundle["scaler"]        # None for Random Forest
FORECAST_FEATURES = forecast_bundle["feature_cols"]
# ['today_kwh_so_far', 'frac_day_elapsed', 'Interval kWh', 'Hour', 'dow', 'Weekend']

anomaly_bundle    = joblib.load(os.path.join(MODEL_DIR, "anomaly_model.pkl"))
ANOMALY_MODEL     = anomaly_bundle["model"]
ANOMALY_SCALER    = anomaly_bundle["scaler"]
ANOMALY_FEATURES  = anomaly_bundle["feature_cols"]
# ['Voltage (V)', 'Current (A)', 'Power (W)', 'Interval kWh',
#  'Roll mean 1hr', 'Roll mean 24hr', 'Dev 1hr', 'Dev 24hr']

# Rolling window sizes (5-min intervals)
WINDOW_1HR  = 12
WINDOW_24HR = 288

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
    global BILLING_BASELINE_KWH, BILLING_CUTOFF_DATE, BILLING_COMPUTED
    global last_pushed_hour, last_pushed_date

    computed_cutoff = compute_billing_cutoff()
    state = load_billing_state()

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
                     dev_1hr, dev_24hr, acknowledged)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
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

def push_to_firebase(raw: dict, adjusted_cumul: float):
    """Push all 6 live measurements to Firebase /live_reading."""
    firebase_db.reference("/live_reading").set({
        "voltage":      raw["voltage"],
        "current":      raw["current"],
        "power":        raw["power"],
        "cumul_kwh":    adjusted_cumul,   # ← adjusted (current cycle only)
        "power_factor": raw["power_factor"],
        "frequency":    raw["frequency"],
        "timestamp":    raw["timestamp"],
    })

# ── FCM Push Notification ──────────────────────────────────────────────────────
def send_fcm_alert(title: str, body: str, data: dict = None):
    """
    Sends FCM push notification to ALL registered devices.
    """
    try:
        tokens_ref = firebase_db.reference("/device_tokens").get()

        if not tokens_ref:
            print("❌ No device tokens registered")
            return

        tokens = list(tokens_ref.values())

        if not tokens:
            return

        # Send to all registered devices using multicast
        message = messaging.MulticastMessage(
            notification=messaging.Notification(
                title=title,
                body=body,
            ),
            data={k: str(v) for k, v in (data or {}).items()},
            tokens=tokens,
        )

        response = messaging.send_each_for_multicast(message)
        print(f"✅ FCM sent to {response.success_count} devices")

        # Clean up invalid tokens
        if response.failure_count > 0:
            for idx, result in enumerate(response.responses):
                if not result.success:
                    failed_token = tokens[idx]
                    safe_key = failed_token[-20:].replace(":", "_").replace("-", "_")
                    firebase_db.reference(f"/device_tokens/{safe_key}").delete()
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
    global last_pushed_hour, last_pushed_date

    today        = now.strftime("%Y-%m-%d")
    current_hour = now.hour

    # Midnight reset
    if today != last_pushed_date:
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
    global reading_buffer

    if len(reading_buffer) < 2:
        reading_buffer = []
        return

    voltages  = [r["voltage"]   for r in reading_buffer]
    currents  = [r["current"]   for r in reading_buffer]
    powers    = [r["power"]     for r in reading_buffer]
    cumuls    = [r["cumul_kwh"] for r in reading_buffer]

    avg_voltage  = round(float(np.mean(voltages)), 2)
    avg_current  = round(float(np.mean(currents)), 3)
    avg_power    = round(float(np.mean(powers)),   2)
    interval_kwh = round(float(cumuls[-1] - cumuls[0]), 4)
    window_ts    = datetime.now(PH_TZ).replace(tzinfo=None)

    # cumul_kwh — continue from last DB value if ESP32 reset detected
    last_db_row = get_latest_averaged_reading()
    if last_db_row and float(cumuls[-1]) < float(last_db_row["cumul_kwh"]):
        raw_cumul = round(float(last_db_row["cumul_kwh"]) + float(cumuls[-1]), 4)
    else:
        raw_cumul = round(float(cumuls[-1]), 4)

    # Adjust cumul_kwh for current billing cycle
    adjusted_cumul = adjust_cumul(raw_cumul)

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
    anomaly_result = run_anomaly(
        voltage=avg_voltage,
        current=avg_current,
        power=avg_power,
        interval_kwh=interval_kwh,
    )

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
        })
        send_fcm_alert(
                    title="⚠️ Anomalya Natukoy",
                    body=f"Hindi karaniwan ang kuryente: {avg_power:.1f}W. Normal ba ito?",
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
        })
        

    # Push today's hourly history to Firebase (Option C)
    push_hourly_history(datetime.now(PH_TZ))

    reading_buffer = []
    return anomaly_result


def run_anomaly(voltage, current, power, interval_kwh):
    """
    Compute rolling features from DB history and run Isolation Forest.
    """
    rows = get_recent_averaged_readings(WINDOW_24HR)

    if len(rows) < 2:
        return {"status": "collecting_data", "is_anomaly": False, "score": None}

    df           = pd.DataFrame(rows)
    power_series = pd.concat(
        [df["power_avg"], pd.Series([power])],
        ignore_index=True,
    )

    roll_mean_1hr  = power_series.rolling(WINDOW_1HR,  min_periods=1).mean().iloc[-1]
    roll_mean_24hr = power_series.rolling(WINDOW_24HR, min_periods=1).mean().iloc[-1]
    dev_1hr        = power - roll_mean_1hr
    dev_24hr       = power - roll_mean_24hr

    feature_row = pd.DataFrame([{
        "Voltage (V)":    voltage,
        "Current (A)":   current,
        "Power (W)":     power,
        "Interval kWh":  interval_kwh,
        "Roll mean 1hr":  float(roll_mean_1hr),
        "Roll mean 24hr": float(roll_mean_24hr),
        "Dev 1hr":        float(dev_1hr),
        "Dev 24hr":       float(dev_24hr),
    }])[ANOMALY_FEATURES]

    scaled = ANOMALY_SCALER.transform(feature_row)
    pred   = ANOMALY_MODEL.predict(scaled)[0]         # 1=normal, -1=anomaly
    score  = ANOMALY_MODEL.score_samples(scaled)[0]   # more negative = more anomalous

    return {
        "status":         "ok",
        "is_anomaly":     bool(pred == -1),
        "score":          round(float(score), 4),
        "roll_mean_1hr":  round(float(roll_mean_1hr), 4),
        "roll_mean_24hr": round(float(roll_mean_24hr), 4),
        "dev_1hr":        round(float(dev_1hr), 4),
        "dev_24hr":       round(float(dev_24hr), 4),
    }


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
    global reading_buffer

    now            = datetime.now(PH_TZ)
    adjusted_cumul = adjust_cumul(data.cumul_kwh)

    # 1. Push all 6 to Firebase (adjusted cumul_kwh)
    push_to_firebase({
        "voltage":      data.voltage,
        "current":      data.current,
        "power":        data.power,
        "power_factor": data.power_factor,
        "frequency":    data.frequency,
        "timestamp":    now.isoformat(),
    }, adjusted_cumul)

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


# ── Forecast Endpoint ──────────────────────────────────────────────────────────
@app.post("/forecast")
def forecast():
    """
    User-triggered endpoint.
    Predicts today's day_total_kWh and estimates month-end consumption.
    Option B: month_end = consumed_so_far + (predicted_day x remaining_days)
    """
    latest = get_latest_averaged_reading()
    if latest is None:
        raise HTTPException(status_code=503, detail="No data available yet.")

    now      = datetime.now(PH_TZ)
    hour     = now.hour
    dow      = now.weekday()        # 0=Mon, 6=Sun
    weekend  = 1 if dow >= 5 else 0
    frac_day = (now.hour * 3600 + now.minute * 60 + now.second) / 86400

    # Compute today_kwh_so_far = SUM(interval_kwh) for today
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT COALESCE(SUM(interval_kwh), 0)
                FROM readings
                WHERE DATE(timestamp) = (now() AT TIME ZONE 'Asia/Manila')::date
                """
            )
            today_kwh_so_far = float(cur.fetchone()[0])

    feature_row = pd.DataFrame([{
        "today_kwh_so_far": today_kwh_so_far,
        "frac_day_elapsed": frac_day,
        "Interval kWh":     latest["interval_kwh"],
        "Hour":             hour,
        "dow":              dow,
        "Weekend":          weekend,
    }])[FORECAST_FEATURES]

    if FORECAST_SCALER is not None:
        feature_row = FORECAST_SCALER.transform(feature_row)

    predicted_day_kwh = float(FORECAST_MODEL.predict(feature_row)[0])

    # Month-end estimate (Option B)
    # accumulated_kwh = the same adjusted cumul_kwh shown on the dashboard —
    # total consumption since BILLING_CUTOFF_DATE up to the latest reading.
    accumulated_kwh = float(latest["cumul_kwh"])

    # Past-days total = accumulated so far MINUS today's so-far total.
    # Avoids a separate day-by-day GROUP BY query, which was vulnerable to
    # a timezone mismatch between Postgres' CURRENT_DATE and Asia/Manila "today".
    kwh_past_days = round(max(accumulated_kwh - today_kwh_so_far, 0.0), 4)

    # Days elapsed this cycle (cutoff day excluded, today included)
    cutoff_dt   = datetime.strptime(BILLING_CUTOFF_DATE, "%Y-%m-%d").date()
    days_so_far = (now.date() - cutoff_dt).days

    # Step 1: Combined kWh = Accumulated Past kWh + Today's ML Prediction
    combined_kwh = kwh_past_days + predicted_day_kwh

    # Step 2: Average daily kWh = Combined kWh / Days so far
    avg_daily_kwh = combined_kwh / days_so_far if days_so_far > 0 else 0.0

    # Step 3: Remaining days after today until billing end (27th)
    billing_end   = now.replace(day=27) if now.day <= 27 else (
        now.replace(month=now.month + 1, day=27) if now.month < 12
        else now.replace(year=now.year + 1, month=1, day=27)
    )
    remaining_days = (billing_end.date() - now.date()).days

    # Step 4: Projected EOM = Combined kWh + (Average Daily kWh x Remaining Days)
    projected_eom = combined_kwh + (avg_daily_kwh * remaining_days)

    result = {
        "status":                    "ok",
        "timestamp":                 now.isoformat(),
        "billing_cycle_start":       BILLING_CUTOFF_DATE,
        "predicted_day_total_kWh":   round(predicted_day_kwh, 4),
        "accumulated_past_kWh":      round(kwh_past_days, 4),
        "combined_kWh":              round(combined_kwh, 4),
        "days_so_far":               days_so_far,
        "avg_daily_kWh":             round(avg_daily_kwh, 4),
        "days_remaining":            remaining_days,
        "projected_eom_kWh":         round(projected_eom, 4),
    }

    firebase_db.reference("/forecast").set(result)

    # Log forecast to PostgreSQL
    log_forecast(result, datetime.now(PH_TZ).replace(tzinfo=None))

    return result

# ── Historical Data Endpoint ───────────────────────────────────────────────────
@app.get("/history/{date_str}")
def get_history(date_str: str):
    """
    Returns hourly aggregated interval_kwh for any past date.
    Queries PostgreSQL directly.
    date_str format: YYYY-MM-DD
    """
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

    return {
        "status":          "ok",
        "date":            date_str,
        "daily_total_kwh": daily_total,
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


# ── Health Check ───────────────────────────────────────────────────────────────
@app.get("/")
def root():
    return {"status": "Energy Monitor API running"}