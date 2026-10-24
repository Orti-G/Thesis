"""Unit tests for forecast_retrain.py (EWMA, brackets, anomaly scaling, end-of-month formula, cached frame)."""
import pandas as pd
import pytest

import forecast_retrain as fr


def test_ewma_weight_for_3day_half_life():
    assert fr.EWMA_HALFLIFE == 3
    assert 1 - 0.5 ** (1 / fr.EWMA_HALFLIFE) == pytest.approx(0.206, abs=5e-4)


@pytest.mark.parametrize("kwh,expected", [(0, "0-200"), (200, "0-200"), (200.01, "201-300"), (300, "201-300"),
                                          (300.01, "301-400"), (400, "301-400"), (400.01, "over-400")])
def test_bracket_edges(kwh, expected):
    assert fr.bracket_of(kwh) == expected


def test_anomaly_scale_ratio_and_fallbacks():
    idx = [pd.Timestamp("2026-10-0%d" % d).date() for d in range(1, 6)]
    daily = pd.DataFrame({"anom": [0.2, 0.2, 0.2, 0.2, 0.2]}, index=idx)
    today = pd.Timestamp("2026-10-06").date()
    assert fr.anomaly_scale(daily, today, base=0.4) == pytest.approx(0.5)
    assert fr.anomaly_scale(daily, idx[2], base=0.4) == 1.0      # fewer than 3 earlier days
    assert fr.anomaly_scale(daily, today, base=0.0) == 1.0       # no base


def test_forecast_bundle_is_valid(forecast_bundle):
    assert fr.validate_bundle(forecast_bundle) is not False
    assert list(forecast_bundle["ln_columns"]) == list(fr.LN_DEF)
    assert forecast_bundle["eom"]["k_pooled"] == pytest.approx(1.097, abs=5e-4)


def _last_full_day(readings):
    n = readings.groupby(readings.timestamp.dt.date).size()
    return [d for d in n.index if n[d] >= fr.FULL_DAY_ROWS][-2]


def _cycle_end(day):
    return day.replace(day=27) if day.day <= 27 else (pd.Timestamp(day.replace(day=1)) + pd.Timedelta(days=32)).date().replace(day=27)


@pytest.fixture(scope="module")
def checkpoint(readings, anomaly_bundle, forecast_bundle):
    day = _last_full_day(readings)
    now = pd.Timestamp(f"{day} 15:00")
    upto = readings[readings.timestamp <= now]
    F = fr.build_frame(upto, anomaly_bundle, forecast_bundle, today=day)
    f = fr.forecast_now(F, forecast_bundle, float(upto.cumul_kwh.iloc[-1]), now.to_pydatetime(), _cycle_end(day))
    return day, now, upto, F, f


def test_end_of_month_formula(checkpoint):
    _, _, _, _, f = checkpoint
    expected = f["accumulated_past_kWh"] + f["predicted_day_total_kWh"] + f["days_remaining"] * f["ewma_daily_kWh"]
    assert f["projected_eom_kWh"] == pytest.approx(expected, abs=2e-3)
    assert f["projected_eom_calibrated_kWh"] == pytest.approx(f["projected_eom_kWh"] * f["calibration_k"], abs=2e-3)
    assert f["bracket"] == fr.bracket_of(f["projected_eom_calibrated_kWh"])


def test_day_total_is_clean_plus_anomalous(checkpoint):
    _, _, _, _, f = checkpoint
    parts = f["predicted_clean_kWh"] + f["anomalous_so_far_kWh"] + f["expected_rest_anomalous_kWh"]
    assert f["predicted_day_total_kWh"] == pytest.approx(parts, abs=2e-3)


def test_predicted_clean_total_not_below_energy_so_far(checkpoint, forecast_bundle):
    day, _, _, F, _ = checkpoint
    rows = F["df"][F["df"].date == day]
    pred = fr.predict_clean_total(forecast_bundle, rows)
    assert (pred >= rows.today_kwh_so_far.to_numpy() - 1e-9).all()


@pytest.mark.parametrize("hhmm", ["06:30", "12:00", "21:00"])
def test_cached_frame_gives_same_forecast(readings, anomaly_bundle, forecast_bundle, hhmm):
    day = _last_full_day(readings)
    d0, now = pd.Timestamp(day), pd.Timestamp(f"{day} {hhmm}")
    upto = readings[readings.timestamp <= now]
    hist = fr.build_history(readings[readings.timestamp < d0 + pd.Timedelta(minutes=20)], anomaly_bundle,
                            forecast_bundle, day)
    win = upto[upto.timestamp >= d0 - pd.Timedelta(hours=fr.WINDOW_HOURS_BEFORE_TODAY)]
    kwh, end = float(upto.cumul_kwh.iloc[-1]), _cycle_end(day)
    a = fr.forecast_now(fr.build_frame(upto, anomaly_bundle, forecast_bundle, today=day), forecast_bundle, kwh,
                        now.to_pydatetime(), end)
    b = fr.forecast_now(fr.build_today(win, anomaly_bundle, forecast_bundle, hist), forecast_bundle, kwh,
                        now.to_pydatetime(), end)
    for k in ("predicted_day_total_kWh", "projected_eom_kWh", "projected_eom_calibrated_kWh"):
        assert b[k] == pytest.approx(a[k], abs=1e-6)
    assert a["bracket"] == b["bracket"]
