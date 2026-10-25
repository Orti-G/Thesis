"""
advisory_rules.py — GRID Tagalog NLG advisory module (rule-based)

Follows the three-stage pipeline of Reiter & Dale (1997):
    1. Document planning   -> plan_advisories(), CATEGORY priorities/channels,
                              push dedup (check_bracket_event, update_anomaly_event,
                              push_allowed)
    2. Microplanning       -> fmt_*() number formatting, bracket/severity
                              classification, merging cycle + projection into one
                              message, "Bakit?" explanation lines (EXPLAIN)
    3. Surface realization -> TEMPLATES + _realize() with template rotation (avoid_id)

The module only RESTATES outputs of the billing engine, the forecasting model and
the anomaly detector. It does no analytics of its own and does no I/O
(no DB, Firebase or FCM). main.py gathers the inputs and publishes the result.

Every build_*() returns an Advisory dict (or None):
    {category, priority, channel, push, title_tl, message_tl, explain_tl,
     template_id, data}
Persist template_id per category (RTDB /advisories/{category}/template_id) and
pass it back as avoid_id so the same sentence is not shown twice in a row.

-----------------------------------------------------------------------------
GLOSSARY AND REGISTER GUIDE
-----------------------------------------------------------------------------
Register: casual-polite, second person "mo / iyong / ka", no "po".
          Short sentences, one idea each. No exclamation-heavy cheerleading.
Taglish:  keep the English term when it is what Filipinos see on the Meralco
          bill or in the app UI; otherwise use Tagalog.

    consumption          -> konsumo            (not "pagkonsumo" in body text)
    usage / use          -> paggamit / nagamit
    electricity          -> kuryente
    bill                 -> bayarin
    estimated/projected  -> tinatayang / tantiya
    rate per kWh         -> singil kada kWh
    billing cycle        -> billing cycle      (as printed on the bill)
    bracket / tier       -> bracket            (always "<range> bracket")
    appliance            -> appliance          (no plural -s after "mga")
    anomaly              -> anomalya (titles); "hindi pangkaraniwang paggamit" (body)
    reading              -> reading
    device (GRID unit)   -> GRID device
    pattern of use       -> takbo ng iyong paggamit
    iron (appliance)     -> plantsa
    kWh, W, ₱            -> unchanged; kWh 2 decimals, W whole number, ₱1,234.56,
                            per-kWh rates 4 decimals (₱15.0615), as Meralco prints them
    announcement         -> abiso;  news -> balita;  rate schedule -> rate
    months               -> Enero ... Disyembre (MONTHS_TL)

Attribution (CMS): anything taken from Meralco starts with "Ayon sa Meralco"
or quotes only the headline, and always carries the source link. Article
bodies are never stored or reproduced; GRID writes its own text from facts.
-----------------------------------------------------------------------------
"""

import random
from datetime import datetime, timedelta
from decimal import Decimal, ROUND_HALF_UP
from typing import Dict, List, Optional, Tuple


# =======================================================================
# CONFIG
# =======================================================================

# Meralco residential consumption brackets: (label, upper bound in whole kWh).
# Labels match the keys of /meralco_rates/brackets used by post_reading().
BRACKETS = [
    ("0-200",    200),
    ("201-300",  300),
    ("301-400",  400),
    ("over-400", None),
]
BRACKET_DISPLAY = {
    "0-200":    "0–200 kWh",
    "201-300":  "201–300 kWh",
    "301-400":  "301–400 kWh",
    "over-400": "higit 400 kWh",
}

# "Approaching" = kWh reaches this fraction of the current bracket's upper bound
# (e.g. 180 kWh for the 0–200 bracket).
APPROACHING_RATIO = 0.90

# Anomaly severity from run_anomaly()'s time_zscore (vs the 48-bucket baseline).
# Checked top-down with >=. Below "mild" (or no z) = "pattern".
# Starting cut-points; test-set median of flagged readings was 6.70σ. Tune these.
SEVERITY_BANDS = [("severe", 6.0), ("moderate", 4.0), ("mild", 3.0)]
SEVERITY_RANK = {"pattern": 0, "mild": 1, "moderate": 2, "severe": 3}

# Flagged 5-min readings at most this far apart form ONE event / ONE prompt.
ANOMALY_EVENT_GAP = timedelta(minutes=10)
# Minimum time between two anomaly pushes, unless the new one is severe.
ANOMALY_PUSH_COOLDOWN = timedelta(minutes=30)

# Event lifecycle (event cards):
#   open   -> flagged readings keep arriving; card shows "Nangyayari pa", no buttons.
#             Only a SEVERE event pushes right away (safety); others wait.
#   closed -> no flagged reading for ANOMALY_EVENT_GAP; card gets the summary and
#             the three answers, and ONE review push is sent (bundled, throttled).
REVIEW_PUSH_COOLDOWN = timedelta(minutes=30)   # at most one review push per 30 min
REVIEW_EXPIRY = timedelta(days=7)              # unanswered events expire (expired_at set, acknowledged stays NULL)
REVIEW_NOTIFY_WINDOW = timedelta(hours=1)      # only events that ended this recently get a review push
QUIET_SEVERITIES = ("pattern", "mild")         # one-reading events of these: card, no push

# Daily: within ±5% of the typical (EWMA) daily total counts as "halos pareho".
DAILY_SAME_TOLERANCE = 0.05
# Weekly: change smaller than ±10% counts as "halos pareho".
WEEKLY_NOTABLE_CHANGE = 0.10
# Anomalous energy below this is not mentioned in the daily explanation.
MIN_ANOMALOUS_KWH_TO_MENTION = 0.01

# Document plan: priority (lower = shown first), FCM channel, and push default.
# channel None = in-app only.
CATEGORY = {
    "anomaly": {"priority": 1, "channel": "high_channel",   "push": True},
    "review":  {"priority": 1, "channel": "medium_channel", "push": True},
    "device":  {"priority": 1, "channel": "high_channel",   "push": True},
    "bracket": {"priority": 2, "channel": "medium_channel", "push": True},
    "cycle":   {"priority": 3, "channel": "low_channel",    "push": False},
    "rates":   {"priority": 4, "channel": "low_channel",    "push": False},
    "daily":   {"priority": 5, "channel": None,             "push": False},
    "weekly":  {"priority": 6, "channel": None,             "push": False},
}
MAX_PUSH_PER_PLAN = 2

# Rate change smaller than this (pesos on the household's bill) = "halos walang pagbabago".
RATE_FLAT_PESO = 1.00

# HITL prompt attached to every anomaly advisory.
# acknowledged: True = real anomaly, False = normal use, None = leave NULL (unsure).
HITL_PROMPT = "Normal ba ang paggamit na ito?"
HITL_OPTIONS = [
    {"answer": "real",   "label_tl": "Totoong kakaiba", "acknowledged": True},
    {"answer": "normal", "label_tl": "Normal na gamit", "acknowledged": False},
    {"answer": "unsure", "label_tl": "Hindi sigurado",  "acknowledged": None},
]

