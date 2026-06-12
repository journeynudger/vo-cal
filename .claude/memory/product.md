# Product

## Thesis

Vo-Cal is **not an effortless tracker — it's the accurate tracker for people willing to do the work.** Photos guess; voice knows: voice captures what a photo can't (beef fat ratio, cheese type, condiment amount, prep method). Weighing and knowing your food is table stakes; the edge is the **handoff** — a spoken, fully-specified meal becomes an accurate log faster than typing. Users voice every ingredient; a lingo tutorial teaches the speech patterns up front. Effort is required by design.

**The one thing this build must prove: people will log meals by voice and trust the output.** Every prioritization question resolves against that.

Two pillars: ① a real personalized protocol (activity, occupation, training, hunger history, the gray area — not just height/weight/age/sex); ② low-friction, high-accuracy voice meal logging.

## P0 scope → phases

1. Intake (F) · 2. Protocol + "why" (F) · 3. Voice capture, Serein port (C) · 4. Parser (B) · 5. Macros: USDA FDC + internal dictionary (B) · 6. Per-item confidence (B) · 7. ONE clarifying question, >75 kcal / >10g threshold (B engine, D UX) · 8. Today dashboard (E) · 9. Weekly check-in (G) · 10. Admin review panel (H).

**Out of scope — hard MUST NOT:** photo logging, social, payments/billing UI, branded/restaurant DB, gamification, text-search food logging.

## Phase status (canonical: `.claude/plans/MASTER-PLAN.md`)

All phases Queued; Phase A is first. Dependency spine: A → (B ∥ C) → D (thesis gate) → E; F after A anytime (D outranks it); G after E+F; H after D; I last → TestFlight.

## Beta gate (30-day concierge beta)

70% activation (intake+protocol) · 10+ meals in first 7 days · avg log <30s · correction rate <25% by week 2 · 50% D14 retention · 5 users @ $15–25/mo OR 1 coach @ $50–100/mo. Instrumentation: D4 (latency), E3 (`scripts/beta-metrics`), F6 (activation funnel), G2 (check-in), verified live in I7.

## The 6 screens

1. **Welcome** — "Photos guess. Voice knows." / CTA "Build my protocol" (F0)
2. **Intake** — 7-step multi-step, autosave-resume (F2)
3. **Protocol** — targets + whys + meal structure + behavioral rules + lingo tutorial (F5)
4. **Today** — cals/macros left rings, meals logged, avg confidence (E1)
5. **Voice log** — big mic → transcript → parsed cards → confidence → ≤1 question → confirm (D0–D3)
6. **Weekly check-in** — form + recommendation → protocol v(n+1) (G1)

Plus internal admin review panel (H, not user-facing).

## Open threads

- **Bundle ID / team / app-name availability** — placeholders `com.vocal.app` / "Vo-Cal" until I0 confirms against the Apple Developer account.
- **Parser model verdict** — Sonnet 4.6 vs Haiku 4.5 latency/accuracy decided by B7's eval; record in `decisions.md`.
- **Willingness-to-pay metric** — manual entry in `scripts/beta-metrics`; conversation guide lands in I7's runbook.
- **Deferred (post-beta candidates, not P0):** push notifications (check-in nudge via text message during concierge beta), lock-screen/Action-Button logging (re-port Serein intent + Live Activity), voice-captured intake answers, dark mode, HealthKit weight sync.
