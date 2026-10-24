"""
Shared fixtures for the GRID unit tests.

Run from the folder that holds main.py and the modules (e.g. ~/energy_app):
    python -m pytest tests -v

Data for the tests that need real readings (forecast checks):
    - on the VM: export GRID_DB_PASSWORD=...   (read-only SELECTs)
    - elsewhere: export GRID_TEST_CSV=readings.csv
Without either, those tests are skipped; all other tests still run.
Nothing is written to PostgreSQL, Firebase or the models folder.
"""
import os
import sys
import warnings

import joblib
import numpy as np
import pandas as pd
import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
MODEL_DIR = os.path.join(ROOT, "models")
warnings.filterwarnings("ignore")


@pytest.fixture(scope="session")
def anomaly_bundle():
    path = os.path.join(MODEL_DIR, "anomaly_model.pkl")
    if not os.path.exists(path):
        pytest.skip("models/anomaly_model.pkl not found")
    return joblib.load(path)


@pytest.fixture(scope="session")
def forecast_bundle():
    import forecast_retrain as fr
    if not os.path.exists(os.path.join(MODEL_DIR, "forecast_model.pkl")):
        pytest.skip("models/forecast_model.pkl not found")
    return fr.load_bundle(MODEL_DIR)


@pytest.fixture(scope="session")
def readings():
    """All readings since the first training day (same query /forecast uses)."""
    import forecast_retrain as fr
    csv = os.environ.get("GRID_TEST_CSV")
    if csv:
        df = pd.read_csv(csv, parse_dates=["timestamp"])
    elif os.environ.get("GRID_DB_PASSWORD"):
        import psycopg2
        with psycopg2.connect(dbname="energy_db", user="energy_user", password=os.environ["GRID_DB_PASSWORD"],
                              host="localhost", port=5432) as conn:
            df = fr.fetch_all_readings_db(conn)
    else:
        pytest.skip("no readings: set GRID_DB_PASSWORD (VM) or GRID_TEST_CSV")
    df["timestamp"] = pd.to_datetime(df["timestamp"])
    return df.sort_values("timestamp").reset_index(drop=True)


def make_day(day, power=200.0, start=None, periods=288, minutes=5):
    """Synthetic 5-minute readings with constant power (W)."""
    ts = pd.date_range(start or pd.Timestamp(day), periods=periods, freq=f"{minutes}min")
    kwh = power * minutes / 60 / 1000
    return pd.DataFrame({"timestamp": ts, "voltage": 230.0, "current": power / 230.0, "power_avg": power,
                         "interval_kwh": kwh, "cumul_kwh": np.arange(1, periods + 1) * kwh})