MONTHS_TL = ["Enero", "Pebrero", "Marso", "Abril", "Mayo", "Hunyo", "Hulyo",
             "Agosto", "Setyembre", "Oktubre", "Nobyembre", "Disyembre"]


# =======================================================================
# TEMPLATES  (surface realization)
# Slots are pre-formatted strings from microplanning; never raw floats.
# =======================================================================

TITLES = {
    "bracket.approaching": "Malapit na sa susunod na bracket",
    "bracket.crossed":     "Bagong bracket: {bracket}",
    "cycle.same":          "Billing cycle: tantiya hanggang ika-27",
    "cycle.near_edge":     "Billing cycle: malapit sa hangganan",
    "cycle.will_cross":    "Billing cycle: posibleng tumaas ang bracket",
    "daily.higher":        "Konsumo ngayong araw",
    "daily.lower":         "Konsumo ngayong araw",
    "daily.same":          "Konsumo ngayong araw",
    "daily.no_baseline":   "Konsumo ngayong araw",
    "weekly.up":           "Lingguhang paghahambing",
    "weekly.down":         "Lingguhang paghahambing",
    "weekly.flat":         "Lingguhang paghahambing",
    "weekly.no_baseline":  "Lingguhang paghahambing",
    "weekly.insufficient": "Lingguhang paghahambing",
    "anomaly.severe":      "⚠️ Matinding anomalya sa kuryente",
    "anomaly.moderate":    "⚠️ Anomalya sa kuryente",
    "anomaly.mild":        "Bahagyang anomalya sa kuryente",
    "anomaly.pattern":     "Hindi pangkaraniwang paggamit",
    "anomaly.escalated":   "⚠️ Lumala ang anomalya",
    "review.severe":       "Matinding anomalya · {when}",
    "review.moderate":     "Anomalya · {when}",
    "review.mild":         "Bahagyang anomalya · {when}",
    "review.pattern":      "Hindi pangkaraniwang paggamit · {when}",
    "review.ongoing":      "Nangyayari pa · mula {start}",
    "review.rise":         "Biglang pagtaas ng konsumo · {when}",
    "review.drop":         "Biglang pagbaba ng konsumo · {when}",
    "anomaly.rise":        "Biglang tumaas ang konsumo",
    "anomaly.drop":        "Biglang bumaba ang konsumo",
    "review_push.one":     "Tapos na ang anomalya",
    "review_push.many":    "{n} anomalyang hinihintay ang sagot mo",
    "device.offline":      "⚠️ Offline ang GRID device",
    "device.online":       "Online na ulit ang GRID device",
    "rates.up":            "Tumaas ang rate ngayong {month}",
    "rates.down":          "Bumaba ang rate ngayong {month}",
    "rates.flat":          "Rate ngayong {month}",
    # CMS item titles (GRID's own wording; the source title is shown separately)
    "cms.rate.up":         "Mas mataas na rate ng Meralco ngayong {month}",
    "cms.rate.down":       "Mas mababang rate ng Meralco ngayong {month}",
    "cms.rate.flat":       "Rate ng Meralco ngayong {month}",
    "cms.news":            "Balita mula sa Meralco",
    "cms.advisory":        "Abiso mula sa Meralco",
    "cms.maintenance":     "Iskedyul ng maintenance ng Meralco",
}

