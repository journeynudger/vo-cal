# Phase G — Weekly Check-In

> Status: Queued (blocked on Phase E + Phase F)
> Owner: @lorenzo
> Branch: `phase-g-weekly-checkin`
> Next: G0

## Goal

P0 item 9: a simple weekly form (weight trend, hunger, energy, adherence, free text) that produces a concrete recommendation — usually a protocol adjustment with its "why" — closing the loop that makes the protocol feel alive rather than a one-time PDF. Accepted adjustments create a new protocol version (immutable versioning, F-engine recomputed). Touches: `apps/ios/VoCal/Views/CheckIn/`, `services/api/src/api/checkin/`, `protocols/`.

## Decisions locked

- **Deterministic recommendation core, AI phrasing** (same split as F3/F4): weight-trend-vs-goal-rate + adherence + hunger drive a rule table (hold / adjust kcal ±100–200 / adjust expectations / flag for coach conversation); Claude phrases it; it cannot invent an adjustment the rules didn't produce.
- **Check-in due = 7 days after protocol activation, then weekly.** Surfaced as a banner card on Today. **No push notifications in P0** — push infra is real scope; the concierge beta can prompt by text message. (Flagged delta; revisit post-beta.)
- **Weight is self-reported in the check-in** — no HealthKit in P0 (out-of-scope discipline; HealthKit adds privacy-form scope Phase I doesn't need).
- **Protocol versions are immutable rows** — accepting a recommendation creates v(n+1) with `supersedes` FK; Today reads the active version; history visible on the protocol screen.

## Context

Needs F (protocol versioning, engine) and E (Today banner placement, logged-meal data for adherence). Adherence is computed from actuals: logged days / 7 and avg kcal vs target from `meal_logs` — the check-in form pre-fills what the system already knows and only asks what it can't know.

---

## Tasks

### G0. Check-in schema + recommendation engine

- [x] **Step 1.** `checkin/router.py` + store: `POST /checkins` (weight, hunger 1–5, energy 1–5, adherence self-rating, free text; server attaches computed adherence: logged-days, avg kcal/protein vs target for the week), `GET /checkins` history, `GET /checkins/due` (due-state logic: 7 days post-protocol-activation, weekly cadence).
- [x] **Step 2.** `checkin/recommend.py` — rule table mapping (weight Δ vs expected rate, computed adherence, hunger, energy) → recommendation type + magnitude; Claude phrases the recommendation + why (tool-forced, F4 plumbing); deterministic fallback template.
- [x] **Test:** rule-table golden cases (on-track→hold; stalled cut + high adherence→ −150 kcal; stalled + low adherence→ adherence-first recommendation, no kcal change; rapid loss→ +kcal); due-date logic.
- [x] **Acceptance:** pytest green; recommendations never exceed rail bounds.
- [x] **Commit:** `feat(checkin): check-in endpoints + rule-based recommendation engine`

### G1. Check-in UI + protocol re-version

- [ ] **Step 1.** `Views/CheckIn/CheckInView.swift` — simple form per design grammar (one question per card: weight entry, hunger/energy selectors, adherence self-rating, free-text); pre-filled computed stats shown read-only ("You logged 6 of 7 days — avg 2,140 kcal").
- [ ] **Step 2.** Recommendation card (gold accent): the change + plain-English why; `Accept` → `POST /protocols/{id}/revise` creates v(n+1) via the F3 engine with the adjustment applied; `Keep as is` records the decline. Today targets update immediately on accept.
- [ ] **Step 3.** Today banner: "Weekly check-in ready" when due (E1 card slot); protocol screen shows version history.
- [ ] **Acceptance:** complete check-in → recommendation → accept → Today rings reflect new targets; declining records and clears the banner for the week.
- [ ] **Commit:** `feat(ios): weekly check-in flow + protocol versioning`

### G2. Check-in metrics

- [ ] **Step 1.** Events: `checkin_due_shown`, `checkin_completed`, `recommendation_accepted/declined` → client-metrics pipeline; add a check-in completion row to `scripts/beta-metrics` (retention diagnostic).
- [ ] **Acceptance:** events visible for a test user's full check-in cycle.
- [ ] **Commit:** `feat(metrics): check-in funnel events`

---

## Exit Criteria

- ✅ Due logic surfaces the check-in at the right time; form completes in under 2 minutes.
- ✅ Recommendation is rule-derived, rail-bounded, plainly explained; accept creates an immutable protocol v(n+1) live on Today.
- ✅ Check-in events flowing to beta-metrics.

## Amendments

*(none yet)*

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| G0 Schema + recommendation engine | done | backend-completion |
| G1 Check-in UI + re-version | not started | — |
| G2 Check-in metrics | not started | — |
