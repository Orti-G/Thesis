"""Unit tests for the HITL retraining trigger (hitl_trigger.py, the rule from HITL_Retraining_Check.ipynb).
The inputs are constructed events, so these tests check the RULE, independent of any owner labels."""
import numpy as np
import pandas as pd
import pytest

import hitl_trigger as ht


def events(rows, label="normal"):
    """rows: list of (timestamp string, peak W). Returns an event table as group_events() makes it."""
    _, ev = ht.group_events(pd.DataFrame({"timestamp": [r[0] for r in rows], "power_avg": [r[1] for r in rows]}))
    ev["owner_label"] = label
    return ev


# ---------------- event grouping (one prompt per event) ----------------
def test_readings_10_min_apart_are_one_event():
    _, ev = ht.group_events(pd.DataFrame({"timestamp": ["2026-08-31 20:26", "2026-08-31 20:31", "2026-08-31 20:41"],
                                          "power_avg": [1500, 2000, 1800]}))
    assert len(ev) == 1 and ev.n_readings.iloc[0] == 3 and ev.peak_w.iloc[0] == 2000


def test_readings_more_than_10_min_apart_are_separate_events():
    _, ev = ht.group_events(pd.DataFrame({"timestamp": ["2026-08-31 20:26", "2026-08-31 20:37"],
                                          "power_avg": [1500, 2000]}))
    assert len(ev) == 2


# ---------------- pattern distance (the two tolerances) ----------------
def _d(a, b):
    return ht.pattern_distance(events([a, b]))[0, 1]


def test_30_min_apart_is_on_the_tolerance():
    assert _d(("2026-08-01 07:00", 900), ("2026-08-02 07:30", 900)) == pytest.approx(1.0)


def test_31_min_apart_is_outside():
    assert _d(("2026-08-01 07:00", 900), ("2026-08-02 07:31", 900)) > 1.0


def test_power_factor_1_25_is_on_the_tolerance():
    assert _d(("2026-08-01 07:00", 800), ("2026-08-02 07:00", 1000)) == pytest.approx(1.0)


def test_power_factor_1_3_is_outside():
    assert _d(("2026-08-01 07:00", 800), ("2026-08-02 07:00", 1040)) > 1.0


def test_time_of_day_wraps_around_midnight():
    assert _d(("2026-08-01 23:50", 900), ("2026-08-02 00:10", 900)) == pytest.approx(20 / 30)


# ---------------- retraining decision ----------------
def test_recurring_morning_pattern_triggers():
    rows = [(f"2026-08-{d:02d} 07:{m:02d}", w) for d, m, w in
            [(11, 5, 900), (12, 10, 950), (13, 0, 880), (14, 15, 1000), (15, 20, 920), (16, 5, 970), (17, 12, 910)]]
    _, cl, trigger = ht.retrain_check(events(rows))
    assert trigger and len(cl) == 1 and cl.events.iloc[0] == 7


def test_scattered_evening_events_do_not_trigger():
    # start time and peak power of the ten August evening events (Table 47)
    rows = [("2026-08-01 21:40", 1081), ("2026-08-02 21:43", 2081), ("2026-08-12 20:25", 998),
            ("2026-08-14 21:12", 1024), ("2026-08-15 21:30", 1747), ("2026-08-15 22:41", 1184),
            ("2026-08-22 22:33", 1002), ("2026-08-24 22:39", 1068), ("2026-08-26 20:06", 1099),
            ("2026-08-31 20:26", 2019)]
    fp, cl, trigger = ht.retrain_check(events(rows))
    assert not trigger and (fp.cluster == -1).all()


def test_same_pattern_on_only_4_days_does_not_trigger():
    rows = [("2026-08-11 07:00", 900), ("2026-08-11 18:00", 5000), ("2026-08-11 07:20", 910),
            ("2026-08-12 07:05", 920), ("2026-08-13 07:10", 930), ("2026-08-14 07:15", 940)]
    _, cl, trigger = ht.retrain_check(events(rows))
    assert not trigger


def test_pattern_spread_beyond_14_days_does_not_trigger():
    rows = [(f"2026-08-{d:02d} 07:00", 900) for d in (1, 6, 11, 16, 21)]       # 5 days, any 14-day window has 3
    _, cl, trigger = ht.retrain_check(events(rows))
    assert len(cl) == 1 and cl.max_days_in_window.iloc[0] < ht.MIN_DAYS and not trigger