TEMPLATES: Dict[str, List[str]] = {
    # ---- Bracket (tier) alerts -------------------------------------------
    "bracket.approaching": [
        "Malapit ka nang lumampas sa {bracket} bracket. {kwh} na ang konsumo mo "
        "ngayong billing cycle, {headroom} na lang bago ang {upper}, at may "
        "{days_left} pa bago matapos ang cycle.",

        "{kwh} na ang nagamit mo ngayong billing cycle. Kapag lumampas ito sa "
        "{upper}, mapupunta ka sa {next_bracket} bracket, na may mas mataas na "
        "singil kada kWh.",
    ],
    "bracket.crossed": [
        "Lumampas na sa {upper_prev} ang konsumo mo ngayong billing cycle ({kwh}). "
        "Nasa {bracket} bracket ka na, kaya mas mataas na ang singil kada kWh.",

        "Pumasok na sa {bracket} bracket ang konsumo mo ngayong billing cycle "
        "({kwh}). May {days_left} pa bago matapos ang cycle, kaya bantayan ang "
        "paggamit ng malalaking appliance tulad ng aircon.",
    ],

    # ---- Cycle status + month-end projection (merged) --------------------
    "cycle.same": [
        "Sa unang {days_so_far} ng billing cycle, {kwh} na ang konsumo mo. Kung "
        "magpapatuloy ang ganitong takbo ng iyong paggamit, aabot ito sa "
        "humigit-kumulang {projected} pagdating ng ika-27, kaya mananatili ka sa "
        "{proj_bracket} bracket.{bill_sentence}",

        "{kwh} na ang nagamit mo sa unang {days_so_far} ng billing cycle. "
        "Tinatayang {projected} ang kabuuan pagdating ng ika-27, pasok pa rin sa "
        "{proj_bracket} bracket.{bill_sentence}",
    ],
    "cycle.near_edge": [
        "Sa unang {days_so_far} ng billing cycle, {kwh} na ang konsumo mo. "
        "Tinatayang aabot ito sa {projected} pagdating ng ika-27, malapit na sa "
        "{upper} na hangganan ng {proj_bracket} bracket.{bill_sentence}",

        "Tinatayang {projected} ang kabuuang konsumo mo pagdating ng ika-27, "
        "kaunti na lang bago ang {upper}. Kung mababawasan ang paggamit sa "
        "natitirang {days_left}, mananatili ka sa {proj_bracket} bracket."
        "{bill_sentence}",
    ],
    "cycle.will_cross": [
        "Sa unang {days_so_far} ng billing cycle, {kwh} na ang konsumo mo "
        "({bracket} bracket). Kung magpapatuloy ang ganitong takbo ng iyong "
        "paggamit, aabot ito sa humigit-kumulang {projected}, kaya posibleng "
        "mapunta ka sa {proj_bracket} bracket bago matapos ang cycle.{bill_sentence}",

        "Tinatayang {projected} ang kabuuang konsumo mo pagdating ng ika-27, kaya "
        "posibleng mapunta ka sa {proj_bracket} bracket. Sa ngayon, {kwh} na ang "
        "nagamit mo at may {days_left} pa sa cycle.{bill_sentence}",
    ],

    # ---- Daily forecast (vs typical EWMA daily total) --------------------
    "daily.higher": [
        "Tinatayang {predicted} ang kabuuang konsumo mo ngayong araw, mas mataas "
        "nang {diff} kaysa sa karaniwan mong {typical} kada araw.",

        "Mas mataas sa karaniwan ang inaasahang konsumo mo ngayon: {predicted}, "
        "kumpara sa karaniwang {typical} kada araw. Tingnan kung may appliance na "
        "mas matagal na nakabukas, tulad ng aircon o plantsa.",
    ],
    "daily.lower": [
        "Tinatayang {predicted} ang kabuuang konsumo mo ngayong araw, mas mababa "
        "nang {diff} kaysa sa karaniwan mong {typical} kada araw. Magandang takbo ito.",

        "Mas matipid ang araw na ito: {predicted} ang inaasahang konsumo, "
        "kumpara sa karaniwang {typical} kada araw.",
    ],
    "daily.same": [
        "Tinatayang {predicted} ang kabuuang konsumo mo ngayong araw, halos "
        "kapareho ng karaniwan mong {typical} kada araw.",

        "Walang malaking pagbabago ngayon: {predicted} ang inaasahang konsumo, "
        "malapit sa karaniwang {typical} kada araw.",
    ],
    "daily.no_baseline": [
        "Tinatayang {predicted} ang kabuuang konsumo mo ngayong araw.",
    ],

    # ---- Weekly (completed days vs same weekdays last week) --------------
    "weekly.up": [
        "{period}, {cur} ang nagamit mo, {pct} na mas mataas kaysa sa {same_days} "
        "noong nakaraang linggo ({last}).",

        "Tumaas nang {pct} ang konsumo mo ngayong linggo: {cur}, kumpara sa "
        "{last} sa {same_days} noong nakaraang linggo.",
    ],
    "weekly.down": [
        "{period}, {cur} ang nagamit mo, {pct} na mas mababa kaysa sa {same_days} "
        "noong nakaraang linggo ({last}). Ipagpatuloy ang ganitong takbo.",

        "Bumaba nang {pct} ang konsumo mo ngayong linggo: {cur}, kumpara sa "
        "{last} sa {same_days} noong nakaraang linggo.",
    ],
    "weekly.flat": [
        "Halos pareho ang konsumo mo ngayong linggo ({cur}) at sa {same_days} "
        "noong nakaraang linggo ({last}).",
    ],
    "weekly.no_baseline": [
        "{period}, {cur} ang nagamit mo. Wala pang sapat na datos noong "
        "nakaraang linggo para sa paghahambing.",
    ],
    "weekly.insufficient": [
        "Bago pa lang ang linggong ito, kaya wala pang kumpletong araw na "
        "maihahambing. Lalabas bukas ang paghahambing sa nakaraang linggo.",
    ],

    # ---- Anomaly (one per event) ----------------------------------------
    "anomaly.severe": [
        "Napakataas ng konsumo ngayon: {power}, malayo sa karaniwang gamit mo "
        "tuwing ganitong oras. Suriin agad ang mga nakabukas na appliance.",

        "May matinding hindi pangkaraniwang paggamit ng kuryente: {power} sa "
        "nakalipas na 5 minuto. Tingnan kung may sirang appliance o naiwang "
        "nakabukas.",
    ],
    "anomaly.moderate": [
        "Mas mataas kaysa karaniwan ang konsumo ngayon: {power}. Tingnan kung may "
        "malaking appliance na naiwang nakabukas.",

        "Kapansin-pansin ang paggamit ng kuryente ngayon ({power}) para sa "
        "ganitong oras. Kumpirmahin kung inaasahan mo ito.",
    ],
    "anomaly.mild": [
        "Bahagyang mas mataas kaysa karaniwan ang konsumo ngayon ({power}). Kung "
        "may bago kang ginamit na appliance, maaaring iyon ang dahilan.",

        "Medyo naiiba sa karaniwan ang paggamit mo ngayon ({power}). Hindi pa ito "
        "alarmante, pero mabuting tingnan.",
    ],
    "anomaly.pattern": [
        "May napansing hindi pangkaraniwang paggamit ng kuryente ({power}). "
        "Kumpirmahin kung normal ito.",
    ],
    "anomaly.escalated": [
        "Lumala ang hindi pangkaraniwang paggamit: {power} na ngayon, mas malayo "
        "pa sa karaniwan kaysa sa unang alert. Suriin agad ang mga nakabukas na "
        "appliance.",
    ],

    # ---- Anomaly review list (past events; completed aspect, with the time) --
    "review.severe": [
        "Napakataas ng konsumo {span_pp}: umabot ito sa {power}, malayo sa "
        "karaniwang gamit mo tuwing ganitong oras.",
    ],
    "review.moderate": [
        "Mas mataas kaysa karaniwan ang konsumo {span_pp}, hanggang {power}.",
    ],
    "review.mild": [
        "Bahagyang mas mataas kaysa karaniwan ang konsumo {span_pp} ({power}).",
    ],
    "review.pattern": [
        "May hindi pangkaraniwang paggamit ng kuryente {span_pp} ({power}).",
    ],
    "review.ongoing": [
        "Mas mataas pa rin kaysa karaniwan ang konsumo mula {start} (hanggang {power} "
        "sa ngayon). Hihingin namin ang sagot mo kapag natapos na ito.",
    ],
    "review.ongoing_drop": [
        "Mas mababa pa rin kaysa karaniwan ang konsumo mula {start} ({power} sa ngayon). "
        "Hihingin namin ang sagot mo kapag natapos na ito.",
    ],
    # Flagged by a sudden change vs the last hour, not by the time-of-day baseline
    "review.rise": [
        "Biglang tumaas ang konsumo {span_pp}: umabot sa {power} mula sa karaniwang "
        "{baseline} sa nakaraang isang oras.",
    ],
    "review.drop": [
        "Biglang bumaba ang konsumo {span_pp}: {power} na lang mula sa karaniwang "
        "{baseline} sa nakaraang isang oras. Kung may appliance na dapat nakabukas, "
        "gaya ng ref, tingnan kung gumagana ito.",
    ],
    "anomaly.rise": [
        "Biglang tumaas ang konsumo ngayon: {power}, mula sa karaniwang {baseline} sa "
        "nakaraang isang oras. Kumpirmahin kung inaasahan mo ito.",
    ],
    "anomaly.drop": [
        "Biglang bumaba ang konsumo ngayon: {power}, mula sa karaniwang {baseline} sa "
        "nakaraang isang oras. Kung may appliance na dapat nakabukas, gaya ng ref, "
        "tingnan kung gumagana ito.",
    ],
    # Summary sentence added to a CLOSED card (energy measured, priced by billing)
    "review.summary": [
        "Tumagal ito nang {minutes} minuto at umabot sa {kwh}{cost_part}.",
    ],
    "review_push.one": [
        "Natapos na ang hindi pangkaraniwang paggamit {span_pp} ({minutes} minuto). "
        "Normal ba ito? Buksan ang GRID para sumagot.",
    ],
    "review_push.many": [
        "May {n} anomalya na tapos na at hinihintay ang sagot mo. Buksan ang GRID para "
        "sumagot; makatutulong ito para mapahusay ang detector.",
    ],

    # ---- Device status ---------------------------------------------------
    "device.offline": [
        "Walang natatanggap na datos mula sa GRID device mula {since}. Suriin kung "
        "nakasaksak ito at kung may Wi-Fi.",

        "Offline ang GRID device mula {since}. Tingnan ang kuryente at Wi-Fi "
        "connection ng device.",
    ],
    "device.online": [
        "Muling nakakonekta ang GRID device. Tuloy na ulit ang pagmo-monitor.",
    ],

    # ---- Monthly rate change, personalized (household's billed kWh) ------
    "rates.up": [
        "Tumaas ang rate ng Meralco ngayong {month}. Para sa {kwh} na {basis}, "
        "{cur_total} ang bayarin sa bagong rate, {diff} na mas mataas kaysa kung "
        "rate noong {prev_month} ang gagamitin ({prev_total}).",

        "Dahil sa bagong rate ng Meralco ngayong {month}, mas mataas nang "
        "humigit-kumulang {diff} ang bayarin para sa {kwh} na {basis} "
        "({cur_total} mula {prev_total}).",
    ],
    "rates.down": [
        "Bumaba ang rate ng Meralco ngayong {month}. Para sa {kwh} na {basis}, "
        "{cur_total} ang bayarin sa bagong rate, {diff} na mas mababa kaysa kung "
        "rate noong {prev_month} ang gagamitin ({prev_total}).",

        "Dahil sa bagong rate ng Meralco ngayong {month}, mas mababa nang "
        "humigit-kumulang {diff} ang bayarin para sa {kwh} na {basis} "
        "({cur_total} mula {prev_total}).",
    ],
    "rates.flat": [
        "Halos walang pagbabago sa rate ng Meralco ngayong {month}. Para sa {kwh} "
        "na {basis}, {cur_total} ang bayarin, malapit sa {prev_total} kung rate "
        "noong {prev_month} ang gagamitin.",
    ],

    # ---- CMS bodies: GRID's own text built from extracted FACTS only -----
    # Meralco's article text is never stored or reproduced; items carry
    # "Ayon sa Meralco" plus the source link.
    "cms.rate.up": [
        "Ayon sa Meralco, tumaas ang singil sa kuryente ngayong {month}. Para sa "
        "karaniwang bahay, {rate_new} na ang singil kada kWh mula {rate_old} "
        "noong {prev_month}, dagdag na {change} kada kWh.{typical_sentence} "
        "Tingnan sa GRID kung magkano ang epekto nito sa tinatayang bayarin mo.",
    ],
    "cms.rate.down": [
        "Ayon sa Meralco, bumaba ang singil sa kuryente ngayong {month}. Para sa "
        "karaniwang bahay, {rate_new} na lang ang singil kada kWh mula {rate_old} "
        "noong {prev_month}, bawas na {change} kada kWh.{typical_sentence} "
        "Tingnan sa GRID kung magkano ang epekto nito sa tinatayang bayarin mo.",
    ],
    "cms.rate.flat": [
        "Ayon sa Meralco, halos walang pagbabago sa singil ngayong {month}: "
        "{rate_new} kada kWh para sa karaniwang bahay.{typical_sentence}",
    ],
    "cms.news": [
        "May bagong balita mula sa Meralco: “{source_title}”. Basahin "
        "ang buong detalye sa website ng Meralco.",
    ],
    "cms.advisory": [
        "May bagong abiso ang Meralco: “{source_title}”. Basahin ang "
        "buong detalye sa website ng Meralco.",
    ],
    "cms.maintenance": [
        "May bagong iskedyul ng maintenance mula sa Meralco: “{source_title}”. "
        "Tingnan sa website ng Meralco kung kasama ang iyong lugar.",
    ],
}

