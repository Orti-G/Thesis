"""
meralco_engine.py — VM-safe Meralco rate schedule parser
------------------------------------------------
Lives at energy_app/meralco_engine.py, alongside energy_app/meralco_rates/
(where monthly PDFs are stored) and energy_app/main.py (FastAPI entry point).
Called on-demand when a user requests a full itemized bill breakdown —
NOT part of the VM's 2-second update loop (that loop uses cached
rate_per_kwh + fixed_charge values from Firebase instead — see the
bracket-simulation notebook, run locally once a month, not on the VM).
Parses a Meralco monthly "Summary Schedule of Rates" PDF and computes a
residential customer's kWh -> peso energy bill, matching Meralco's own
billing math (verified against real July and August 2026 bills;
the July bill is reproduced line by line, see default_lft_adj()).

Pure functions only — nothing runs at import time, so this is safe to
`import` from a FastAPI backend on a VM. Column positions and tier
boundaries are resolved by TEXT LABEL, not fixed index/row number,
verified against schedules with different column orders and different
tier counts (Feb / Jul / Aug 2026).

Usage:
    from meralco_rate_parser import compute_bill

    # Bare filename -> resolved against the meralco_rates/ folder:
    result = compute_bill("08-2026_rate_schedule.pdf", kwh=219)

    # Or pass a full/relative path directly — used as-is if it exists:
    result = compute_bill("/some/other/path/08-2026_rate_schedule.pdf", kwh=219)
"""

import os
import re
import pdfplumber


# Folder where monthly rate schedule PDFs live: energy_app/meralco_rates/
# Anchored to this file's own location (not the process's working
# directory), so it resolves correctly however main.py/systemd launches
# the app. Override via MERALCO_RATES_DIR env var if the PDFs ever move.
_DEFAULT_RATE_SCHEDULE_DIR = os.path.join(os.path.dirname(__file__), "meralco_rates")
RATE_SCHEDULE_DIR = os.environ.get("MERALCO_RATES_DIR", _DEFAULT_RATE_SCHEDULE_DIR)


def resolve_pdf_path(pdf_path):
    """Bare filename -> look inside RATE_SCHEDULE_DIR. Existing/absolute
    paths are returned unchanged."""
    if os.path.exists(pdf_path):
        return pdf_path
    candidate = os.path.join(RATE_SCHEDULE_DIR, pdf_path)
    if os.path.exists(candidate):
        return candidate
    raise FileNotFoundError(
        f"Could not find '{pdf_path}' directly or inside '{RATE_SCHEDULE_DIR}/'. "
        f"Checked: '{pdf_path}' and '{candidate}'."
    )


# ---------------------------------------------------------------------------
# Header normalization + label-based column resolution
# ---------------------------------------------------------------------------

def normalize(s):
    if not s:
        return ""
    s = s.replace("\n", " ").lower()
    s = re.sub(r'\d+$', '', s.strip())   # strip trailing footnote digits
    s = re.sub(r'\s+', ' ', s).strip()
    return s


def build_header_map(table):
    """Forward-fill row0 across its span, combine with row1 sub-label and
    row2 unit, per column index. Returns index -> normalized header text."""
    row0, row1, row2 = table[0], table[1], table[2]
    ncols = max(len(row0), len(row1), len(row2))

    filled_row0 = []
    last = ""
    for i in range(ncols):
        val = row0[i] if i < len(row0) else None
        if val:
            last = val
        filled_row0.append(last)

    combined = []
    for i in range(ncols):
        parts = [filled_row0[i]]
        if i < len(row1) and row1[i]:
            parts.append(row1[i])
        if i < len(row2) and row2[i]:
            parts.append(row2[i])
        combined.append(normalize(" ".join(p for p in parts if p)))
    return combined


