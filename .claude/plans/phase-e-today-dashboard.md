# Phase E — Today Dashboard + Beta-Gate Metrics

> Status: Queued (blocked on Phase D)
> Owner: @lorenzo
> Branch: `phase-e-today-dashboard`
> Next: E0

## Goal

P0 item 8: the daily macro dashboard that makes logging feel rewarded — calories/protein/carbs/fat left against protocol targets, meals logged today, average confidence — in the exact layout of the Cal AI home screenshots (week strip, big calories-left card with ring, three macro rings, recent meals list). Plus the beta-gate reporting script: the six gate numbers computed from real data, cheap to run weekly. Touches: `apps/ios/VoCal/Views/Today/`, `services/api/src/api/meals/` (today aggregation), `scripts/beta-metrics`.

## Decisions locked

- **Targets come from the active protocol row; until Phase F lands, a stubbed default protocol** (via `MockProtocolService` + a seeded row) keeps this phase unblocked. The screen contract doesn't change when F arrives.
- **Day boundary is user-timezone-aware, computed server-side** in the `/today` aggregation — the client never does day math.
- **Pending (offline/processing) captures appear in the meals list as distinct "analyzing…" rows** — honest states extend to the dashboard.
- **Fiber is a secondary row, not a fourth ring** — protocol includes fiber, but the screenshot grammar is three rings; fiber shows under the rings as a small stat.

## Context

Consumes Phase D's logging flow and Phase B's `GET /meals?date=`. Layout reference: Cal AI home screens (week strip `W T F S S M T` with dotted selection, `Calories left` card with flame ring, three ring cards `Protein left / Carbs left / Fat left`, `Recently uploaded` list with thumbnail/name/time/kcal/macro chips — Vo-Cal swaps thumbnails for meal-type glyphs since there are no photos by design).

---

## Tasks

### E0. Today aggregation endpoint

- [x] **Step 1.** `meals/router.py` — `GET /today` → `{date, targets{kcal,protein,carbs,fat,fiber}, consumed{...}, remaining{...}, meals[{id,name,meal_type,logged_at,kcal,macros,confidence,state}], pending_captures[], avg_confidence}`. Targets from active protocol (stub-seeded until F); consumed from confirmed meal_logs; tz from profile.
- [x] **Test:** day-boundary cases (late-night logs, tz change), empty day, pending captures included.
- [x] **Acceptance:** pytest green incl. tz edges; response shape frozen in `VoCalCore` types.
- [x] **Commit:** `feat(api): /today aggregation with tz-aware day window`

### E1. Today screen UI

- [ ] **Step 1.** `Views/Today/TodayView.swift` — `WeekStrip` header (component from A3), `Calories left` StatCard (48–64pt numeral + `MacroRing` with flame glyph), three macro ring cards in a row (semantic colors, remaining values), fiber small-stat row, avg-confidence indicator (gold badge, "Avg confidence 91%").
- [ ] **Step 2.** Meals list ("Logged today"): meal cards with type glyph, name, time, kcal + P/C/F chips; pending captures render as skeleton rows with "analyzing…" (or "waiting for connection"); tap → meal detail (read-only result view reusing D1 components).
- [ ] **Step 3.** Empty state for a fresh day (gold-accent nudge toward the mic button); pull-to-refresh; floating mic button (from A3 shell) always reachable.
- [ ] **Acceptance:** UITestMode renders full, empty, and pending-mixed states pixel-consistent with `docs/DESIGN.md`; week strip date math correct across month boundaries.
- [ ] **Commit:** `feat(ios): Today dashboard (rings, remaining macros, meals list)`

### E2. Post-log return flow

- [ ] **Step 1.** Confirm in the voice loop (D3) dismisses to Today with the new meal animated in and rings updating (the reward beat). Past-day viewing via week strip taps `GET /meals?date=`.
- [ ] **Acceptance:** log → land on Today → rings visibly move; selecting yesterday shows that day's meals.
- [ ] **Commit:** `feat(ios): post-log return + week-strip day navigation`

### E3. Beta-gate metrics script

The six gate numbers, computed not estimated.

- [ ] **Step 1.** `scripts/beta-metrics` — queries Supabase and prints: activation % (intake+protocol completed / signups), users with 10+ meals in first 7 days, p50 log duration (from `client_metrics`), correction rate by user-week (corrected items / items, week-2 cohort), D14 retention (logged ≥1 meal day 14±2), and a placeholder row for willingness-to-pay (manual entry). One-shot table output + `--csv`.
- [ ] **Step 2.** Document in AGENTS.md commands; note the weekly cadence during beta.
- [ ] **Acceptance:** script runs against dev data and prints all six rows with real numbers.
- [ ] **Commit:** `feat(metrics): beta-gate reporting script`

---

## Exit Criteria

- ✅ Log a meal → Today reflects it immediately with targets-vs-consumed correct.
- ✅ Pending/offline captures visible and honest on the dashboard.
- ✅ `scripts/beta-metrics` outputs all six gate metrics from live tables.

## Amendments

*(none yet)*

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| E0 /today aggregation | done | backend-completion |
| E1 Today screen UI | not started | — |
| E2 Post-log return flow | not started | — |
| E3 Beta-gate metrics script | not started | — |