# "Bakit?" lines — what a tier means, why a reading was flagged, how uncertain
# a projection is (Chapter 5 recommendations / Self-descriptiveness).
EXPLAIN = {
    "bracket": (
        "Sa Meralco, ang singil kada kWh ay nakabatay sa kabuuang konsumo mo sa "
        "buong billing cycle (ika-28 hanggang ika-27). Ang mga bracket ay 0–200, "
        "201–300, 301–400, at higit 400 kWh. Kapag lumampas ka sa isang bracket, "
        "ang mas mataas na rate ang gagamitin sa lahat ng kWh mo sa cycle na iyon, "
        "hindi lang sa sobra.{calib_sentence}"
    ),
    "cycle": (
        "Ang tantiya ay ang nagamit mo na, dagdag ang forecast para sa araw na ito "
        "at ang karaniwang konsumo mo kada araw para sa natitirang {days_left}."
        "{calib_sentence} Mas tumpak ang tantiya habang papalapit ang katapusan ng "
        "cycle, kaya maaari pa itong magbago."
    ),
    "rates": (
        "Kinuwenta ito ng GRID mula sa Summary of Schedule of Rates ng Meralco para "
        "sa {month} at {prev_month}. Sa {bracket} bracket, {prev_rate} ang singil "
        "kada kWh noon at {cur_rate} ngayon, at pareho ang {kwh} na ginamit sa "
        "dalawang kuwenta. Epekto lamang ito ng pagbabago ng rate, hindi ng "
        "pagbabago ng iyong paggamit.{basis_note}"
    ),
    "daily": (
        "Tinantiya ng forecasting model ang konsumo para sa natitirang oras ng araw "
        "batay sa nagamit mo na hanggang ngayon.{anomaly_sentence} Ang "
        "\"karaniwan\" ay ang average ng mga nakaraang araw, kung saan mas mabigat "
        "ang mga pinakahuling araw."
    ),
    "weekly": (
        "Inihahambing lang ang mga araw na tapos na (hindi kasama ang araw na ito) "
        "sa parehong mga araw ng nakaraang linggo, para patas ang paghahambing."
    ),
    "anomaly": (
        "Na-flag ito ng anomaly detector dahil malayo ang {power} sa karaniwang "
        "gamit mo tuwing ganitong oras{z_part}.{base_sentence} Ang sagot mo sa "
        "tanong ay ginagamit para mapahusay ang detector."
    ),
    "anomaly_rise": (
        "Na-flag ito ng anomaly detector dahil biglang tumaas ang power: {power}, mula "
        "sa karaniwang {baseline} sa nakaraang isang oras. Para sa ganitong oras, hindi "
        "ito malayo sa karaniwan mo{z_part}; ang biglang pagbabago ang napansin. Ang "
        "sagot mo sa tanong ay ginagamit para mapahusay ang detector."
    ),
    "anomaly_drop": (
        "Na-flag ito ng anomaly detector dahil biglang bumaba ang power: {power}, mula "
        "sa karaniwang {baseline} sa nakaraang isang oras{z_part}. Ang sagot mo sa "
        "tanong ay ginagamit para mapahusay ang detector."
    ),
    "device": (
        "Itinuturing na offline ang device kapag walang bagong reading sa loob ng "
        "{timeout} segundo. Habang offline, hindi naa-update ang live reading at "
        "hindi makapagpapadala ng alert."
    ),
}


# =======================================================================
# LOGIC — microplanning helpers
# =======================================================================

def _half_up(x: float, places: int = 0) -> Decimal:
    q = Decimal(1).scaleb(-places)
    return Decimal(str(x)).quantize(q, rounding=ROUND_HALF_UP)


