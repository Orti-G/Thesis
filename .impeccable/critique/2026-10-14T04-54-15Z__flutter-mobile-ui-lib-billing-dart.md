---
target: expanded tier cards overlay
total_score: 17
max_score: 40
na_heuristics: 
p0_count: 2
p1_count: 2
target_identity: "file:C:\\Users\\Lyndon\\Documents\\GitHub\\Thesis\\flutter_mobile_ui\\lib\\billing.dart"
target_fingerprint: "sha256:9c7af04f626872ca90662be1e56e09d8d5ed501829c732e07d0aacd0f0a7846b"
target_path: "C:\\Users\\Lyndon\\Documents\\GitHub\\Thesis\\flutter_mobile_ui\\lib\\billing.dart"
timestamp: 2026-10-14T04-54-15Z
slug: flutter-mobile-ui-lib-billing-dart
---
Critique of expanded tier cards overlay (billing.dart _openTierCardsHero ~2242-2414). Method: dual-agent. Score 17/40 = 42.5%, Poor. Resting stack out of scope.
P0: no framing (no title, kWh marker, marginal-rule explanation). P0: pager hides 3 of 4 tiers, neighbours peek ~10px, no indicator; vertical column of cards cannot fit. P1: Hero + unrelated fade, drag dismiss has no follow-the-finger feedback, no close control. P1: contrast ~2.4:1 / 2.0:1 on orange, 2.7:1 grey; no Semantics; fixed height clips at large text. P2: no entry affordance; fallback rates indistinguishable.
Suggested: clarify, layout, animate, colorize, adapt, polish.
