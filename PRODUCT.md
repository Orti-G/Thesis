# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users
Household members (Meralco residential customers) who open the app on their phone to see how much power their home is drawing, what this month's bill is heading toward, and whether anything abnormal is happening.

## Product Purpose
A mobile companion to a thesis hardware power meter. The meter streams live readings to Firebase; a backend forecasts end-of-month kWh and detects anomalies. The app shows live consumption, forecasts, anomaly alerts and advisories, and turns usage into an itemized Meralco bill (including a kWh/peso calculator against published rate schedules). Success: the household understands and can act on their consumption before the bill arrives.

## Positioning
Own sensor hardware plus ML forecasting and anomaly detection feeding live data into the app, rather than a manual bill calculator or utility-provided portal.

## Operating Context
Data comes from Firebase Realtime Database (`live_reading`, `forecast`, `meralco_rates`, `history/today`, `sync`) and a backend API (forecast, bill breakdown, calculator convert, history, anomaly logs, token registration). Rates come from Meralco rate-schedule PDFs named `MM-YYYY_rate_schedule.pdf`; there is no endpoint listing available schedules.

## Capabilities and Constraints
- Screens: onboarding, dashboard, billing, advisories, alerts, settings, disclaimer dialog.
- Billing has "End of Month" and "Current" modes, tier info, itemized breakdown, and a calculator accepting kWh or pesos for a chosen rate month.
- Flutter app; Android is the target platform (iOS/web/desktop scaffolds exist but are incidental).
- Thesis project; primary audience beyond households (e.g. panel evaluators) is not confirmed.

## Evidence on Hand
No testimonials, customer data or benchmarks exist in the repo; none should be invented.

## Product Principles
- Live truth first: show what the meter reports now before projections.
- Make money legible: translate kWh into pesos and tiers the household recognizes.
- Surface anomalies calmly and actionably, not alarmingly.
- Never present forecasts or rates as more certain than the data supports.