def whole_kwh(kwh: float) -> int:
    """Whole kWh as printed on the Meralco bill (half-up rounding)."""
    return int(_half_up(max(float(kwh), 0.0)))


def fmt_kwh(kwh: float) -> str:
    return f"{_half_up(max(float(kwh), 0.0), 2):,.2f} kWh"


def fmt_peso(php: float) -> str:
    return f"₱{_half_up(float(php), 2):,.2f}"


def fmt_watts(w: float) -> str:
    return f"{_half_up(max(float(w), 0.0)):,.0f} W"


def fmt_pct(fraction: float) -> str:
    return f"{_half_up(abs(float(fraction)) * 100):.0f}%"


def fmt_days(n: int) -> str:
    return f"{int(n)} araw"


def fmt_time(dt: datetime) -> str:
    return dt.strftime("%I:%M %p").lstrip("0")


def fmt_rate(php_per_kwh: float) -> str:
    """Per-kWh rate with 4 decimals, as Meralco publishes it."""
    return f"₱{_half_up(abs(float(php_per_kwh)), 4):,.4f}"


def fmt_month(year: int, month: int, with_year: bool = True) -> str:
    name = MONTHS_TL[int(month) - 1]
    return f"{name} {int(year)}" if with_year else name


def prev_period(year: int, month: int) -> Tuple[int, int]:
    return (year - 1, 12) if month == 1 else (year, month - 1)


def _calib_sentence(k: Optional[float]) -> str:
    if not k:
        return ""
    return (f" Ginamit ang basa ng GRID na itinama para tumugma sa metro ng Meralco "
            f"(× {k:.3f}), kaya bahagyang mas mataas ito kaysa sa \"Total Used\" sa app.")


def bracket_index(kwh: float) -> int:
    w = whole_kwh(kwh)
    for i, (_, upper) in enumerate(BRACKETS):
        if upper is None or w <= upper:
            return i
    return len(BRACKETS) - 1


def bracket_label(kwh: float) -> str:
    return BRACKETS[bracket_index(kwh)][0]


def bracket_display(idx: int) -> str:
    return BRACKET_DISPLAY[BRACKETS[idx][0]]


def is_approaching(kwh: float) -> bool:
    upper = BRACKETS[bracket_index(kwh)][1]
    return upper is not None and float(kwh) >= APPROACHING_RATIO * upper


def anomaly_severity(time_zscore: Optional[float]) -> str:
    if time_zscore is None:
        return "pattern"
    for name, bound in SEVERITY_BANDS:
        if time_zscore >= bound:
            return name
    return "pattern"


def _realize(key: str, slots: dict, avoid_id: Optional[str] = None,
             rng=random) -> Tuple[str, str]:
    """Pick a phrasing for `key`, skipping avoid_id when another exists."""
    options = TEMPLATES[key]
    ids = [f"{key}.{i}" for i in range(len(options))]
    pool = [i for i, t in enumerate(ids) if t != avoid_id] or list(range(len(options)))
    i = rng.choice(pool)
    return options[i].format(**slots), ids[i]


def _advisory(category: str, key: str, slots: dict, explain: str = "",
              data: Optional[dict] = None, avoid_id: Optional[str] = None,
              rng=random) -> dict:
    message, tid = _realize(key, slots, avoid_id, rng)
    cfg = CATEGORY[category]
    return {
        "category":    category,
        "priority":    cfg["priority"],
        "channel":     cfg["channel"],
        "push":        cfg["push"],
        "title_tl":    TITLES[key].format(**slots),
        "message_tl":  message,
        "explain_tl":  explain,
        "template_id": tid,
        "data":        data or {},
    }


# =======================================================================
# LOGIC — document planning (state + push decisions, still pure)
# =======================================================================

def check_bracket_event(kwh: float, cycle_start: str,
                        state: Optional[dict]) -> Tuple[Optional[str], dict]:
    """Decide whether a bracket alert is due.

    state (persisted by main.py): {"cycle_start", "bracket_idx", "approach_idx"}
    Returns (event, new_state); event is None, "approaching" or "crossed".
    A new cycle (or no state yet) sets the baseline silently, so a restart or a
    first deploy mid-cycle never fires a false "crossed" alert. Each alert fires
    once per bracket per cycle.
    """
    idx = bracket_index(kwh)
    if not state or state.get("cycle_start") != cycle_start:
        state = {"cycle_start": cycle_start, "bracket_idx": idx, "approach_idx": -1}

    new = dict(state)
    if idx > state["bracket_idx"]:
        new["bracket_idx"] = idx
        return "crossed", new
    if is_approaching(kwh) and state.get("approach_idx", -1) < idx:
        new["approach_idx"] = idx
        return "approaching", new
    return None, new


def update_anomaly_event(event: Optional[dict], window_ts: datetime,
                         log_id: Optional[int],
                         time_zscore: Optional[float]) -> Tuple[dict, str]:
    """Group flagged readings <= ANOMALY_EVENT_GAP apart into one event.
    Returns (event, action); action is "new", "escalated" or "extended".
    Only "new" and "escalated" produce a new advisory."""
    sev = anomaly_severity(time_zscore)
    ids = [log_id] if log_id is not None else []

    if event is None or window_ts - event["last_ts"] > ANOMALY_EVENT_GAP:
        return {"start_ts": window_ts, "last_ts": window_ts, "log_ids": ids,
                "severity": sev, "peak_z": time_zscore}, "new"

    ev = dict(event)
    ev["last_ts"] = window_ts
    ev["log_ids"] = list(event["log_ids"]) + ids
    if SEVERITY_RANK[sev] > SEVERITY_RANK[event["severity"]]:
        ev["severity"] = sev
        ev["peak_z"] = time_zscore
        return ev, "escalated"
    return ev, "extended"


def push_allowed(last_push: Optional[datetime], now: datetime,
                 cooldown: timedelta) -> bool:
    return last_push is None or now - last_push >= cooldown


def plan_advisories(advisories: List[Optional[dict]],
                    max_push: int = MAX_PUSH_PER_PLAN) -> List[dict]:
    """Drop empties, order by priority, cap pushes in one batch."""
    items = sorted((a for a in advisories if a), key=lambda a: a["priority"])
    pushed = 0
    for a in items:
        if a["push"]:
            if pushed >= max_push:
                a["push"] = False
            else:
                pushed += 1
    return items


# =======================================================================
# LOGIC — advisory builders
# =======================================================================

