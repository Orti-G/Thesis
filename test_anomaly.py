"""Unit tests for anomaly_retrain.py (gap repair, features, time-aware z-score, drift rule, live scoring)."""
import copy

import numpy as np
import pandas as pd
import pytest

import anomaly_retrain as ar
from conftest import make_day


# ---------------- gap repair ----------------
def _with_gap(minutes):
    a = make_day("2026-08-03", periods=12)
    b = make_day("2026-08-03", periods=12, start=a.timestamp.iloc[-1] + pd.Timedelta(minutes=minutes))
    b.loc[0, "interval_kwh"] = 0.2                  # energy of the whole gap reported in one reading
    return pd.concat([a, b], ignore_index=True)


def test_gap_30min_is_split_into_5min_slots():
    raw = _with_gap(30)
    out = ar.repair_gaps(raw)
    assert len(out) == len(raw) + 5                 # 30 min = 6 slots: 5 added + the real reading
    assert int(out.is_synthetic.sum()) == 5


def test_gap_repair_conserves_energy():
    raw = _with_gap(30)
    out = ar.repair_gaps(raw)
    assert out.interval_kwh.sum() == pytest.approx(raw.interval_kwh.sum(), abs=1e-9)


def test_gap_over_60min_is_left_unfilled():
    raw = _with_gap(90)
    assert len(ar.repair_gaps(raw)) == len(raw)


def test_normal_interval_is_not_treated_as_gap():
    raw = _with_gap(7)                              # 7 min <= 7.5 min (1.5 x 5 min)
    assert len(ar.repair_gaps(raw)) == len(raw)


# ---------------- features ----------------
def test_constant_power_gives_zero_deviation():
    f = ar.add_features(make_day("2026-08-03", power=300.0))
    assert np.allclose(f["Roll mean 1hr"], 300.0) and np.allclose(f["Roll mean 24hr"], 300.0)
    assert np.allclose(f["Dev 1hr"], 0.0) and np.allclose(f["Dev 24hr"], 0.0)
    assert np.allclose(f["Power Delta"], 0.0)


def test_power_delta_is_zero_after_long_gap():
    a = make_day("2026-08-03", power=100.0, periods=12)
    b = make_day("2026-08-03", power=900.0, periods=12, start=a.timestamp.iloc[-1] + pd.Timedelta(minutes=90))
    f = ar.add_features(pd.concat([a, b], ignore_index=True))
    assert f["Power Delta"].iloc[12] == 0.0          # first reading after a >60 min outage
    assert f["Power Delta"].iloc[1] == 0.0


def test_hour_encoding_and_weekend_flag():
    f = ar.add_features(make_day("2026-08-01"))      # Saturday
    assert f.hour_sin.iloc[0] == pytest.approx(0.0) and f.hour_cos.iloc[0] == pytest.approx(1.0)
    assert set(f.is_weekend) == {1}
    assert set(ar.add_features(make_day("2026-08-03")).is_weekend) == {0}   # Monday


# ---------------- time-aware baseline and z-score ----------------
def test_threshold_is_3_sigma():
    assert ar.Z_THR == 3.0


def test_baseline_mean_std_and_zscore_by_hand():
    d = make_day("2026-08-03", power=100.0)
    d.loc[d.timestamp.dt.hour == 10, "power_avg"] = [100, 200] * 6          # hour 10: mean 150, std 52.22
    base, floor = ar.fit_baseline(d)
    mu, sd = base[(10, 0)]
    assert mu == pytest.approx(150.0)
    assert sd == pytest.approx(pd.Series([100, 200] * 6).std())
    test = d[d.timestamp.dt.hour == 10].head(1).copy()
    test["power_avg"] = mu + 3 * sd
    assert ar.zscore(test, base)[0] == pytest.approx(3.0)