# Fields that must resolve to exactly one column, or parsing stops —
# these are the ones every schedule (Feb/Jul/Aug 2026 confirmed) has had.
FIELD_RULES_REQUIRED = {
    "generation":      ["generation charge", "per kwh"],
    "transmission":    ["transmission charge", "per kwh"],
    "system_loss":     ["system loss charge"],
    "distribution":    ["distribution charge", "per kwh"],
    "supply_perkwh":   ["supply charge", "per kwh"],
    "supply_fixed":    ["supply charge", "per cust/mo"],
    "metering_perkwh": ["metering charge", "per kwh"],
    "metering_fixed":  ["metering charge", "per cust/mo"],
    "reg_reset":       ["regulatory reset"],
    "senior_citizen":  ["senior citizen subsidy"],
    "rpt":             ["rpt charge"],
    "uc_spug":         ["npc-spug"],
    "uc_redci":        ["red-ci"],
    "uc_env":          ["uc-ec"],
    "uc_npc_debt":     ["uc-sd"],
    "fit_all":         ["fit-all"],
    "lifeline_rate":   ["non-lifeline: lifeline subsidy"],
}

# Fields that may be absent (older schedules) or ambiguous (e.g. plain
# "awat" matching both Aug-2026-onward AWAT columns) — left unused rather
# than raising an error when that happens.
FIELD_RULES_OPTIONAL = {
    "gea_all":            ["gea-all"],
    "awat":               ["awat"],
    "awat_1":             ["awat", "collect 1"],
    "awat_2":             ["awat", "collect 2"],
    "ancillary_service":  ["ancillary service charge", "per kwh"],
    "lifeline_rate_adj":  ["lifeline rate adjustment"],
    "rpt_adj":            ["rpt adj"],
}


def resolve_field_columns(combined_headers, rules):
    resolved = {}
    for field, needles in rules.items():
        matches = [i for i, h in enumerate(combined_headers)
                   if all(n in h for n in needles)]
        resolved[field] = matches
    return resolved


# ---------------------------------------------------------------------------
# Residential section + tier lookup (by name/range text, not row number)
# ---------------------------------------------------------------------------

def find_residential_rows(table):
    start = end = None
    for i, row in enumerate(table):
        label = (row[0] or "").replace("\n", " ").strip()
        if label == "Residential":
            start = i + 1
        elif start is not None and label == "General Service A":
            end = i
            break
    if start is None or end is None:
        raise ValueError("Could not locate Residential section boundaries")
    return start, end


def parse_tier_bounds(tier_label):
    """Turn '0 TO 50 KWH' / 'OVER 400 KWH' into a (low, high) range."""
    s = tier_label.upper().replace("KWH", "").strip()
    if s.startswith("OVER"):
        low = float(s.replace("OVER", "").strip())
        return (low, float("inf"))
    parts = s.split("TO")
    return (float(parts[0].strip()), float(parts[1].strip()))


def find_tier_row(table, kwh):
    s, e = find_residential_rows(table)

    # Round the kWh to the nearest whole number to match the integer tiers
    rounded_kwh = round(kwh)

    for i in range(s, e):
        low, high = parse_tier_bounds(table[i][0])
        if low <= rounded_kwh <= high:
            return table[i]
    raise ValueError(f"No tier found for {kwh} kWh")


# ---------------------------------------------------------------------------
# Value cleaning + VAT rate lookup
# ---------------------------------------------------------------------------

def clean(v):
    """'(0.4278)' -> -0.4278, '' -> 0.0, '10.05%' -> 10.05, '1,234' -> 1234"""
    if v is None or v.strip() == "":
        return 0.0
    v = v.strip()
    neg = v.startswith("(") and v.endswith(")")
    v = v.strip("()").replace(",", "").replace("%", "")
    val = float(v)
    return -val if neg else val


def get_vat_rates(table):
    rates = {}
    labels = ("Generation", "Transmission", "Ancillary Service", "System Loss", "Other Charges")
    exempt_text = ""
    for row in table:
        label = (row[0] or "").strip()
        if label in labels and row[1]:
            rates[label] = clean(row[1])
        if len(row) > 1 and row[1] and "not subject to" in row[1].lower():
            exempt_text = " ".join((row[0] or "").lower().split())

    if "System Loss" not in rates and "system loss" in exempt_text:
        rates["System Loss"] = 0.0
        rates["_system_loss_exempt"] = 1.0
    return rates