def build_bracket_advisory(event: str, kwh: float, days_left: int,
                           calibration_k: Optional[float] = None,
                           avoid_id: Optional[str] = None, rng=random) -> Optional[dict]:
    """event from check_bracket_event(): "approaching" or "crossed".
    kwh: billed (calibrated) kWh this cycle, as main.py prices it."""
    if event not in ("approaching", "crossed"):
        return None
    idx = bracket_index(kwh)
    upper = BRACKETS[idx][1]
    slots = {
        "kwh":          fmt_kwh(kwh),
        "bracket":      bracket_display(idx),
        "days_left":    fmt_days(days_left),
        "upper":        f"{upper} kWh" if upper else "",
        "headroom":     fmt_kwh(upper - kwh) if upper else "",
        "next_bracket": bracket_display(idx + 1) if idx + 1 < len(BRACKETS) else "",
        "upper_prev":   f"{BRACKETS[idx - 1][1]} kWh" if idx > 0 else "",
    }
    if event == "approaching" and upper is None:
        return None
    explain = EXPLAIN["bracket"].format(calib_sentence=_calib_sentence(calibration_k))
    return _advisory("bracket", f"bracket.{event}", slots, explain,
                     data={"bracket": BRACKETS[idx][0], "event": event},
                     avoid_id=avoid_id, rng=rng)


def build_cycle_advisory(accumulated_kwh: float, projected_kwh: float,
                         days_so_far: int, days_left: int,
                         projected_bill_php: Optional[float] = None,
                         calibration_k: Optional[float] = None,
                         avoid_id: Optional[str] = None, rng=random) -> dict:
    """Cycle status + month-end projection in ONE message.
    accumulated_kwh: billed kWh this cycle (adjusted cumul_kwh × k).
    projected_kwh:   calibrated projection (projected_eom_calibrated_kWh).
    projected_bill_php: total from compute_bill() on round(projected_kwh)."""
    cur_idx = bracket_index(accumulated_kwh)
    proj_idx = max(bracket_index(projected_kwh), cur_idx)
    upper = BRACKETS[proj_idx][1]

    if proj_idx > cur_idx:
        key = "cycle.will_cross"
    elif is_approaching(projected_kwh) and bracket_index(projected_kwh) == cur_idx:
        key = "cycle.near_edge"
    else:
        key = "cycle.same"

    slots = {
        "kwh":           fmt_kwh(accumulated_kwh),
        "projected":     fmt_kwh(projected_kwh),
        "bracket":       bracket_display(cur_idx),
        "proj_bracket":  bracket_display(proj_idx),
        "upper":         f"{upper} kWh" if upper else "",
        "days_so_far":   fmt_days(max(days_so_far, 1)),
        "days_left":     fmt_days(days_left),
        "bill_sentence": (f" Tinatayang bayarin: {fmt_peso(projected_bill_php)}."
                          if projected_bill_php is not None else ""),
    }
    explain = EXPLAIN["cycle"].format(days_left=slots["days_left"],
                                      calib_sentence=_calib_sentence(calibration_k))
    return _advisory("cycle", key, slots, explain,
                     data={"bracket": BRACKETS[cur_idx][0],
                           "projected_bracket": BRACKETS[proj_idx][0]},
                     avoid_id=avoid_id, rng=rng)


def build_daily_advisory(predicted_total_kwh: float, typical_daily_kwh: float,
                         anomalous_kwh: float = 0.0,
                         avoid_id: Optional[str] = None, rng=random) -> dict:
    """predicted_total_kwh: full expected day total (clean + anomalous).
    typical_daily_kwh: EWMA daily level from /forecast (avg_daily_kWh)."""
    slots = {"predicted": fmt_kwh(predicted_total_kwh), "typical": fmt_kwh(typical_daily_kwh),
             "diff": fmt_kwh(abs(predicted_total_kwh - typical_daily_kwh))}

    if typical_daily_kwh <= 0:
        key = "daily.no_baseline"
    else:
        ratio = (predicted_total_kwh - typical_daily_kwh) / typical_daily_kwh
        if ratio > DAILY_SAME_TOLERANCE:
            key = "daily.higher"
        elif ratio < -DAILY_SAME_TOLERANCE:
            key = "daily.lower"
        else:
            key = "daily.same"

    anom = (f" Kasama rito ang {fmt_kwh(anomalous_kwh)} mula sa mga reading na "
            f"na-flag bilang anomalya." if anomalous_kwh >= MIN_ANOMALOUS_KWH_TO_MENTION else "")
    return _advisory("daily", key, slots, EXPLAIN["daily"].format(anomaly_sentence=anom),
                     avoid_id=avoid_id, rng=rng)


def compare_weeks(current_days: List[dict], last_days: List[dict],
                  today: str) -> Tuple[float, float, int]:
    """Completed days of this week (date < today) vs the same weekdays of last
    week. Both lists come from /history/weekly-comparison, sorted Sun→.
    Returns (current_kwh, last_same_days_kwh, n_days)."""
    done = [d for d in current_days if d["date"] < today]
    n = len(done)
    cur = sum(float(d["daily_kwh"]) for d in done)
    last = sum(float(d["daily_kwh"]) for d in last_days[:n])
    return cur, last, n


def build_weekly_advisory(current_days: List[dict], last_days: List[dict],
                          today: str, avoid_id: Optional[str] = None,
                          rng=random) -> dict:
    cur, last, n = compare_weeks(current_days, last_days, today)
    slots = {
        "cur":       fmt_kwh(cur),
        "last":      fmt_kwh(last),
        "period":    "Noong Linggo" if n == 1 else "Mula Linggo hanggang kahapon",
        "same_days": "parehong araw" if n == 1 else f"parehong {fmt_days(n)}",
        "pct":       "",
    }
    change = None
    if n == 0:
        key, direction = "weekly.insufficient", "insufficient"
    elif last <= 0:
        key, direction = "weekly.no_baseline", "no_baseline"
    else:
        change = (cur - last) / last
        slots["pct"] = fmt_pct(change)
        if change > WEEKLY_NOTABLE_CHANGE:
            key, direction = "weekly.up", "up"
        elif change < -WEEKLY_NOTABLE_CHANGE:
            key, direction = "weekly.down", "down"
        else:
            key, direction = "weekly.flat", "flat"
    data = {
        "days_compared":      n,
        "direction":          direction,                       # insufficient / no_baseline / up / down / flat
        "current_kwh":        round(cur, 4),                   # finished days this week
        "last_same_days_kwh": round(last, 4),                  # same weekdays last week
        "diff_kwh":           round(cur - last, 4),
        "pct_change":         round(change * 100, 1) if change is not None else None,
    }
    return _advisory("weekly", key, slots, EXPLAIN["weekly"],
                     data=data, avoid_id=avoid_id, rng=rng)


def anomaly_kind(power: float, baseline_1hr: Optional[float],
                 time_zscore: Optional[float]) -> str:
    """Why the detector's own values say this reading is unusual:
    "hour" = far above the usual for this time of day (time_zscore >= 3),
    "rise" / "drop" = a sudden change vs the last hour's mean, otherwise.
    Only states detector inputs; no cause is inferred."""
    if time_zscore is not None and time_zscore >= SEVERITY_BANDS[-1][1]:
        return "hour"
    if baseline_1hr is None or baseline_1hr <= 0:
        return "hour"                         # no baseline: fall back to the generic text
    return "rise" if power >= baseline_1hr else "drop"


