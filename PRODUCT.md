# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users
Household members (Meralco residential customers) who open the app on their phone to see how much power their home is drawing, what this month's bill is heading toward, and whether anything abnormal is happening.

- Several members of one household may watch the same GRID device, each from their own phone.
- That includes older or less tech-savvy members, often the person who actually pays the bill, who must understand screens without being walked through them.
- Phones are typically budget to mid-range Android devices.

The thesis panel evaluates the app as if it were shipping to households. Design for real household use; no demo-only affordances.

## Product Purpose
A mobile companion to the GRID device, a thesis-built whole-house power meter. The device streams live readings to Firebase; a backend forecasts end-of-month kWh and detects anomalies. The app shows live consumption, forecasts, anomaly alerts the household reviews, weekly advisories, Meralco news and tips, and turns usage into an itemized Meralco bill (including a kWh/peso calculator against published rate schedules). Success: the household understands and can act on their consumption before the bill arrives.

## Positioning
Own sensor hardware plus ML forecasting and anomaly detection feeding live data into the app, rather than a manual bill calculator or utility-provided portal.

## Operating Context
Data comes from Firebase Realtime Database (`live_reading`, `forecast`, `meralco_rates`, `history/today`, `sync`, `advisories/{bracket,cycle,daily,rates,weekly}` holding the latest backend advisory per category, and `cms/published` for the News & Tips feed) and a backend API (forecast, bill breakdown, calculator convert, history including `/history/weekly-comparison`, anomaly logs and events, anomaly reviews, token registration). Rates come from Meralco rate-schedule PDFs named `MM-YYYY_rate_schedule.pdf`; there is no endpoint listing available schedules. Push notifications (Firebase Messaging) arrive on three channels: detected anomalies, Meralco tier-crossing warnings, and projected bill estimates. Tapping an anomaly notification opens its review in Alerts.

Releases are built with `flutter_mobile_ui/tool/build.ps1`, which stamps the git commit count as the Android build number; the version name comes from `pubspec.yaml`. Settings shows the installed version and build.

## Capabilities and Constraints
- Screens: onboarding (with intro video), device setup, dashboard, billing, advisories, alerts, settings, disclaimer dialog.
- Device linking (MergedBLE branch, in progress): a household links the app to its GRID device by typing the device ID (`XXXX-XXXX`, alphabet without I, O, 0, 1) into eight code boxes, or by first-time Bluetooth setup. The ID is checked against Firebase (`devices/<ID>/sync` must exist) before anything is saved, so a typo is never remembered. Setup-mode devices advertise as `PROV_EM-XXXX`; the Wi-Fi setup flow (`lib/wifi_setup/`) sends Wi-Fi credentials over BLE and exchanges a setup ID with the device. Each install has a secret owner identity (setup ID, a UUID) that is never displayed or logged.
- Multi-device data scope: linked devices read from `devices/<id>/...` in the default Firebase project. A "legacy household" code (`LGCY-KR22`) keeps the original household, whose device has no ID, on the original Firebase project and backend at root paths, as the app always did. Screens build every Firebase path through `HouseholdScope`.
- Pilot mode: for linked devices, forecasts, bills and alerts need about a month of readings, so Billing is blurred behind a plain "Coming soon" message and Alerts shows the same message and pulls no anomaly data. Live usage and the hour-by-hour graph work from day one. The legacy household is never gated. A single flag turns this off when the features go live.
- Viewer presence: an open dashboard counts as one viewer on the GRID device's LCD (`devices/<id>/viewers/<session>`), using a random per-session ID, removed on disconnect.
- Remote reset: the owning install can send a reset command to its device through the backend `/command` route (needs a build-time `APP_API_KEY` from gitignored `secrets.json`); outcomes include queued, not owner, no owner, conflict, offline. Only the install that provisioned the device is allowed to reset it.
- Billing has "End of Month" and "Current" modes, tier info, itemized breakdown, and a calculator accepting kWh or pesos for a chosen rate month.
- Alerts lets the household review each detected anomaly event (with its chart) by picking one of the answers the backend offers, posted to `/anomaly-events/{id}/review`. Swiping an event away answers "unsure", with an Undo toast before the answer is sent.
- Advisories compares this week with last week, lists the backend's advisories (each with a "Bakit?" explanation), and has a News & Tips tab.
- Settings hides a developer diagnostic mode, unlocked by tapping "About" repeatedly.
- Whole-house scope only: one meter on the main supply. No appliance-level monitoring, load disaggregation, or per-appliance cost. Generic advice that names appliance types is fine.
- Flutter app; Android is the target platform (iOS/web/desktop scaffolds exist but are incidental).
- Language: the app's own UI labels are English. Backend-generated copy (advisory titles, messages and "Bakit?" explanations, rate-change cards, news items) arrives in Tagalog (`*_tl` fields) and is shown as sent, with one exception: Alerts rebuilds anomaly card titles and review answer labels in plain Tagalog from the stable `kind`, `severity` and `answer` values, because the backend's "Anomalya" titles confused households. Everything else is never rewritten. Text containers and layouts must tolerate longer Tagalog strings and generated copy.

## Brand Commitments
- The app is named **GRID**, shown without an acronym expansion. It was formerly KURO.
- The hardware is the "GRID device", never "GRID meter", so it is not confused with the Meralco utility meter.
- The Firebase project id `kuro-ec80f` is infrastructure, not branding, and must not be renamed.
- GRID is independent of Meralco and not affiliated with or endorsed by it (stated in the disclaimer dialog). Meralco appears only as the factual source of rates and billing rules.
- Thesis title shown in About: "Smart Household Electrical Monitoring System"; team credited there.
- Existing assets: `flutter_mobile_ui/assets/app_icon.png`, intro video `assets/grid_animation.mp4`, Lottie loaders and restart guides in `assets/`.

## Evidence on Hand
No testimonials, customer data or benchmarks exist in the repo; none should be invented.

## Product Principles
- Live truth first: show what the meter reports now before projections.
- Interpret, don't hide: pair raw readings (W, A, V, PF, Hz) with what they mean for the household, and keep the raw values available.
- Make money legible: translate kWh into pesos and tiers the household recognizes.
- Surface anomalies calmly and actionably, not alarmingly.
- Never present forecasts or rates as more certain than the data supports.

## Accessibility & Inclusion
- Plain language a non-technical, possibly older bill-payer understands on first read; technical units always get a household-terms explanation.
- Type must follow the system font-size setting without clipping.
- Must stay smooth on budget Android phones: heavy effects (blur, video, large Lottie files) need to stay cheap or degrade gracefully.