# ---------------------------------------------------------------------------
# Column resolution for one loaded table (used internally by compute_bill,
# also usable standalone for debugging a schedule that fails to parse)
# ---------------------------------------------------------------------------

def resolve_columns(table):
    """Returns (cols, problems). cols maps field -> column index for every
    required field that resolved cleanly, plus any optional field that
    resolved unambiguously. problems lists required fields that didn't
    resolve to exactly one column (missing or ambiguous)."""
    headers = build_header_map(table)
    resolved_required = resolve_field_columns(headers, FIELD_RULES_REQUIRED)
    resolved_optional = resolve_field_columns(headers, FIELD_RULES_OPTIONAL)

    problems = [f for f, c in resolved_required.items() if len(c) != 1]
    cols = {f: c[0] for f, c in resolved_required.items() if len(c) == 1}
    for f, c in resolved_optional.items():
        if len(c) == 1:
            cols[f] = c[0]

    return cols, problems


def load_table(pdf_path):
    """Resolve the path, open the PDF, extract the first table.
    Uncached -- prefer get_parsed_schedule() for repeated use (e.g. serving
    requests), since this alone is the expensive ~700ms step."""
    path = resolve_pdf_path(pdf_path)
    with pdfplumber.open(path) as pdf:
        return pdf.pages[0].extract_tables()[0]


# In-memory cache: resolved path -> (mtime, table, cols, vat). Keyed by
# mtime so replacing a PDF (e.g. dropping in next month's schedule) is
# picked up automatically on the next call -- no restart needed -- while
# repeated calls against an unchanged file skip the ~700ms parse entirely.
_schedule_cache = {}


def get_parsed_schedule(pdf_path):
    """Cached (table, cols, vat) for a given PDF. First call for a given
    file pays the full parse cost (~700ms); subsequent calls, with any
    kwh value, return in well under 1ms as long as the file on disk
    hasn't changed since. Raises ValueError immediately if a required
    column fails to resolve, same as compute_bill() used to."""
    path = resolve_pdf_path(pdf_path)
    mtime = os.path.getmtime(path)

    cached = _schedule_cache.get(path)
    if cached and cached[0] == mtime:
        return cached[1], cached[2], cached[3]

    with pdfplumber.open(path) as pdf:
        table = pdf.pages[0].extract_tables()[0]
    cols, problems = resolve_columns(table)
    if problems:
        raise ValueError(f"Column resolution failed for required fields: {problems}")
    vat = get_vat_rates(table)

    _schedule_cache[path] = (mtime, table, cols, vat)
    return table, cols, vat


# ---------------------------------------------------------------------------
# LFT Adj: printed only on bills from August 2026 onward
# ---------------------------------------------------------------------------

LFT_ADJ_PERKWH = 0.0009          # San Pablo City, from the Aug-2026 bill
LFT_ADJ_FROM = (2026, 8)          # (year, month) of the first schedule that has it


def schedule_year_month(pdf_path):
    """'07-2026_rate_schedule.pdf' -> (2026, 7). None if the name has no MM-YYYY prefix."""
    m = re.match(r"(\d{2})-(\d{4})", os.path.basename(pdf_path))
    return (int(m.group(2)), int(m.group(1))) if m else None


def default_lft_adj(pdf_path):
    """0 for schedules before August 2026 (e.g. the July bill has no LFT Adj line),
    LFT_ADJ_PERKWH from August 2026 on. Unknown file names keep the current value."""
    ym = schedule_year_month(pdf_path)
    return 0.0 if ym is not None and ym < LFT_ADJ_FROM else LFT_ADJ_PERKWH


# ---------------------------------------------------------------------------
# Full pipeline: PDF + kWh -> peso breakdown
# ---------------------------------------------------------------------------