def anomaly_explain(kind: str, power: float, baseline_1hr: Optional[float],
                    time_zscore: Optional[float]) -> str:
    z_part = f" (z-score: {time_zscore:.1f})" if time_zscore is not None else ""
    if kind in ("rise", "drop"):
        return EXPLAIN[f"anomaly_{kind}"].format(power=fmt_watts(power),
                                                 baseline=fmt_watts(baseline_1hr), z_part=z_part)
    base = (f" Sa isang oras bago nito, nasa {fmt_watts(baseline_1hr)} ang karaniwan "
            f"mong power." if baseline_1hr and baseline_1hr > 0 else "")
    return EXPLAIN["anomaly"].format(power=fmt_watts(power), z_part=z_part, base_sentence=base)


def build_anomaly_advisory(power_avg: float, roll_mean_1hr: Optional[float],
                           time_zscore: Optional[float], event: dict,
                           escalated: bool = False,
                           avoid_id: Optional[str] = None, rng=random) -> dict:
    """One advisory per anomaly event (see update_anomaly_event)."""
    sev = event["severity"]
    kind = anomaly_kind(power_avg, roll_mean_1hr, time_zscore)
    if escalated:
        key = "anomaly.escalated"
    elif kind in ("rise", "drop"):
        key = f"anomaly.{kind}"
    else:
        key = f"anomaly.{sev}"
    slots = {"power": fmt_watts(power_avg),
             "baseline": fmt_watts(roll_mean_1hr) if roll_mean_1hr else ""}
    explain = anomaly_explain(kind, power_avg, roll_mean_1hr, time_zscore)
    data = {
        "severity":    sev,
        "kind":        kind,
        "log_ids":     list(event["log_ids"]),
        "event_start": event["start_ts"].isoformat(),
        "prompt_tl":   HITL_PROMPT,
        "options":     HITL_OPTIONS,
    }
    return _advisory("anomaly", key, slots, explain, data=data,
                     avoid_id=avoid_id, rng=rng)


def build_device_advisory(online: bool, since: Optional[datetime] = None,
                          timeout_s: int = 60, avoid_id: Optional[str] = None,
                          rng=random) -> dict:
    if online:
        adv = _advisory("device", "device.online", {}, "", avoid_id=avoid_id, rng=rng)
        adv["push"] = False
        return adv
    slots = {"since": fmt_time(since) if since else "kanina"}
    return _advisory("device", "device.offline", slots,
                     EXPLAIN["device"].format(timeout=timeout_s),
                     avoid_id=avoid_id, rng=rng)


def build_rate_change_advisory(comparison: dict, avoid_id: Optional[str] = None,
                               rng=random) -> Optional[dict]:
    """Household effect of this month's Meralco rates vs last month's.
    comparison comes from rate_compare.compare_with_previous() (billing side):
    {kwh, basis, bracket, prev_period: (y, m), cur_period: (y, m),
     prev_rate, cur_rate, prev_total, cur_total, diff_total}
    basis "so_far" = billed kWh this cycle; "projected" = calibrated month-end."""
    if not comparison:
        return None
    cy, cm = comparison["cur_period"]
    py, pm = comparison["prev_period"]
    diff = float(comparison["diff_total"])
    key = ("rates.flat" if abs(diff) < RATE_FLAT_PESO
           else "rates.up" if diff > 0 else "rates.down")
    projected = comparison.get("basis") == "projected"
    slots = {
        "month":      fmt_month(cy, cm, with_year=False),
        "prev_month": fmt_month(py, pm, with_year=False),
        "kwh":        fmt_kwh(comparison["kwh"]),
        "basis":      ("tinatayang konsumo mo ngayong billing cycle" if projected
                       else "nagamit mo na ngayong billing cycle"),
        "cur_total":  fmt_peso(comparison["cur_total"]),
        "prev_total": fmt_peso(comparison["prev_total"]),
        "diff":       fmt_peso(abs(diff)),
    }
    bracket = comparison.get("bracket", bracket_label(comparison["kwh"]))
    explain = EXPLAIN["rates"].format(
        month=fmt_month(cy, cm), prev_month=fmt_month(py, pm), kwh=slots["kwh"],
        bracket=BRACKET_DISPLAY[bracket],
        prev_rate=fmt_rate(comparison.get("prev_rate", 0)),
        cur_rate=fmt_rate(comparison.get("cur_rate", 0)),
        basis_note=("" if projected else
                    " Lalaki pa ang epektong ito habang dumarami ang nagagamit mo "
                    "hanggang ika-27."))
    return _advisory("rates", key, slots, explain,
                     data={"period": f"{cy}-{cm:02d}", "diff_total": round(diff, 2),
                           "basis": comparison.get("basis", "so_far")},
                     avoid_id=avoid_id, rng=rng)


# =======================================================================
# LOGIC — CMS item text (GRID's own wording from extracted facts)
# =======================================================================

def build_cms_item_text(kind: str, source_title: str,
                        facts: Optional[dict] = None) -> dict:
    """Title and body for a CMS item. Uses only the source headline (quoted,
    attributed) and the numbers in `facts`; never Meralco's article body.
    Returns {title_tl, body_tl, template_id}."""
    facts = facts or {}
    if kind == "rate_change" and facts.get("rate_new") and facts.get("period_month"):
        y, m = int(facts["period_year"]), int(facts["period_month"])
        py, pm = prev_period(y, m)
        change = facts.get("change_per_kwh")
        if change is None and facts.get("rate_old"):
            change = float(facts["rate_new"]) - float(facts["rate_old"])
        change = float(change or 0.0)
        key = ("cms.rate.flat" if abs(change) < 0.00005
               else "cms.rate.up" if change > 0 else "cms.rate.down")
        typical = facts.get("typical_kwh")
        rate_new = float(facts["rate_new"])
        rate_old = float(facts["rate_old"]) if facts.get("rate_old") else rate_new - change
        slots = {
            "month":      fmt_month(y, m, with_year=False),
            "prev_month": fmt_month(py, pm, with_year=False),
            "rate_new":   fmt_rate(rate_new),
            "rate_old":   fmt_rate(rate_old),
            "change":     fmt_rate(change),
            "typical_sentence": (f" Batay ito sa bahay na gumagamit ng {int(typical)} kWh "
                                 f"kada buwan." if typical else ""),
        }
        title_slots = {"month": fmt_month(y, m)}
    else:
        key = {"advisory": "cms.advisory", "maintenance": "cms.maintenance"}.get(kind, "cms.news")
        slots = {"source_title": source_title.strip()}
        title_slots = {}
    body, tid = _realize(key, slots)
    return {"title_tl": TITLES[key].format(**title_slots), "body_tl": body,
            "template_id": tid}


