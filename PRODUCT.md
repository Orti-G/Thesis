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
A mobile companion to the GRID device, a thesis-built whole-house power meter. The device streams live readings to Firebase; a backend forecasts end-of-month kWh and detects anomalies. The app shows live consumption, forecasts, anomaly alerts and advisories, and turns usage into an itemized Meralco bill (including a kWh/peso calculator against published rate schedules). Success: the household understands and can act on their consumption before the bill arrives.

## Positioning
Own sensor hardware plus ML forecasting and anomaly detection feeding live data into the app, rather than a manual bill calculator or utility-provided portal.

## Operating Context
Data comes from Firebase Realtime Database (`live_reading`, `forecast`, `meralco_rates`, `history/today`, `sync`) and a backend API (forecast, bill breakdown, calculator convert, history, anomaly logs, token registration). Rates come from Meralco rate-schedule PDFs named `MM-YYYY_rate_schedule.pdf`; there is no endpoint listing available schedules. Push notifications (Firebase Messaging) arrive on three channels: detected anomalies, Meralco tier-crossing warnings, and projected bill estimates.

## Capabilities and Constraints
- Screens: onboarding (with intro video), dashboard, billing, advisories, alerts, settings, disclaimer dialog.
- Billing has "End of Month" and "Current" modes, tier info, itemized breakdown, and a calculator accepting kWh or pesos for a chosen rate month.
- Settings hides a developer diagnostic mode, unlocked by tapping "About" repeatedly.
- Whole-house scope only: one meter on the main supply. No appliance-level monitoring, load disaggregation, or per-appliance cost. Generic advice that names appliance types is fine.
- Flutter app; Android is the target platform (iOS/web/desktop scaffolds exist but are incidental).
- Language: UI copy is English today. A Tagalog natural-language-generation module is planned but not built; text containers and layouts should tolerate longer Tagalog strings and generated copy.

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