def compute_bill(pdf_path, kwh, lft_pct=0.5, lft_adj_perkwh=None):
    """
    pdf_path: bare filename (resolved against RATE_SCHEDULE_DIR /
        meralco_rates/) or a full/existing path.

    lft_pct: Local Franchise Tax %, applied to (energy charges + RPT).
        Neither PDF prints this as a clean number (footnote says "Varies
        per LGU"); 0.5% was reverse-engineered from a San Pablo City bill.
        Override for other LGUs.

    lft_adj_perkwh: "LFT Adj" line seen on Aug-2026-onward bills. Not
        published anywhere in the rate schedule PDF's table — only visible
        on the actual bill — so it can't be auto-parsed. None (default) =
        0.0009 for schedules from August 2026 (San Pablo City verification
        bill) and 0 for earlier ones, which matches the July 2026 bill
        exactly. Pass a number to override.

    Raises ValueError if any required field fails to resolve to exactly
    one column (e.g. Meralco reorders/renames a column this parser
    doesn't recognize yet) — fails loudly rather than silently using the
    wrong number.

    Parsing is cached per PDF file (see get_parsed_schedule) — the first
    call for a given month's schedule pays the ~700ms parse cost; every
    call after that, for any kwh, is a cache hit and takes well under 1ms.
    The cache auto-invalidates if the file's contents change.
    """
    if lft_adj_perkwh is None:
        lft_adj_perkwh = default_lft_adj(pdf_path)
    table, cols, vat = get_parsed_schedule(pdf_path)

    row = find_tier_row(table, kwh)

    v = lambda field: clean(row[cols[field]]) if field in cols else 0.0

    gen_amt = round(kwh * v("generation"), 2)
    trans_amt = round(kwh * v("transmission"), 2)
    ancillary_amt = round(kwh * v("ancillary_service"), 2)
    sysloss_amt = round(kwh * v("system_loss"), 2)
    dist_charge = round(kwh * v("distribution"), 2)
    metering_fixed_amt = round(1 * v("metering_fixed"), 2)
    metering_perkwh_amt = round(kwh * v("metering_perkwh"), 2)
    metering_amt = round(metering_fixed_amt + metering_perkwh_amt, 2)
    supply_fixed_amt = round(1 * v("supply_fixed"), 2)
    supply_perkwh_amt = round(kwh * v("supply_perkwh"), 2)
    supply_amt = round(supply_fixed_amt + supply_perkwh_amt, 2)
 
    if "awat_1" in cols or "awat_2" in cols:
        awat_1_amt = round(kwh * v("awat_1"), 2)
        awat_2_amt = round(kwh * v("awat_2"), 2)
        awat_amt = round(awat_1_amt + awat_2_amt, 2)
    else:
        awat_1_amt = round(kwh * v("awat"), 2)
        awat_2_amt = 0.0
        awat_amt = awat_1_amt
 
    reg_reset_amt = round(kwh * v("reg_reset"), 2)
    distribution_section = round(dist_charge + metering_amt + supply_amt + awat_amt + reg_reset_amt, 2)
 
    senior_citizen_amt = round(kwh * v("senior_citizen"), 2)
    lifeline_rate_adj_amt = round(kwh * v("lifeline_rate_adj"), 2)
    senior_amt = round(senior_citizen_amt + lifeline_rate_adj_amt, 2)
 
    uc_spug_amt = round(kwh * v("uc_spug"), 2)
    uc_redci_amt = round(kwh * v("uc_redci"), 2)
    uc_env_amt = round(kwh * v("uc_env"), 2)
    uc_npc_debt_amt = round(kwh * v("uc_npc_debt"), 2)
    uc_total = round(uc_spug_amt + uc_redci_amt + uc_env_amt + uc_npc_debt_amt, 2)
 
    fit_amt = round(kwh * v("fit_all"), 2)
    lifeline_amt = round(kwh * v("lifeline_rate"), 2)
    rpt_charge_amt = round(kwh * v("rpt"), 2)
    rpt_adj_amt = round(kwh * v("rpt_adj"), 2)
    rpt_amt = round(rpt_charge_amt + rpt_adj_amt, 2)
 
    vat_gen = round(gen_amt * vat["Generation"] / 100, 2)
    vat_trans = round(trans_amt * vat["Transmission"] / 100, 2)
    vat_ancillary = round(ancillary_amt * vat.get("Ancillary Service", 0) / 100, 2)

    # replace the vat_sysloss line:
    if "System Loss" not in vat:
        raise ValueError("System Loss is neither in the VAT rates nor listed as VAT-exempt - schedule layout changed")
    sysloss_exempt = bool(vat.get("_system_loss_exempt"))
    vat_sysloss = round(sysloss_amt * vat["System Loss"] / 100, 2)

    vat_dist = round(distribution_section * vat["Other Charges"] / 100, 2)
    vat_senior = round(senior_amt * vat["Other Charges"] / 100, 2)
    vat_total = round(vat_gen + vat_trans + vat_ancillary + vat_sysloss + vat_dist + vat_senior, 2)
 
    # replace vat_sales_base and lft_charge_base:
    sysloss_in_vat_base = 0.0 if sysloss_exempt else sysloss_amt
    sysloss_in_non_vat = sysloss_amt if sysloss_exempt else 0.0
    vat_sales_base = round(gen_amt + trans_amt + ancillary_amt + sysloss_in_vat_base + distribution_section + senior_amt, 2)
    lft_charge_base = round(vat_sales_base + sysloss_in_non_vat + rpt_amt, 2)

    lft_charge_amt = round(lft_charge_base * lft_pct / 100, 2)
    lft_adj_amt = round(kwh * lft_adj_perkwh, 2)
    lft_amt = round(lft_charge_amt + lft_adj_amt, 2)
 
    # replace non_vat:
    non_vat = round(uc_total + fit_amt + lifeline_amt + rpt_amt + lft_amt + sysloss_in_non_vat, 2)

    total_energy_amount = round(vat_sales_base + vat_total + non_vat, 2)

    return {
        "tier": row[0],
        "generation": gen_amt,
        "transmission": trans_amt,
        "ancillary_service": ancillary_amt,
        "system_loss": sysloss_amt,
        "distribution": distribution_section,
        "distribution_breakdown": {
            "distribution_charge": dist_charge,
            "metering_fixed": metering_fixed_amt,
            "metering_perkwh": metering_perkwh_amt,
            "supply_fixed": supply_fixed_amt,
            "supply_perkwh": supply_perkwh_amt,
            "awat_1": awat_1_amt,
            "awat_2": awat_2_amt,
            "regulatory_reset_adj": reg_reset_amt,
        },
        "senior_citizen": senior_amt,
        "senior_citizen_breakdown": {
            "senior_citizen_subsidy": senior_citizen_amt,
            "lifeline_rate_adj": lifeline_rate_adj_amt,
        },
        "universal_charges": uc_total,
        "universal_charges_breakdown": {
            "spug": uc_spug_amt,
            "redci": uc_redci_amt,
            "environmental_fund": uc_env_amt,
            "npc_stranded_debt": uc_npc_debt_amt,
        },
        "fit_all": fit_amt,
        "lifeline": lifeline_amt,
        "rpt": rpt_amt,
        "rpt_breakdown": {"charge": rpt_charge_amt, "adj": rpt_adj_amt},
        "lft": lft_amt,
        "lft_breakdown": {"charge": lft_charge_amt, "adj": lft_adj_amt, "base": lft_charge_base},
        "vat": vat_total,
        "vat_breakdown": {
            "generation": vat_gen,
            "transmission": vat_trans,
            "ancillary_service": vat_ancillary,
            "system_loss": vat_sysloss,
            "distribution": vat_dist,
            "senior_citizen": vat_senior,
        },
        "non_vat": non_vat,
        "total_energy_amount": total_energy_amount,
    }

