"""
Dummy Data Insertion Script
Inserts 2 days (576 rows) of realistic 5-minute averaged readings
that match the Isolation Forest training data range.

Run this on your VM:
    source ~/energy_env/bin/activate
    python insert_dummy_data.py
"""

import psycopg2
import numpy as np
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

PH_TZ = ZoneInfo("Asia/Manila")

# ── Config ─────────────────────────────────────────────────────────────────────
DB_CONFIG = {
    "dbname":   "energy_db",
    "user":     "energy_user",
    "password": "thesis1234",
    "host":     "localhost",
    "port":     5432,
}

ROWS         = 576        # 2 days × 288 rows/day
INTERVAL_MIN = 5          # 5-minute intervals
np.random.seed(42)        # reproducible

# ── Training data ranges (from your stats) ────────────────────────────────────
VOLTAGE_MEAN  = 220.0;  VOLTAGE_STD  = 2.5
CURRENT_MEAN  = 4.968;  CURRENT_STD  = 1.2
POWER_MEAN    = 1092.0; POWER_STD    = 250.0
INTERVAL_MEAN = 0.091;  INTERVAL_STD = 0.02

# ── Generate timestamps (2 days back from now) ─────────────────────────────────
now        = datetime.now(PH_TZ)
start_time = now - timedelta(minutes=INTERVAL_MIN * ROWS)
timestamps = [start_time + timedelta(minutes=INTERVAL_MIN * i) for i in range(ROWS)]

# ── Generate realistic values ──────────────────────────────────────────────────
voltages  = np.clip(np.random.normal(VOLTAGE_MEAN,  VOLTAGE_STD,  ROWS), 209.6, 233.4)
currents  = np.clip(np.random.normal(CURRENT_MEAN,  CURRENT_STD,  ROWS), 1.68,  10.6)
powers    = np.clip(np.random.normal(POWER_MEAN,    POWER_STD,    ROWS), 380.0, 2333.0)
intervals = np.clip(np.random.normal(INTERVAL_MEAN, INTERVAL_STD, ROWS), 0.032, 0.194)

# ── Cumulative kWh (incrementing) ─────────────────────────────────────────────
cumul_kwh = np.cumsum(intervals)

# ── Insert into PostgreSQL ─────────────────────────────────────────────────────
conn = psycopg2.connect(**DB_CONFIG)
cur  = conn.cursor()

print(f"Inserting {ROWS} dummy rows into energy_db.readings...")

for i in range(ROWS):
    cur.execute(
        """
        INSERT INTO readings
            (timestamp, voltage, current, power_avg, interval_kwh, cumul_kwh)
        VALUES (%s, %s, %s, %s, %s, %s)
        """,
        (
            timestamps[i],
            round(float(voltages[i]),  2),
            round(float(currents[i]),  3),
            round(float(powers[i]),    2),
            round(float(intervals[i]), 4),
            round(float(cumul_kwh[i]), 4),
        ),
    )

conn.commit()
cur.close()
conn.close()

print("✅ Done! Dummy data inserted successfully.")
print(f"   Rows inserted : {ROWS}")
print(f"   Time range    : {timestamps[0]} → {timestamps[-1]}")
print(f"   Power range   : {powers.min():.1f}W → {powers.max():.1f}W")
print(f"   Total kWh     : {cumul_kwh[-1]:.3f} kWh")
