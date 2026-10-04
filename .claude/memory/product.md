# Product

## Thesis

**Follow your nutrition your way** (decision 56, 2026-10-04). The person says how they want to follow their nutrition (habits, calories, the method's five, macros; a meal plan once P8 ships) and the app shows only that: the intake, the dashboard, the result, the nudges and the protocol surface obey the choice. Voice stays the default way in: it captures what a photo can't (beef fat ratio, cheese type, condiment amount, prep method), and a spoken meal becomes an accurate log faster than typing. The earlier headline ("the accurate tracker for people willing to do the work") over-estimated how many people want to voice every ingredient after the first week.

**The one thing this build must prove: people will log meals by voice and trust the output.** Every prioritization question resolves against that.

Two pillars: ① a real personalized protocol (activity, occupation, training, hunger history, the gray area — not just height/weight/age/sex); ② low-friction, high-accuracy voice meal logging.

## P0 scope → phases

1. Intake (F) · 2. Protocol + "why" (F) · 3. Voice capture, Serein port (C) · 4. Parser (B) · 5. Macros: USDA FDC + internal dictionary (B) · 6. Per-item confidence (B) · 7. ONE clarifying question, >75 kcal / >10g threshold (B engine, D UX) · 8. Today dashboard (E) · 9. Weekly check-in (G) · 10. Admin review panel (H).

**Out of scope — hard MUST NOT:** social, payments/billing UI, branded/restaurant DB, gamification. (Photo logs and typed logs with search over what the person has logged are IN scope since 2026-09-24, decision 52; voice stays the default and the emphasized way in.)

## Phase status (canonical: `.claude/plans/MASTER-PLAN.md`)

Phases A–I are Done (TestFlight build 31, 2026-09-24; Phase U, the UX overhaul, shipped as build 30/31). Phase P (the personalized tracker) is Active. Open items live in `docs/restructure/04-findings.md` and `05-questions.md`. The concierge runbook (I7) and the client metrics producer (beta-gate numbers) are not built.

## Beta gate (30-day concierge beta)

70% activation (intake+protocol) · 10+ meals in first 7 days · avg log <30s · correction rate <25% by week 2 · 50% D14 retention · 5 users @ $15–25/mo OR 1 coach @ $50–100/mo. Instrumentation: D4 (latency), E3 (`scripts/beta-metrics`), F6 (activation funnel), G2 (check-in), verified live in I7.

## The 6 screens

1. **Welcome** — "Follow your nutrition your way." / CTA "Choose how I track" (F0)
2. **Intake** — the mode first, then the steps the mode needs (habits: five screens; the rest: twelve), autosave-resume (F2)
3. **Protocol** — targets + whys + meal structure + behavioral rules + lingo tutorial (F5)
4. **Today** — the server-composed panels of the person's mode (`PanelView`), meals logged, avg confidence (E1, P4)
5. **Voice log** — big mic → transcript → parsed cards → confidence → ≤1 question → confirm (D0–D3)
6. **Weekly check-in** — form + recommendation → protocol v(n+1) (G1)

Plus internal admin review panel (H, not user-facing).

## Open threads

- **Bundle ID / team / app-name availability** — placeholders `com.vocal.app` / "Vo-Cal" until I0 confirms against the Apple Developer account.
- **Parser model verdict** — Sonnet 4.6 vs Haiku 4.5 latency/accuracy decided by B7's eval; record in `decisions.md`.
- **Willingness-to-pay metric** — manual entry in `scripts/beta-metrics`; conversation guide lands in I7's runbook.
- **Deferred (post-beta candidates, not P0):** remote push (nudges are local notifications scheduled from `POST /nudges/plan`), lock-screen Live Activity (the Action button and Siri open a live capture since build 30), voice-captured intake answers, dark mode, HealthKit weight sync (Health is read for active energy only).
- **Direction decided (2026-10-04, decisions 56–64):** the headline is "Follow your nutrition your way." The person chooses how they want to follow their nutrition (habits, calories, the method's five, macros, a meal plan) and the intake, Today, the result, the nudges and the protocol surface show only that. Building under `.claude/plans/phase-p-personalized-tracker.md`; the design is `docs/design/personalized-tracker-spec.md`.

---

## 2026-06-18 — Cofounder call update (canonical: docs/PRODUCT_BRIEF.md)

The product is now **three pillars and nothing more** (Francesco, nutrition cofounder): (1) voice-first logging, (2) personalized protocol from a *deep human intake*, (3) **mid-week situational nudging** (his highest-rated). Thesis unchanged: collapse logging friction; what the app does NOT do matters as much as what it does (MyFitnessPal with ~10% of the surface).

- **Dashboard:** calories · protein · produce · fiber · water. Carbs/fat off by default; micro-tracking (sugar/sodium/...) opt-in via edit screen. No nagging.
- **Parser:** per-material-ingredient checks (not one-per-meal); dictionary gains variant families.
- **Protocol:** cal/kg of ideal body weight (24–29 fat loss), pluggable formulas pending Francesco's Notion (NDA); activity inferred not asked.
- **Nudging (Phase G reframed):** mid-week, situational, SMS/email delivery; productizes what Francesco does manually with Claude.
- **MVP adds:** text-search fallback; voice does not talk back. **Deferred:** photo, QR, the conversational "guide" AI.
- **GTM:** Francesco's ~2000 warm clients + referral (free 3mo for 2 referrals); coaches are the wedge.
- **OPEN — platform:** web-app MVP vs native iOS/TestFlight (decision #39). Backend serves both; native Serein port banked as production foundation. Awaiting Lorenzo + Francesco.
- **Naming:** call says "Vocal"; repo is "Vo-Cal" — unresolved.
