# Beta Feedback — 2026-08-19 (Lorenzo dogfood batch 1)

> Status: Active
> Owner: @lorenzo
> Branch: feature/beta-feedback-aug19
> Next: R1

## Goal

First real dogfood feedback from TestFlight build 23/24. Seven items: two visual bugs/polish (overlay collision, harsh error screen), one color-semantics change (weekly bars), one trust audit (protocol numbers look wrong: 120g protein "minimum", flat 2000 kcal), and three capability gaps (append to an existing meal by voice; one-tap "usuals" re-log; browse history further back). Touches `apps/ios/VoCal/Views/`, `Sources/VoCalCore`, `services/api/src/api/{meals,protocols}`. The through-line: keep the log → trust loop tight — every fix either removes friction or removes a reason to doubt the numbers.

## Decisions locked

- **Status colors (2026-08-19, Lorenzo):** weekly bars read gold = on the way / under, green = goal met, red = over. Requires two new theme tokens (`success`, `alert`) — palette amendment recorded in `docs/DESIGN.md` + `decisions.md` (#45). Gold stays brand accent; green/red are *status* semantics, never macro colors.
- **Errors are outcomes, not catastrophes (2026-08-19, Lorenzo):** parse-failure UI gets calm on-palette treatment; raw error codes come off the primary surface (stay in debug-events.jsonl). Facts-first claims unchanged — we never soften *what* happened, only how it looks.
- **Append is a new capture, not an edit of one (invariants):** adding food to a logged meal records a full capture → transcript → parse chain; only the derived `meal_logs` row gains items. Raw artifacts stay append-only.

## Context

Protocol math note: engine v2.0 golden test is green (`test_ip_worked_example_exact`), and no single input set produces BOTH protein-min 120g AND target 2000 kcal under v2.0 — Lorenzo's stored protocol likely predates the current engine or shows a fallback. R3 must find which, then make recovery obvious (profile edit → rebuild exists in build 24).

---

## Tasks

### R0. Weekly bar status colors (delegated: sonnet)

Swap the ink-opacity scheme for status semantics per Lorenzo's direction.

- [x] Status tokens: consolidated instead of grown — incumbent `optimal` green (#4F9D69) covers "goal met"; new `alert` red (#B5443A) covers over/escalation/destructive and absorbed the near-duplicate `danger`
- [x] `WeekStatusStyle.barFill`: inProgress → gold, under → gold 0.55, onTarget → optimal, over → alert; notLogged/upcoming unchanged
- [x] Foot label + carry chip + Today-card standing label recolored; legend derives from barFill
- [x] `docs/DESIGN.md` token table + amendment; `decisions.md` #45
- [~] **Acceptance:** `bin/ios-app-build` zero warnings ✓; sim screenshot pending (final sim pass)
- [x] **Commit:** `feat(ios): weekly bars read gold/green/red by status`

### R1. Capture overlay collision — "Logging to <date>" pill vs status toast

When logging to a past day, the date chip and the Saved/status note render on top of each other (screenshot evidence, build 23).

- [x] Root cause: date chip lived in a screen `.overlay(alignment: .top)` at 48pt while the Saved/Saving tag was each surface's first VStack child at ~56pt — two uncoordinated top-center anchors. Fix: one top overlay stack (`targetDayChip` + new `commitStatusTag`), tags stripped from `processingSurface`/`enhancingSurface`; claim-ladder licensing moved verbatim (receipt-gated)
- [~] **Acceptance:** sim run logging to a past date shows chip and status stacked cleanly (final sim pass)
- [x] **Commit:** shared with R2 (same file, one editing pass): `fix(ios): voice-log top stack + calm failure states`

### R2. Parse-failure state redesign (professional, calm)

Replace the red-exclamation full-screen with an on-palette outcome state: ink/gold, muted glyph, honest copy ("Couldn't find food in that — your recording is safe"), Try again primary, Close secondary, no raw `parse_422` on screen.

- [x] `failureSurface` redesigned: muted glyph on card circle (was protein-red exclamation — a macro-token misuse), diagnostic code carried in state but not rendered, transcript echoed on parse failures ("You said …") so rephrasing beats blind retry
- [x] `.failed` gained `transcript:`; parse-stage failures pass it; `stalledSurface` escalation now `alert` (doctrine-required unmistakable, but not protein red)
- [~] **Acceptance:** no-food parse on sim reads calm + shows transcript (final sim pass)
- [x] **Commit:** shared with R1: `fix(ios): voice-log top stack + calm failure states`

### R3. Protocol trust audit — the 120g / 2000 kcal question

Find why Lorenzo's protocol shows a flat 2000 kcal and a "minimum"-framed 120g protein; make protein read as a range; make recalibration obvious.

- [x] **Verdict:** engine v2.0 is correct (golden tests green; skill cross-check matches). The 2000/120 is `STUB_TARGETS` (`meals/today.py`) served when NO active protocol row exists — and the Home screen was the one surface that never read `targets_are_stub`. Protein range UI already ships (band bar) once real targets flow.
- [x] **Class fix (API):** interrupted supersede converges — `get_active` self-heals zero-active by re-activating the newest row (level-triggered, INVARIANTS §9); supersede compensates on insert failure; `/meals/today` reads via the store so the heal covers the dashboard; unique-index mirror extended to updates in both backends. +5 tests (630 green).
- [x] **iOS:** Today shows a "You're on starter targets" banner (tap → Profile editor sheet) whenever stub targets are in play; Profile editor's "No profile yet" dead end is now a seeded build-from-scratch path ("Build my protocol"); intake write no longer fire-and-forget (drift bug); sex default hardened to empty per the 2026-07 field bug pattern.
- [~] **Acceptance:** check-api + ios-app-build green ✓; sim verify pending (final pass)
- [x] **Commit:** `fix: stranded protocols converge; starter targets declare themselves`

### R4. Add to an existing meal by voice (flagship)

Open a logged meal → "Add more" mic → capture → parse → items append to THAT meal. Kills the delete-and-redo workflow.

- [x] API: `POST /meals/{id}/append` — server re-resolves the merge (manual items trusted, composition runs over BOTH utterances' transcripts sentence-joined), recomputes totals/confidence, idempotent by the appended parse (items stamped `appended_from_parse`), `item_appended` corrections rows are the durable audit, tombstoned/foreign meals 404. 5 tests; 635 green.
- [x] iOS: "Add more by voice" row in LoggedMealEditView → full capture flow with `AppendTarget` (header "Add to Meal 2", CTA "Add to meal (N cal)", receipt "Added to Meal 2", save-as-usual hidden); detected water lands on the MEAL's day; Today rows pass their display name through.
- [x] Capture path untouched: append context rides only the confirm call, exactly like `targetDate` (capture/transcribe/parse identical either way).
- [x] **Acceptance (headless):** beef meal 215.5 cal → append rice → same meal, 2 items, 475.5 cal; replay idempotent; day view shows ONE meal; 1 audit row. Sim visual + 9/9 voice self-test in R8.
- [x] **Commit:** `feat(voice): append to a logged meal by voice`

### R5. Usuals — finish the planned one-tap re-log

`saved_meals` write path shipped; read path + chips UI never landed (phase-d plan promised it).

- [ ] API: `GET /meals/usuals` (list) + log-a-usual path
- [ ] iOS: usuals chips on the voice-log entry surface (pre-capture) for one-tap re-log; respects target date
- [ ] **Acceptance:** save a meal as usual, see it as a chip, one-tap log it to a chosen day
- [ ] **Commit:** `feat: usuals are one tap to re-log`

### R6. History — reach further back

WeekStrip hard-caps at 7 days back; server accepts any date. Add week paging (chevron back/forward through past weeks) reusing the existing Today rendering for any date.

- [ ] **Acceptance:** navigate 3+ weeks back on sim (seed user has history), meals render, logging targets that date
- [ ] **Commit:** `feat(ios): browse past weeks from Today`

### R7. Recalibration nudge (seasonal)

Protocol age > 90 days → gentle "Season's changed?" card linking to Profile edit. Realizes decision #37 lightweight; Lorenzo's quarterly idea.

- [x] Server decides: `protocols/staleness.py` (90-day threshold, tested), `/protocols/active` + generate/revise now carry `created_at` + `needs_recalibration` (same posture as `targets_are_stub`)
- [x] iOS: gold card in Settings (a screen you come to, not a feed — the Today nudge slot is dismiss-only essential-level wire contract, wrong fit); taps push the Profile editor; card clears itself once rebuilt (re-reads on nav pop)
- [x] 15 tests (staleness unit + route-level age flags); 650 API green; build zero warnings
- [~] **Acceptance:** mock path serves a 120-day-old protocol → card reachable on sim (final pass)
- [x] **Commit:** `feat: seasonal recalibration prompt when a protocol ages past 90 days`

### R8. Wrap: docs, verification battery, build prep

- [ ] Canonical docs updated (DESIGN.md done in R0; VOICE_CAPTURE/PARSER_CONTRACT only if contracts changed)
- [ ] Full battery: `scripts/check`, `bin/ios-app-build`, `bin/ios-sim-voice-test`, `scripts/parser-eval` if parser touched
- [ ] Merge to main; TestFlight bump prepared (publish only on Lorenzo's go)
- [ ] **Commit:** `chore: beta feedback batch 1 wrap`

---

## Exit Criteria

- ✅ All seven feedback items shipped or explicitly answered (protocol provenance)
- ✅ Voice self-test 9/9; zero-warning build; API tests green
- ✅ Lorenzo can: append to a meal by voice, re-log a usual in one tap, browse past weeks, see protein as a range, and never see a raw error code

## Amendments

*(none yet)*

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| R0 weekly bar colors | delegated, in flight | — |
| R1 overlay collision | not started | — |
| R2 parse-failure UX | not started | — |
| R3 protocol audit | recon done | — |
| R4 voice append | not started | — |
| R5 usuals | not started | — |
| R6 history paging | not started | — |
| R7 recalibration nudge | not started | — |
| R8 wrap | not started | — |
