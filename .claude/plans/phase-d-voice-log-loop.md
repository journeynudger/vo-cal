# Phase D — Voice Log Loop End-to-End (The Thesis)

> Status: Queued (blocked on Phase B + Phase C)
> Owner: @lorenzo
> Branch: `phase-d-voice-log-loop`
> Next: D0

## Goal

The screen the product lives or dies on: big mic → speak → transcript → parsed food cards → macros + confidence → at most one clarifying question → edit/confirm → saved meal, in under 30 seconds, with honest states under every failure. This is the thesis gate — **do not start Phase E polish until this phase's exit criteria pass on a real device.** Every parsed-vs-confirmed divergence is captured as training data. Touches: `apps/ios/VoCal/Views/VoiceLog/`, `ViewModels/`, `Services/`, `services/api` metrics ingestion.

## Decisions locked

- **UI states are projections of the claim ladder, never optimistic flags.** "Listening" renders only on `confirmed_listening` (byte-flow proof). "Saved" renders only against a `LocalCommitReceipt`. "Logged" renders only after the server confirms the meal_log row. Phase C's types make lying a compile error — keep it that way.
- **One question, one sheet.** The clarifying question is a single bottom sheet with quick-answer chips. Skipping is allowed and logs at stated confidence. No question chains.
- **Result delivery by polling** `GET /captures/{id}/result` (Beacon's no-WebSockets convention, ~1.5s interval with backoff). Revisit only if measured latency threatens the 30s target.
- **Corrections are field-level and silent.** The user just edits; the diff parsed-vs-confirmed is computed and persisted by the client+API without any "you corrected the AI" ceremony.
- **Layout follows the Create Meal screenshot:** calories card with flame icon + large numeral, P/C/F chip row, meal-items list with per-item delete, black pill confirm CTA.

## Context

Consumes Phase B endpoints (`/parse/refine`, `/meals`) and Phase C capture + result pipeline. Services follow Beacon's protocol+mock pattern so every screen state is reachable in UITestMode without a backend. Read `docs/VOICE_CAPTURE.md` before touching any state in this phase.

---

## Tasks

### D0. Voice log screen — capture states

The mic surface, claim-ladder-honest from the first build.

- [ ] **Step 1.** `Views/VoiceLog/VoiceLogView.swift` — full-screen capture UI: oversized mic button (black, gold ring when live), state-driven copy (`Hold on…` on accepted → `Listening` on confirmed_listening → elapsed timer + level meter), stop button, cancel. Permission-denied state routes to Settings deep-link.
- [ ] **Step 2.** `ViewModels/VoiceLogViewModel.swift` (@Observable) — projects `VoiceCaptureCoordinator` snapshots into a typed `VoiceLogState` enum (idle / arming / listening(elapsed) / stalled / blocked(reason) / sealing / saved(receipt) / processing / result / failed). No boolean soup.
- [ ] **Step 3.** Stall + interruption surfaces: stall escalates from peripheral hint to centered alert (Serein failure-priority doctrine); interruption shows pause-and-seal state with explicit resume affordance and the 5-min auto-finalize countdown honest in copy.
- [ ] **Acceptance:** sim self-test scenarios drive every visual state; "Listening" provably gated on byte-flow milestone in `debug-events.jsonl`.
- [ ] **Commit:** `feat(ios): voice log capture screen with claim-ladder states`

### D1. Processing + result UI

From "Saved" to seeing your meal.

- [ ] **Step 1.** Processing state: capture saved chip (honest: "Saved — analyzing…"), polling `MealCaptureService` (protocol + mock) against `/captures/{id}/result`; skeleton cards while waiting (Cal AI "You can switch apps…" tone for the reassurance line, minus the notify promise — no push in P0).
- [ ] **Step 2.** Result layout per the Create Meal screenshot: editable meal name, calories card (flame icon, 48–64pt numeral), Protein/Carbs/Fats chip row with semantic colors, `Meal Items` list — each item: name, amount+unit, per-item kcal, `ConfidenceBadge` (gold scale), delete (trash) affordance.
- [ ] **Step 3.** Transcript drawer: collapsed single-line transcript above the items, expandable — the user can always see what Vo-Cal heard (trust mechanics: provenance visible).
- [ ] **Acceptance:** mocked parse renders the canonical "Chipotle bowl" as 5 item cards with macros and confidence; UITestMode reaches this screen with zero network.
- [ ] **Commit:** `feat(ios): parse result UI with per-item confidence + transcript provenance`

### D2. Clarifying question sheet

P0 item 7's UX half.

- [ ] **Step 1.** `Views/VoiceLog/ClarifyingQuestionSheet.swift` — bottom sheet presenting THE one question with quick-answer chips (e.g. fat-ratio presets 80/20 · 85/15 · 90/10 · 93/7), free-field fallback, and `Skip` (explicit: "log as-is at ~N% confidence").
- [ ] **Step 2.** Answer → `POST /parse/refine` → updated items/macros animate in place; confidence badge updates. Skip → proceed unchanged.
- [ ] **Step 3.** Question metadata (asked/answered/skipped, which field) rides into the metrics events — question precision is a beta-gate diagnostic.
- [ ] **Acceptance:** "burger, unknown beef" fixture: sheet appears with fat-ratio chips; answering 93/7 updates kcal visibly; "93/7 stated" fixture: no sheet, straight to confirm.
- [ ] **Commit:** `feat(ios): single clarifying-question sheet with refine round-trip`

### D3. Edit, confirm, save-as-usual

The handoff: user authority over the final log, corrections harvested silently.

- [ ] **Step 1.** Per-item edit sheet: amount stepper + unit picker (contract enum), raw/cooked toggle, fat-ratio field, brand field, prep method; item delete. Add-item is NOT built (voice-only logging — re-record or accept; out-of-scope rule).
- [ ] **Step 2.** Confirm flow: black pill `Log Meal` → `POST /meals` with confirmed items; client computes field-level diff vs parse and sends it; API persists `corrections` append-only (B6). Meal-type selector (breakfast/lunch/dinner/snack) defaulted by time of day.
- [ ] **Step 3.** `Save as usual` toggle on confirm → `saved_meals`; a `Usuals` row (horizontal chips) appears on the voice-log entry screen for one-tap re-log (logs a copy referencing the saved meal — still a normal meal_log).
- [ ] **Acceptance:** editing 4oz→6oz then confirming produces a meal_log AND a corrections row (field=amount, 4→6); usual re-logs in one tap.
- [ ] **Commit:** `feat(ios): edit/confirm flow with append-only corrections + usuals`

### D4. Latency instrumentation (beta-gate wiring)

The <30s number, measured for real from day one.

- [ ] **Step 1.** Port Beacon's `MetricsCollector` → batched client events to `/metrics/client`: `log_duration_ms` (capture-stop → meal confirmed), `capture_to_transcript_ms`, `transcript_to_parse_ms`, `question_asked/answered/skipped`, `corrections_count`, `parse_confidence`.
- [ ] **Step 2.** Server: ingestion → `client_metrics` table + Prometheus histograms; `make metrics` TUI shows p50/p95 log duration.
- [ ] **Acceptance:** three test logs on device → `make metrics` displays real p50 log duration end-to-end.
- [ ] **Commit:** `feat(metrics): end-to-end log-duration instrumentation`

### D5. Failure-path UX

Honest states under every failure — the trust criterion in adversarial conditions.

- [ ] **Step 1.** Offline: capture saves locally, result screen replaced by honest "Saved on phone — will analyze when online" state; Today (Phase E) shows pending captures distinctly. On reconnect, processing resumes without user action.
- [ ] **Step 2.** Transcription/parse failure or `exhausted`: surface "Couldn't analyze — audio is safe" with retry affordance (re-enqueues server-side); never a dead end, never silent loss.
- [ ] **Step 3.** Server unreachable mid-confirm: confirmed meal queues locally and syncs (idempotent `POST /meals` by client-generated ID); UI distinguishes "logged (syncing)" from "logged".
- [ ] **Test:** XCUITest with mock services scripting each failure; manual airplane-mode pass on device.
- [ ] **Acceptance:** no failure path can show "Logged" without a server row or lose audio; every dead-end has a retry.
- [ ] **Commit:** `feat(ios): honest failure-path states for the voice log loop`

### D6. Loop UI test + thesis check

- [ ] **Step 1.** XCUITest: scripted golden path in UITestMode (canned transcript/parse via mocks) — mic → states → result → question → edit → confirm → corrections asserted.
- [ ] **Step 2.** Real-device thesis check, ≥10 real meals across messy speech: record per-log duration, corrections, question behavior into `.tmp/thesis-check.md`; file issues for anything that breaks trust (wrong "Listening", lost audio, lying states).
- [ ] **Acceptance:** 10/10 meals logged; median duration <30s; zero trust violations observed.
- [ ] **Commit:** `test(ios): voice-log loop UITest + thesis check record`

---

## Exit Criteria

- ✅ Real device: speak a fully-specified meal → confirmed log, median <30s across ≥10 real meals.
- ✅ Clarifying question fires only per threshold, answerable in one tap, skippable.
- ✅ Every parsed-vs-confirmed divergence lands in `corrections`; usuals work.
- ✅ Offline/failed/killed paths all converge with honest UI claims — no state lies, no audio loss.
- ✅ `make metrics` shows real p50/p95 log duration from device events.

## Amendments

*(none yet)*

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| D0 Capture states UI | not started | — |
| D1 Processing + result UI | not started | — |
| D2 Clarifying question sheet | not started | — |
| D3 Edit/confirm/usuals | not started | — |
| D4 Latency instrumentation | not started | — |
| D5 Failure-path UX | not started | — |
| D6 Loop UI test + thesis check | not started | — |