def analytic_bracket_rate(pdf_path, representative_kwh, lft_pct=0.5, lft_adj_perkwh=None):
    """Closed-form rate_per_kwh (slope) + fixed_charge (intercept) for the
    tier representative_kwh falls into. Same math compute_bill() uses,
    just expressed as a line instead of a rounded step-by-step total —
    this is what makes peso_to_kwh() invertible."""
    if lft_adj_perkwh is None:
        lft_adj_perkwh = default_lft_adj(pdf_path)
    table, cols, vat = get_parsed_schedule(pdf_path)
    row = find_tier_row(table, representative_kwh)
    v = lambda field: clean(row[cols[field]]) if field in cols else 0.0

    g, t, a, sl = v("generation"), v("transmission"), v("ancillary_service"), v("system_loss")
    d, mp, sp = v("distribution"), v("metering_perkwh"), v("supply_perkwh")
    AW = (v("awat_1") + v("awat_2")) if ("awat_1" in cols or "awat_2" in cols) else v("awat")
    rr = v("reg_reset")
    Kd = d + mp + sp + AW + rr

    sc, lra = v("senior_citizen"), v("lifeline_rate_adj")
    Ks = sc + lra

    Kuc = v("uc_spug") + v("uc_redci") + v("uc_env") + v("uc_npc_debt")
    fit_rate, lifeline_rate = v("fit_all"), v("lifeline_rate")
    Krpt = v("rpt") + v("rpt_adj")

    VATg, VATt, VATsl = vat["Generation"], vat["Transmission"], vat["System Loss"]
    VATa, VATd = vat.get("Ancillary Service", 0), vat["Other Charges"]

    Kenergy = g + t + a + sl + Kd + Ks
    Kvat = (g*VATg + t*VATt + a*VATa + sl*VATsl + (Kd+Ks)*VATd) / 100
    Knonvat = Kuc + fit_rate + lifeline_rate + Krpt + (Kenergy+Krpt)*lft_pct/100 + lft_adj_perkwh

    slope = Kenergy + Kvat + Knonvat
    F = v("metering_fixed") + v("supply_fixed")
    intercept = F * (1 + VATd/100 + lft_pct/100)

    return round(slope, 4), round(intercept, 4)


