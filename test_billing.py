"""Unit tests for meralco_engine.py, with expected values from the household's actual Meralco bills
(Chapter IV, Table 42) and the published rate schedules in meralco_rates/."""
import os

import pytest

me = pytest.importorskip("meralco_engine")

JULY, AUGUST, OCTOBER = "07-2026_rate_schedule.pdf", "08-2026_rate_schedule.pdf", "10-2026_rate_schedule.pdf"
# linear rates pushed to Firebase /meralco_rates for October 2026 (Update_Meralco_Firebase.ipynb)
OCT_LINEAR = {"fixed_charge": 24.0525,
              "brackets": {"0-200": 14.9424, "201-300": 15.2917, "301-400": 15.6212, "over-400": 16.1954}}


def total(bill):
    for key in ("total_energy_amount", "total_bill", "total", "total_amount"):
        if isinstance(bill.get(key), (int, float)):
            return float(bill[key])
    raise KeyError(f"no total in compute_bill() result: {list(bill)}")


def any_schedule():
    for pdf in (AUGUST, JULY, OCTOBER):
        if os.path.exists(os.path.join(me.RATE_SCHEDULE_DIR, pdf)):
            return pdf
    pytest.skip("no rate schedule PDF found")


def need(pdf):
    if not os.path.exists(os.path.join(me.RATE_SCHEDULE_DIR, pdf)):
        pytest.skip(f"{pdf} not in {me.RATE_SCHEDULE_DIR}")
    return pdf


# Actual bill, 28 Jun - 27 Jul 2026, 259 kWh (each line as printed on the bill)
JULY_BILL = {"generation": 2395.85, "transmission": 331.16, "system_loss": 226.65, "distribution": 460.03,
             "senior_citizen": 0.03, "universal_charges": 83.31, "fit_all": 52.08, "lifeline": 2.59,
             "rpt": 1.68, "lft": 17.08, "vat": 352.91, "non_vat": 156.74, "total_energy_amount": 3923.37}


def test_july_bill_259_kwh_every_line():
    # The July bill has no "LFT Adj" line (it appears from August); the engine leaves it out by default.
    bill = me.compute_bill(need(JULY), 259)
    for key, amount in JULY_BILL.items():
        assert bill[key] == pytest.approx(amount, abs=0.005), key
    assert bill["distribution_breakdown"]["awat_1"] == pytest.approx(-110.80, abs=0.005)   # single AWAT column in July
    assert bill["lft_breakdown"]["base"] == pytest.approx(3415.40, abs=0.005)


def test_july_with_lft_adj_explains_23_centavos():
    # With the Aug-onward LFT Adj (0.0009/kWh x 259 kWh = 0.23) the engine gives 3,923.60 (paper, Table 42).
    assert total(me.compute_bill(need(JULY), 259, lft_adj_perkwh=0.0009)) == pytest.approx(3923.60, abs=0.005)


@pytest.mark.parametrize("pdf,expected", [("07-2026_rate_schedule.pdf", 0.0), ("08-2026_rate_schedule.pdf", 0.0009),
                                          ("10-2026_rate_schedule.pdf", 0.0009), ("01-2027_rate_schedule.pdf", 0.0009)])
def test_lft_adj_follows_schedule_month(pdf, expected):
    assert me.default_lft_adj(pdf) == expected


def test_august_bill_219_kwh():
    assert total(me.compute_bill(need(AUGUST), 219)) == pytest.approx(3312.01, abs=0.01)


def test_tier_jump_at_200_kwh_boundary():
    # Consumption is rounded to whole kWh before pricing (main.py). Under the August schedule
    # 200 kWh is billed at 2,956.87 and 201 kWh at 3,041.76: +84.89 for one kWh, because the
    # higher tier's rates apply to the whole month.
    pdf = need(AUGUST)
    low, high = me.compute_bill(pdf, 200), me.compute_bill(pdf, 201)
    assert low["tier"] != high["tier"]
    assert total(low) == pytest.approx(2956.87, abs=0.01)
    assert total(high) == pytest.approx(3041.76, abs=0.01)
    assert total(high) - total(low) == pytest.approx(84.89, abs=0.02)


def test_bill_increases_with_consumption():
    pdf = any_schedule()
    totals = [total(me.compute_bill(pdf, k)) for k in (50, 150, 250, 350, 450)]
    assert totals == sorted(totals)


@pytest.mark.parametrize("kwh,bracket", [(150, "0-200"), (250, "201-300"), (350, "301-400"), (450, "over-400")])
def test_linear_firebase_rates_match_engine(kwh, bracket):
    expected = kwh * OCT_LINEAR["brackets"][bracket] + OCT_LINEAR["fixed_charge"]
    assert total(me.compute_bill(need(OCTOBER), kwh)) == pytest.approx(expected, abs=0.05)


def test_peso_to_kwh_is_inverse_of_compute_bill():
    pdf = any_schedule()
    assert me.peso_to_kwh(pdf, total(me.compute_bill(pdf, 250))) == pytest.approx(250, abs=0.05)
