from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
import psycopg2
import psycopg2.extras
import joblib
import numpy as np
import pandas as pd
import calendar
import os
import firebase_admin
from firebase_admin import credentials, db as firebase_db

app = FastAPI()

# ── Timezone ───────────────────────────────────────────────────────────────────
PH_TZ = ZoneInfo("Asia/Manila")

# ── Firebase Setup ─────────────────────────────────────────────────────────────
# Download your Firebase service account JSON from Firebase Console and
# place it at ~/energy_app/firebase_key.json
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
# ['Cumul kWh', 'frac_day_elapsed', 'Interval kWh', 'Hour', 'dow', 'Weekend']

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


def push_to_firebase(raw: dict):
    """
    Push all 6 live measurements to Firebase Realtime DB.
    Mobile app reads from: /live_reading
    """
    firebase_db.reference("/live_reading").set({
        "voltage":      raw["voltage"],
        "current":      raw["current"],
        "power":        raw["power"],
        "cumul_kwh":    raw["cumul_kwh"],
        "power_factor": raw["power_factor"],
        "frequency":    raw["frequency"],
        "timestamp":    raw["timestamp"],
    })


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

    avg_voltage  = float(np.mean(voltages))
    avg_current  = float(np.mean(currents))
    avg_power    = float(np.mean(powers))
    interval_kwh = float(cumuls[-1] - cumuls[0])   # energy consumed this window
    window_ts    = datetime.now(PH_TZ)


    # cumul_kwh — continue from last DB value if ESP32 reset detected
    last_db_row = get_latest_averaged_reading()
    if last_db_row and float(cumuls[-1]) < float(last_db_row["cumul_kwh"]):
        # ESP32 reset — offset from last DB cumul_kwh
        last_cumul = float(last_db_row["cumul_kwh"]) + float(cumuls[-1])
    else:
        last_cumul = float(cumuls[-1])
     
        
    # Save averaged row to PostgreSQL
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO readings
                    (timestamp, voltage, current, power_avg, interval_kwh, cumul_kwh)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (window_ts, avg_voltage, avg_current,
                 avg_power, interval_kwh, last_cumul),
            )
        conn.commit()

    # Run anomaly detection on this averaged row
    anomaly_result = run_anomaly(
        voltage=avg_voltage,
        current=avg_current,
        power=avg_power,
        interval_kwh=interval_kwh,
    )

    # Push anomaly result to Firebase
    if anomaly_result["is_anomaly"]:
        firebase_db.reference("/anomaly_alert").set({
            "is_anomaly": True,
            "score":      anomaly_result["score"],
            "timestamp":  window_ts.isoformat(),
            "power_avg":  avg_power,
        })
    else:
        firebase_db.reference("/anomaly_alert").set({
            "is_anomaly": False,
            "score":      anomaly_result["score"],
            "timestamp":  window_ts.isoformat(),
        })

    # Clear buffer for next window
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
        "status":     "ok",
        "is_anomaly": bool(pred == -1),
        "score":      round(float(score), 4),
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

    1. Pushes all 6 to Firebase instantly (live view on mobile)
    2. Buffers voltage, current, power, cumul_kwh for 5-min averaging
    3. Every 5 minutes: averages buffer → saves to PostgreSQL → runs anomaly
    """
    global reading_buffer

    now = datetime.now(PH_TZ)

    # 1. Push all 6 to Firebase for live view
    push_to_firebase({
        "voltage":      data.voltage,
        "current":      data.current,
        "power":        data.power,
        "cumul_kwh":    data.cumul_kwh,
        "power_factor": data.power_factor,
        "frequency":    data.frequency,
        "timestamp":    now.isoformat(),
    })

    # 2. Add to 5-min buffer (only 4 ML-relevant fields)
    reading_buffer.append({
        "voltage":   data.voltage,
        "current":   data.current,
        "power":     data.power,
        "cumul_kwh": data.cumul_kwh,
        "ts":        now,
    })

    # 3. Check if 5-minute window has elapsed
    anomaly_result = None
    if len(reading_buffer) >= 2:
        elapsed = (reading_buffer[-1]["ts"] - reading_buffer[0]["ts"]).total_seconds()
        if elapsed >= BUFFER_SECONDS:
            anomaly_result = flush_buffer()

    return {
        "status":      "ok",
        "timestamp":   now.isoformat(),
        "buffer_size": len(reading_buffer),
        "anomaly":     anomaly_result,   # None until first 5-min flush
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

    feature_row = pd.DataFrame([{
        "Cumul kWh":        latest["cumul_kwh"],
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
    today          = now.day
    days_in_month  = calendar.monthrange(now.year, now.month)[1]
    days_remaining = days_in_month - today

    # kWh at start of today
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT cumul_kwh FROM readings
                WHERE timestamp >= date_trunc('day', NOW() AT TIME ZONE 'UTC')
                ORDER BY timestamp ASC
                LIMIT 1
                """,
            )
            row = cur.fetchone()
    kwh_start_of_day = float(row[0]) if row else 0.0

    # Sum of completed past days this month
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT DATE(timestamp) as day,
                       MAX(cumul_kwh) - MIN(cumul_kwh) as daily_kwh
                FROM readings
                WHERE DATE(timestamp) < CURRENT_DATE
                GROUP BY DATE(timestamp)
                """,
            )
            past_days = cur.fetchall()

    kwh_past_days = sum(r[1] for r in past_days if r[1] is not None)
    kwh_today     = float(latest["cumul_kwh"]) - kwh_start_of_day
    month_so_far  = kwh_past_days + kwh_today
    month_end_est = month_so_far + (predicted_day_kwh * days_remaining)

    result = {
        "status":                    "ok",
        "timestamp":                 now.isoformat(),
        "predicted_day_total_kWh":   round(predicted_day_kwh, 4),
        "month_consumed_so_far_kWh": round(month_so_far, 4),
        "days_remaining_in_month":   days_remaining,
        "estimated_month_end_kWh":   round(month_end_est, 4),
    }

    # Also push to Firebase so mobile can display it
    firebase_db.reference("/forecast").set(result)

    return result


# ── Health Check ───────────────────────────────────────────────────────────────
@app.get("/")
def root():
    return {"status": "Energy Monitor API running"}