def build_cms_published(item: dict) -> dict:
    """App-ready CMS item from a /cms/inbox record written by the notebook.
    Realizes GRID's Tagalog text here (templates live only on the VM) and adds a
    `card` the app draws from the facts when there is no image.
    kind "note" = GRID's own content: its title_tl/body_tl are used as written."""
    kind = item.get("kind", "news")
    facts = item.get("facts") or {}

    if kind == "note":
        text = {"title_tl": (item.get("title_tl") or "").strip(),
                "body_tl": (item.get("body_tl") or "").strip(),
                "template_id": None}
    else:
        text = build_cms_item_text(kind, item.get("source_title", ""), facts)

    card = {"icon": kind}
    if kind == "rate_change" and facts.get("rate_new"):
        change = facts.get("change_per_kwh")
        if change is None and facts.get("rate_old"):
            change = float(facts["rate_new"]) - float(facts["rate_old"])
        change = float(change or 0.0)
        card.update({
            "direction":   "flat" if abs(change) < 0.00005 else ("up" if change > 0 else "down"),
            "change_tl":   ("+" if change > 0 else "−" if change < 0 else "") + fmt_rate(change) + "/kWh",
            "rate_new_tl": fmt_rate(facts["rate_new"]) + "/kWh",
            "period":      (f"{int(facts['period_year'])}-{int(facts['period_month']):02d}"
                            if facts.get("period_month") else None),
        })

    source_name = item.get("source_name") or (None if kind == "note" else "Meralco")
    out = {
        "kind":           kind,
        "title_tl":       text["title_tl"],
        "body_tl":        text["body_tl"],
        "admin_note_tl":  (item.get("admin_note_tl") or "").strip() or None,
        "template_id":    text["template_id"],
        "source_name":    source_name,
        "source_title":   item.get("source_title"),
        "source_url":     item.get("source_url"),
        "source_date":    item.get("source_date") or facts.get("published"),
        "attribution_tl": (f"Pinagmulan: {source_name}. Basahin ang buong detalye sa "
                           f"kanilang website." if item.get("source_url") else
                           "Mula sa GRID team."),
        "image_url":      item.get("image_url"),
        "image_credit":   item.get("image_credit"),
        "pinned":         bool(item.get("pinned", False)),
        "published_at":   item.get("approved_at") or item.get("created_at"),
        "card":           {k: v for k, v in card.items() if v is not None},
    }
    return {k: v for k, v in out.items() if v is not None}


def fmt_span(start: datetime, end: datetime, today) -> Tuple[str, str]:
    """(when, span) for a past event, e.g. ("kahapon", "kahapon, 8:55 PM–9:05 PM").
    `today` is a date in the same timezone as start/end."""
    d = start.date()
    if d == today:
        when = "ngayong araw"
    elif d == today - timedelta(days=1):
        when = "kahapon"
    else:
        when = f"{MONTHS_TL[d.month - 1][:3]} {d.day}"
    times = f"{fmt_time(start)}–{fmt_time(end)}"
    return when, (times if when == "ngayong araw" else f"{when}, {times}")


def event_status(last_ts: datetime, now: datetime,
                 closed_at: Optional[datetime] = None) -> str:
    """"closed" once no flagged reading has arrived for ANOMALY_EVENT_GAP
    (or the close job already marked it), else "open"."""
    if closed_at is not None or now - last_ts >= ANOMALY_EVENT_GAP:
        return "closed"
    return "open"


def is_quiet_event(severity: str, readings: int) -> bool:
    """A one-reading mild blip gets a card but no push (avoids prompt fatigue)."""
    return severity in QUIET_SEVERITIES and readings <= 1


def build_anomaly_review(event_id: int, peak_power: float, baseline_1hr: Optional[float],
                         peak_z: Optional[float], start: datetime, end: datetime,
                         today, status: str = "closed",
                         event_kwh: Optional[float] = None,
                         event_cost_php: Optional[float] = None) -> dict:
    """Card for one anomaly event in the review list.
    open   -> present tense, no answer buttons (options = []).
    closed -> past tense with the time, the summary (minutes, kWh, ≈ pesos) and
              the three HITL answers. Wording is fixed per event_id.
    event_kwh: sum of the event's measured interval_kWh; event_cost_php: that
    energy priced by the billing side (main.py). Both are stated, not computed here."""
    sev = anomaly_severity(peak_z)
    kind = anomaly_kind(peak_power, baseline_1hr, peak_z)
    when, span = fmt_span(start, end, today)
    minutes = int((end - start).total_seconds() // 60)
    rng = random.Random(event_id)
    explain = anomaly_explain(kind, peak_power, baseline_1hr, peak_z)

    if status == "open":
        okey = "review.ongoing_drop" if kind == "drop" else "review.ongoing"
        message, tid = _realize(okey, {"start": fmt_time(start),
                                       "power": fmt_watts(peak_power)}, rng=rng)
        return {
            "status": "open", "severity": sev, "kind": kind,
            "title_tl": TITLES["review.ongoing"].format(start=fmt_time(start)),
            "message_tl": message, "summary_tl": None, "explain_tl": explain,
            "time_tl": f"mula {fmt_time(start)}", "template_id": tid,
            "prompt_tl": None, "options": [],
        }

    key = f"review.{kind}" if kind in ("rise", "drop") else f"review.{sev}"
    span_pp = span if when == "kahapon" else f"noong {span}"   # "kahapon, …" / "noong 8:55 PM–…"
    message, tid = _realize(key, {"span_pp": span_pp, "power": fmt_watts(peak_power),
                                  "baseline": fmt_watts(baseline_1hr) if baseline_1hr else ""},
                            rng=rng)
    summary = None
    if event_kwh is not None and event_kwh > 0:
        cost_part = (f" (humigit-kumulang {fmt_peso(event_cost_php)} sa kasalukuyang rate)"
                     if event_cost_php is not None and event_cost_php > 0 else "")
        summary, _ = _realize("review.summary", {"minutes": minutes, "kwh": fmt_kwh(event_kwh),
                                                 "cost_part": cost_part}, rng=rng)
    return {
        "status":      "closed",
        "severity":    sev,
        "kind":        kind,
        "title_tl":    TITLES[key].format(when=when),
        "message_tl":  message,
        "summary_tl":  summary,
        "explain_tl":  explain,
        "time_tl":     f"{span} ({minutes} minuto)",
        "template_id": tid,
        "prompt_tl":   HITL_PROMPT,
        "options":     HITL_OPTIONS,
    }


def build_review_push(events: List[dict], today) -> Optional[dict]:
    """ONE push for events that just closed and still need an answer.
    events: [{event_id, start, end, severity, readings}] (already closed, not yet
    notified). Quiet one-reading blips are left out; several events = one bundled
    push. Throttling (REVIEW_PUSH_COOLDOWN) is decided by main.py with push_allowed."""
    loud = [e for e in events if not is_quiet_event(e["severity"], e["readings"])]
    if not loud:
        return None
    if len(loud) == 1:
        e = loud[0]
        when, span = fmt_span(e["start"], e["end"], today)
        span_pp = span if when == "kahapon" else f"noong {span}"
        minutes = int((e["end"] - e["start"]).total_seconds() // 60)
        adv = _advisory("review", "review_push.one", {"span_pp": span_pp, "minutes": minutes},
                        data={"event_ids": [e["event_id"]]})
    else:
        adv = _advisory("review", "review_push.many", {"n": len(loud)},
                        data={"event_ids": [e["event_id"] for e in loud]})
    return adv
