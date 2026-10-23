"""
rate_compare.py — month-over-month Meralco rate effect (billing side, pure).

Uses the same linear rates the dashboard prices with (/meralco_rates, pushed by
Update_Meralco_Firebase.ipynb; exact to within ₱0.01 of compute_bill), so the
peso figures match the app. The notebook also keeps every month in
/meralco_rates_history/{YYYY-MM}, so no PDF is needed on the VM.

    bill(kWh) = rate[bracket(kWh)] × kWh + fixed_charge
    effect    = bill_this_month(kWh) − bill_last_month(kWh)   (same kWh)
"""

import re
from typing import Optional, Tuple

import advisory_rules as nlg   # bracket rule (whole kWh) shared with the alerts

_FILE_RE = re.compile(r"(\d{2})-(\d{4})")


def period_of(rates: Optional[dict]) -> Optional[str]:
    """'2026-10' from rates['period'], else from source_file '10-2026_rate_schedule.pdf'."""
    if not rates:
        return None
    if rates.get("period"):
        return str(rates["period"])
    m = _FILE_RE.search(str(rates.get("source_file", "")))
    return f"{m.group(2)}-{m.group(1)}" if m else None


def _ym(period: str) -> Tuple[int, int]:
    y, m = period.split("-")
    return int(y), int(m)


def previous_period(period: str) -> str:
    y, m = _ym(period)
    y, m = (y - 1, 12) if m == 1 else (y, m - 1)
    return f"{y}-{m:02d}"


def linear_bill(rates: dict, kwh: float) -> float:
    bracket = nlg.bracket_label(kwh)
    return float(rates["brackets"][bracket]) * kwh + float(rates["fixed_charge"])


def compare_with_previous(current: dict, history: dict, billed_kwh: float,
                          basis: str = "so_far") -> Optional[dict]:
    """Effect of this month's rates on the household's billed kWh.
    basis: "so_far" (billed kWh this cycle) or "projected" (calibrated EOM).
    Returns None if last month's rates are missing (a gap would mix two
    months of changes) or there is no consumption yet."""
    cur_p = period_of(current)
    if not cur_p or not history or billed_kwh is None or billed_kwh < 1:
        return None
    prev_p = previous_period(cur_p)
    prev = history.get(prev_p)
    if not prev:
        return None

    kwh = round(float(billed_kwh), 2)
    bracket = nlg.bracket_label(kwh)
    # Round the totals first so the stated difference always equals what the
    # reader gets by subtracting the two displayed amounts.
    prev_total = round(linear_bill(prev, kwh), 2)
    cur_total = round(linear_bill(current, kwh), 2)
    return {
        "kwh":         kwh,
        "basis":       basis,
        "bracket":     bracket,
        "prev_period": _ym(prev_p),
        "cur_period":  _ym(cur_p),
        "prev_rate":   float(prev["brackets"][bracket]),
        "cur_rate":    float(current["brackets"][bracket]),
        "prev_total":  prev_total,
        "cur_total":   cur_total,
        "diff_total":  round(cur_total - prev_total, 2),
    }
