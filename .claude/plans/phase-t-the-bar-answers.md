# Phase T: The bar answers

> Status: Building 2026-10-04 (decision 71; Lorenzo: "it should respond when someone has a response and in that they could chat with it if they choose to but it more importantly shows them what they need via that chat").
> Owner: @lorenzo
> Branch: `claude/confident-volta-7er84f` (on top of Phases P to S)
> Next: T2
> Design: `docs/design/the-bar-answers-spec.md` (the Rams REVIEW of the ask and the design). Where this file and the spec differ, the spec wins.

## Goal

The capture bar is the one mouth. When a sentence through it is not food, the app answers with
the thing the person needed: the changed setting shown as Settings shows it, the Today card for
the number they asked about, the way to the surface that has it, or an honest no. A low-cost
model (`claude-haiku-4-5`) reads the sentence into a form; deterministic code applies it through
the stores Settings already writes; every line the person reads is in a catalog. No chat screen,
no transcript, no generated prose. The door stays open after the answer (a field and the mic),
nothing asks the person through it.

What does not move: the capture path (the parse stays first; the assistant runs only when no
food was found); the claim ladder ("Changed" from the server's echo alone); decision 67 (no
generated coaching text); the refused list (spec 5.9).

## Tasks

### T0. The spec and the decision

- [x] **Step 1.** `docs/design/the-bar-answers-spec.md`; decision 71 in memory; this plan; the master plan row.
- [x] **Commit:** `docs(design): the bar answers, under the Rams audit`

### T1. API: `POST /assist`

- [x] **Step 1.** `tracking/router.py`: `apply_update(db, user_id, req)` factored out of `put_tracking` (one merge, two callers). `meals/router.py`: `today_for(db, user_id, day, tz_zone)` factored out of `today()` (one composition, two callers).
- [x] **Step 2.** `assist/schemas.py`: `AssistTurn`, `AssistRequest` (text, thread of at most six, date, tz), `Intent` (the form), `AssistChange`, `AssistPointer`, `AssistUndo`, `AssistReply` (kind in changed, shown, pointed, told, meal; line; one of change, panel, pointer; undo; the app's turn). `assist/lines.py`: the catalog (spec 5.5) and the anatomy test's subject.
- [x] **Step 3.** `assist/llm.py`: `AssistClient` protocol; `AnthropicAssistClient` (the parser client's shape: lazy SDK, cached system prompt, forced tool, `settings.assist_model`); `RulesAssistClient` (keyword rules over the same form); `get_assist_client()` (rules under `test_mode` or without a key). `config.assist_model`.
- [x] **Step 4.** `assist/apply.py`: intent to effect and reply (spec 5.4): the tracking merge, the reactions by subject (catalog categories), the Today card by metric, the pointers, the mode rule (no number in habits), "already so", undo. `assist/router.py`: `POST /assist`; `main.py` mounts it. Logs carry the kind only.
- [x] **Test:** `tests/test_assist_api.py`: auth; each intent on the rules (mode with undo, focus, level, anchor with its slots, frictions, mute by subject with the reaction rows and undo, unmute, show protein as the five's panel, show in habits as the line, a metric not on Today, each pointer, meal, other); the thread resolves a follow-up; the message builder alternates roles and ends on the person; the catalog's anatomy; the wire shape additive. `test_today_api.py` and `test_tracking_api.py` unchanged and green.
- [x] **Commit:** `feat(api): the bar answers` *(974 passed, ruff clean)*

### T2. iOS: the answer surface

- [ ] **Step 1.** `Services/AssistModels.swift` (tolerant decode; `TrackingUpdate` becomes `Codable` for the undo); `APIClientProtocol.assist`, `APIClient.assist` (`POST /assist`); `MealCaptureService.answer(_:thread:)`: live through the client with the day and the zone, mock through `MockAssistant` (the rules twin, applying to `MockTrackingService` and drawing the panel from `PanelComposer`).
- [ ] **Step 2.** `VoiceLogState.answered(AnswerContext)`. `VoiceLogViewModel`: the parse's 422 and the empty parse (typed and voice paths) go to `answer(_:captureID:)` through the same working surface; `undoAnswer()` through the tracking service and `NudgeCenter.react`; `sayMore(_:)` keeps the thread and reopens the door; `cancel()` forgets the thread; a voice request records the capture as finished for Today's list.
- [ ] **Step 3.** `Views/VoiceLog/AssistReplyView.swift` (spec 5.2 and 5.6): the quote, the line, the one thing (`SettingsRow`, `PanelView`, the pointer row), Undo, the field and the mic, Close; swipe to close with the `select` tick, long-press Undo, `success` only on a landed change. `VoiceLogView` renders the state, `onOpen` for the pointers; `AppRootView` opens Settings for them. `A11y.VoiceLog` ids.
- [ ] **Test:** render tests: the answer with a change row and Undo, the answer with the protein card, the honest no; the rules twin (`MockAssistant`) for each kind; the tolerant decode (an unknown kind draws the line alone).
- [ ] **Commit:** `feat(ios): the bar answers`

### T3. Docs and ship

- [ ] **Step 1.** `docs/ARCHITECTURE.md` (the assist row), `docs/DESIGN.md` (the voice log's answer surface, the gestures table, a dated section), `docs/UI_VERIFICATION.md`, `docs/CAPTURE_LIFECYCLE.md` (a request is not a capture; a voice request is a finished one), `apps/ios/AGENTS.md`, `services/api/AGENTS.md` (the seam), the handoff (Phase T, the first run), memory; PR body; CI green.
- [ ] **Commit:** `docs: the bar answers`

## Exit Criteria

The spec's ship gate (section 6).

## Progress log

| Task | Status | SHA |
|---|---|---|
| T0 Spec | done 2026-10-04 | 3afc28e |
| T1 API | done 2026-10-04 | this commit |
| T2 iOS | | |
| T3 Docs | | |
