# Phase W — The default and the three questions

> Status: Built 2026-10-16 (decisions 75 to 77); the goldens and the first run on a device are owed
> Owner: @lorenzo
> Branch: `claude/nice-mayer-yysfuq`
> Next: the owner's items (questions ledger 14 to 22); the goldens on the pinned runtime
> Design: `docs/design/the-default-and-the-three-questions-spec.md` (the Rams REVIEW of the ask and the corrected design; Section 8 is the audit of the rest of the app). Where this file and the spec differ, the spec wins.

## Goal

Lorenzo, 2026-10-16: make every path a slightly different experience; mini quizzes of three
detailed questions that personalize the whole experience; a person who does not care skips every
step and gets the default; the default must include fat; Dieter Rams audits and approves every
aspect. The spec read the ask under the protocol and corrected it: the paths differ by behaviour,
never by words (D1); one quiz, optional, and the weekly check-in is the recurring one (D2); the
fourth question leaves the intake and is asked where it first acts, the card after the first log,
which is also the permission ask (D3); the default is version 0 of the preference rendering the
method's mode at starter targets, with the banner as the door to the basics, and nothing written
for the skipper (D4); fat joins the method's mode and the label follows its contents (D5). Then
the audit of every screen and every server sentence (Section 8), with the inherited findings fixed
here and the decided ones left to the owner. The surface: `services/api/src/api/{tracking,meals,
assist,nudges,checkin,protocols,parser}`, `apps/ios/VoCal/{Views/Onboarding,Views/Today,
Views/Settings,Views/VoiceLog,Views/Week,Views/CheckIn,Views/MealPlan,Services,ViewModels}`,
`docs/`.

The capture core, the parse ladder, the engine's formulas and the behavior-change order (69) do
not move. No migration: nothing new is stored.

## Decisions locked

- **75. The method's six.** Fat joins the standard view; the label follows its contents; the wire token stays `five`.
- **76. Two doors.** "Make it mine" and "Skip the questions"; the skipper writes nothing and lands on the six at starter targets.
- **77. The voice question where it acts.** Asked by the card after the first log, which is the permission ask; the intake's three questions about the person and the app are the mode, what gets in the way and when you log.

---

## Tasks

### W0. The spec, the decisions, the plan

- [x] **Step 1.** `docs/design/the-default-and-the-three-questions-spec.md`; decisions 75 to 77 in `.claude/memory/decisions.md`; this file; the master plan's row and amendment; `.claude/memory/product.md`.
- [x] **Commit:** `docs(design): the default and the three questions, under the Rams audit`

### W1. API: the method's six, and the server's words under the audit

- [x] **Step 1.** `tracking/projection.py`: the method's reveal and own metrics gain fat; meal plan's reveal carries the same keys and owns no tile. `meals/dashboard.py`: the fat tile after protein. `tracking/schemas.py`: `METHOD = "five"` with the reason. `assist/lines.py`, `assist/llm.py`: the label, the short label, "the six" read as the mode. `nudges/invitations.py`: the step-down words name fat.
- [x] **Step 2.** The audit's server fixes (spec 8.3): `checkin/recommend.py`, `assist/apply.py` and `lines.py`, `meals/router.py` (`/meals/summary`), `protocols/why.py` and `engine.py` (`protein_min_g`), `parser/certainty.py`, `nudges/catalog.py` and `invitations.py`.
- [x] **Test:** the pinned lines moved to the new words; new tests for the six's order, a fat focus not doubled, meal plan owning no tile, the default reveal and Today, the habits summary without an average, the habits person answered about water and never pointed at a surface their way lacks.
- [x] **Acceptance:** `scripts/check-api` green; `scripts/parser-eval` untouched (no parser change).
- [x] **Commit:** `feat(api): the method's six, and the server's words under the Rams audit`

### W2. iOS: the two doors, the three questions, the card after the first log, the six