def test_std_floor_applies_to_quiet_hours():
    d = make_day("2026-08-03", power=100.0)
    d.loc[d.timestamp.dt.hour == 18, "power_avg"] = 1000.0                   # global std > 0
    base, floor = ar.fit_baseline(d)
    assert floor == pytest.approx(d.power_avg.std() * 0.1)
    assert base[(3, 0)][1] == pytest.approx(floor)   # constant hour -> std 0 -> floored
    assert len(base) == 48


# ---------------- drift rule (14-day mean outside +/-15%) ----------------
def _daily(level, days=14, end="2026-10-14"):
    return pd.concat([make_day(d, power=level / 24 * 1000) for d in pd.date_range(end=end, periods=days)],
                     ignore_index=True)


def _bundle_for_drift(anomaly_bundle, level=7.0):
    b = copy.copy(anomaly_bundle)
    b["drift"] = {"train_mean_daily_kwh": level, "band": 0.15, "window_days": 14, "last_refit": "2026-09-01"}
    return b


def test_no_drift_at_training_level(anomaly_bundle):
    r = ar.check_drift(_daily(7.0), _bundle_for_drift(anomaly_bundle))
    assert r["drift"] is False and r["reason"] == "inside band"


def test_drift_when_14day_mean_is_30pct_higher(anomaly_bundle):
    r = ar.check_drift(_daily(9.1), _bundle_for_drift(anomaly_bundle))
    assert r["drift"] is True and r["deviation_pct"] == pytest.approx(30.0)


def test_no_drift_inside_band(anomaly_bundle):
    assert ar.check_drift(_daily(7.7), _bundle_for_drift(anomaly_bundle))["drift"] is False    # +10%


def test_drift_needs_10_full_days(anomaly_bundle):
    r = ar.check_drift(_daily(9.1, days=5), _bundle_for_drift(anomaly_bundle))
    assert r["drift"] is False and r["reason"].startswith("only")


def test_partial_day_not_counted():
    d = pd.concat([make_day("2026-10-01"), make_day("2026-10-02", periods=269)], ignore_index=True)
    assert len(ar.daily_full_totals(d)) == 1         # 269 readings < 270 -> not a full day


# ---------------- deployed model ----------------
def test_deployed_bundle_is_valid(anomaly_bundle):
    assert ar.validate_bundle(anomaly_bundle)
    assert len(anomaly_bundle["features"]) == 12 and "Voltage (V)" not in anomaly_bundle["features"]


def test_incomplete_bundle_is_rejected(anomaly_bundle):
    b = {k: v for k, v in anomaly_bundle.items() if k != "scaler"}
    with pytest.raises(ValueError):
        ar.validate_bundle(b)


def _history_at_hourly_mean(bundle, end="2026-10-14 20:00"):
    ts = pd.date_range(end=end, periods=300, freq="5min")
    p = [bundle["time_baseline"][(t.hour, int(t.dayofweek >= 5))][0] for t in ts]
    return pd.DataFrame({"timestamp": ts, "voltage": 230.0, "current": np.array(p) / 230.0, "power_avg": p,
                         "interval_kwh": np.array(p) * 5 / 60 / 1000})


def test_score_latest_returns_expected_fields(anomaly_bundle):
    r = ar.score_latest(_history_at_hourly_mean(anomaly_bundle), anomaly_bundle)
    for k in ("status", "is_anomaly", "score", "time_zscore", "dev_1hr", "dev_24hr", "power_delta", "model_version"):
        assert k in r
    assert isinstance(r["is_anomaly"], bool)


def test_reading_at_its_hourly_mean_is_not_flagged(anomaly_bundle):
    r = ar.score_latest(_history_at_hourly_mean(anomaly_bundle), anomaly_bundle)
    assert abs(r["time_zscore"]) < 1e-6
    assert r["is_anomaly"] is False


def test_large_spike_is_flagged(anomaly_bundle):
    rows = _history_at_hourly_mean(anomaly_bundle)
    rows.loc[rows.index[-1], ["power_avg", "current", "interval_kwh"]] = [6000.0, 26.0, 0.5]
    r = ar.score_latest(rows, anomaly_bundle)
    assert r["time_zscore"] >= 3.0
    assert r["is_anomaly"] is True