def test_fewer_than_5_normal_events_never_trigger():
    rows = [(f"2026-08-{d:02d} 07:00", 900) for d in (11, 12, 13, 14)]
    assert ht.retrain_check(events(rows))[2] is False


@pytest.mark.parametrize("label", ["anomaly", "unsure"])
def test_only_normal_labels_count(label):
    rows = [(f"2026-08-{d:02d} 07:00", 900) for d in range(11, 19)]
    assert ht.retrain_check(events(rows, label=label))[2] is False


# ---------------- daily VM check (window, cooldown, refit wiring) ----------------
def _ev(rows, label="normal"):
    return ht.prepare_events(pd.DataFrame({"event_id": range(len(rows)), "start": [r[0] for r in rows],
                                           "peak_w": [r[1] for r in rows], "owner_label": label}))


MORNING = [(f"2026-11-{d:02d} 07:{m:02d}", w) for d, m, w in
           [(2, 5, 900), (3, 10, 950), (4, 0, 880), (5, 15, 1000), (6, 20, 920), (9, 5, 970)]]


def test_daily_check_triggers_on_recurring_pattern():
    s = ht.check_hitl(_ev(MORNING), since="2026-10-18", as_of="2026-11-10")
    assert s["trigger"] and s["normal_events"] == 6


def test_events_before_last_refit_are_ignored():
    s = ht.check_hitl(_ev(MORNING), since="2026-11-06", as_of="2026-11-10")   # refit on Nov 6
    assert not s["trigger"] and s["normal_events"] == 2                       # only Nov 6 and Nov 9 count


def test_events_older_than_14_days_are_ignored():
    s = ht.check_hitl(_ev(MORNING), since="2026-10-18", as_of="2026-11-25")   # window starts Nov 12
    assert s["events"] == 0 and not s["trigger"]


def test_db_answers_map_to_labels():
    assert ht._labels_from_db(True, False) == "anomaly"
    assert ht._labels_from_db(False, True) == "normal"
    assert ht._labels_from_db(None, None) == "unsure"


def test_run_hitl_check_refits_and_saves(monkeypatch):
    import anomaly_retrain as ar
    calls = {}
    monkeypatch.setattr(ht, "fetch_labeled_events_db", lambda conn, since: _ev(MORNING))
    monkeypatch.setattr(ar, "_last_refit", lambda b: pd.Timestamp("2026-10-18"))
    monkeypatch.setattr(ar, "fetch_readings_db", lambda conn: "readings")
    monkeypatch.setattr(ar, "fetch_confirmed_ids_db", lambda conn: [7, 8])
    monkeypatch.setattr(ar, "fetch_recent_rows_db", lambda conn: "recent")
    monkeypatch.setattr(ar, "validate_bundle", lambda b, rows=None: True)
    monkeypatch.setattr(ar, "refit", lambda r, b, confirmed_ids=(): (calls.setdefault("refit", {"ids": confirmed_ids}) and {}, {"window": ("a", "b")}))
    monkeypatch.setattr(ar, "save_incoming", lambda b, d: calls.setdefault("saved", b))
    s = ht.run_hitl_check(None, {"version": "refit-20261018"}, "models", as_of="2026-11-10")
    assert s["trigger"] and s["refit"]["reason"] == "hitl"
    assert calls["refit"]["ids"] == [7, 8]                       # confirmed anomalies still removed
    assert calls["saved"]["refit_reason"].startswith("hitl")


def test_run_hitl_check_without_pattern_does_not_refit(monkeypatch):
    import anomaly_retrain as ar
    monkeypatch.setattr(ht, "fetch_labeled_events_db", lambda conn, since: _ev(MORNING[:3]))
    monkeypatch.setattr(ar, "_last_refit", lambda b: pd.Timestamp("2026-10-18"))
    monkeypatch.setattr(ar, "refit", lambda *a, **k: pytest.fail("must not refit"))
    s = ht.run_hitl_check(None, {"version": "x"}, "models", as_of="2026-11-10")
    assert not s["trigger"] and "refit" not in s