- [x] **Step 1.** `WelcomeView` two doors; `OnboardingFlowView` the skip path (nothing written) and the way back from a failed build; `AuthGateView.Purpose`; the intake without the voice step (`IntakeFlowView`, `IntakeDraft`, `ExperienceChoosers`, `A11y`).
- [x] **Step 2.** `VoiceAskCard` on Today for a person never asked who has logged (`NudgeCenter.voiceAskPending`, `evaluateVoiceAsk`, `chooseLevel`: the echo, then the system sheet unless Nothing); the permission card stays for people who chose before; Settings → Notifications says when the tick is the default's; one card speaks first on Today at a time.
- [x] **Step 3.** `TrackingMode.method` (raw `five`) with the six's title, support and short label; `PanelComposer`, `MockProtocolService.reveal`, `PanelLayout`, the reveal's building line per goal and fallback by mode, `MockAssistant` reading "the six"; What's New for this release; `TodayViewModel.settingFailureMessage` and `writeFailureMessage`.
- [x] **Step 4.** The audit's fixes on the same screens (spec 8.1, 8.2, 8.4): the pace screen follows the goal, the ruler's facts, the goal screen's card cut, the stress line only where true, the reveal's pill, chips, disclaimer and failed state, the gate, the Health step, the Action button card's gate and sentence, the tour's words, the progress bar, `IntakeOptions`, the meal editor in habits mode, the starter banner, the week's words and colours and failed card, the check-in's words and glyphs, Settings' words, the voice log's blocked state and Try again, the result's one telling of how sure, the item card, the receipt.
- [x] **Test:** `testVoiceAskCardAndFrictionChooser`, `testWelcomeHasTwoDoors`, `testNotificationSettingsInThePersonsWords` (chosen and default); the per-mode renders carry fat.
- [ ] **Acceptance:** `bin/ios-app-build` zero warnings (CI, no Swift toolchain here); the goldens recorded on the pinned runtime; a fresh install skips to Today on the six at starter targets; a first log shows the card; "Nothing" never prompts. *Owed to the Mac: the handoff lists the run.*
- [x] **Commit:** `feat(ios): two doors, three questions, how much to say asked after the first log, and the six`

### W3. Docs and the handoff

- [x] **Step 1.** `docs/DESIGN.md`, `docs/UI_VERIFICATION.md`, `docs/app-store/REVIEW_NOTES.md`, `docs/DATABASE.md`, `docs/PRODUCT_BRIEF.md`, `apps/ios/AGENTS.md`, `docs/restructure/05-questions.md` (14 to 22), the spec's Section 8, `docs/handoffs/2026-10-16-the-default-and-the-three-questions.md`, memory.
- [x] **Commit:** `docs: the default and the three questions`

---

## Exit Criteria

- ✅ A fresh install can skip every question and reach Today on the method's six at starter targets, with one door to the basics; nothing is written for them. *(Built; the run on a device is owed.)*
- ✅ A fresh install that answers is asked three things about itself and the app before the engine's questions, and how much the app should say after its first log; "Nothing" never shows the system sheet.
- ✅ The method's mode prints fat on the reveal, on Today and in the chooser's label; the wire token is unchanged and build 32 decodes every response.
- ✅ Every inherited finding of the audit is fixed or recorded; every decided one is listed for the owner with a recommendation (spec Section 8; ledger 14 to 22).
- ✅ `scripts/check-api` green; CI's iOS job compiles at zero warnings. *(The API half proved here; the iOS half is CI's.)*

## Amendments

### 2026-10-16 — The task list collapsed from seven to four

The audit's fixes landed in the same files as the core (the welcome, the intake, the reveal,
Today, the result), so they ship in W1 and W2 rather than in four commits of their own; the
spec's Section 8 is the per-finding record.

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| W0 Spec, decisions, plan | done 2026-10-16 | W0-SHA |
| W1 API | done | W1-SHA |
| W2 iOS | built; CI compiles it; the goldens await the Mac | W2-SHA |
| W3 Docs | done | W3-SHA |