BRACKET_BOUNDS = {"0-200": (0, 200), "201-300": (201, 300), "301-400": (301, 400), "over-400": (401, float("inf"))}
BRACKET_REPS = {"0-200": 100, "201-300": 250, "301-400": 350, "over-400": 500}


def peso_to_kwh(pdf_path, target_peso, lft_pct=0.5, lft_adj_perkwh=None):
    """Inverse of compute_bill(): given a target peso total, find the kWh
    that produces it. If target_peso falls in a genuine gap between two
    brackets (Meralco's rates step discontinuously at every tier boundary,
    so some peso values are simply unreachable by any exact kWh), snaps
    to whichever boundary kWh is closer instead of erroring."""
    if lft_adj_perkwh is None:
        lft_adj_perkwh = default_lft_adj(pdf_path)
    ranges = []
    for name, (low, high) in BRACKET_BOUNDS.items():
        slope, intercept = analytic_bracket_rate(pdf_path, BRACKET_REPS[name], lft_pct, lft_adj_perkwh)
        peso_low = slope * low + intercept
        peso_high = slope * high + intercept if high != float("inf") else float("inf")
        ranges.append((low, high, peso_low, peso_high))
        if peso_low <= target_peso <= peso_high:
            return round((target_peso - intercept) / slope, 2)

    best_kwh, best_diff = None, float("inf")
    for low, high, peso_low, peso_high in ranges:
        for boundary_kwh, boundary_peso in [(low, peso_low), (high, peso_high)]:
            if boundary_peso == float("inf"):
                continue
            diff = abs(target_peso - boundary_peso)
            if diff < best_diff:
                best_diff, best_kwh = diff, boundary_kwh
    return best_kwh


if __name__ == "__main__":
    # Quick self-test when run directly: python3 meralco_rate_parser.py
    result = compute_bill("07-2026_rate_schedule.pdf", kwh=219)
    for k, val in result.items():
        print(f"{k:22s} {val}")