# Handoff: the UX overhaul (2026-09-25)

For a session with no other context. Read `AGENTS.md`, then `docs/UI_VERIFICATION.md`, then
this. The plan with its ticks and amendments: `.claude/plans/phase-u-ux-overhaul.md`.

## What changed, in one breath

Every meal is named after what was eaten and the person can rename it; a renamed meal is a
usual and is recognized when logged again ("Is this your metal detox smoothie?"); the tab
bar is gone and one frosted capture bar takes voice (first), typed text (with search over
what was logged) and a photo (stored as a capture, read by the vision model, priced by the
ladder, its blind spots asked as checks); the week carries overages only; the parse runs
on Haiku 4.5 with prompt caching and the estimator has a clock; Today has one card
language, a frosted top, a profile circle, named rows that swipe; the first run has a tour,
an Action button card, What's New, Apple Health; Siri opens a live capture; every touch
answers. Decisions 50 to 54 in `.claude/memory/decisions.md`; findings 30 to 35 in
`docs/restructure/04-findings.md`.

## Server (services/api)

- Names: `meals/naming.py` (`auto_name`, `display_name`, `typed_name`; `name_source`
  auto | user | recognized). `PATCH /meals/{id}/name`. A meal-type word from any build is
  no name. Migration `20260925000001_meal_names_and_photo_captures.sql` (applied by Deploy).
- Recognition: `meals/recognition.py`; `recognized_meal` on `ParseResult`; confirm with
  `recognized_meal_id`. Candidates are usuals only.
- Search: `GET /meals/search?q=` (`meals/search.py`).
- Photo: `POST /parse/photo` (`parser/photo.py`, `capture-photos` bucket, `PHOTO_MODEL`
  default claude-sonnet-5); "None" to an amount question removes the item
  (`clarify.absence_index`).
- Latency: `WebGroundedEstimator` race (2 s alone, 6 s deadline, 10 s cap), prompt caching
  on the parse call, `parser_model` claude-haiku-4-5 (also staged as the Fly secret
  `PARSER_MODEL`). `scripts/latency-probe` and `tests/fixtures/LATENCY.md`.
- Week: `weekbudget/engine.py` carries overages only.

## App (apps/ios)

- The shell: `VoCalApp.swift AppRootView` (Today + `CaptureBar` as the bottom inset +
  `HelpTourOverlay`; covers for the voice log, a typed or photo submission, Settings;
  sheets for What's New and the Action button card; `PendingLaunchAction` for Siri).
- The bar: `Views/Capture/*` (Serein's port). Search through
  `ServiceCaptureSearchProvider`. A search hit logs by sending its name through the parse.
- Today: `CardHeader`, `StatCard` (one fill), `StatusBarFrost`, `ProfileCircleButton`,
  `SwipeableRow`, `WeekStrip` (three-letter days, no rings), rename alert, Health line.
- The result: `RecognizedMealCard`, numbers on `IngredientCheckCard`, no plus signs, the
  Save-as-usual row in the content, a tighter pinned bar.
- Typed and photo logs: `VoiceLogViewModel.startTyped/startPhoto`,
  `VoiceLogView(submission:)`; no commit tag without a capture.
- First run: `HelpTourKit`, `WhatsNewKit`, `ActionButtonSetupCard`, `HealthPermissionStep`
  (after the account), `HealthKitService`, `Intents/VoCalIntents.swift`.

## Loops and their verdicts

See the end-of-pass report and `docs/UI_VERIFICATION.md`. Goldens were re-recorded once
for the new surfaces after the outside critic's rounds; the audit baselines moved to the
new counts; the motion budget is set from the first run.

## Open

- Findings 34 (admin chain and photo captures) and 35 (no photo outbox).
- Questions 12 and 13 (Dynamic Type, the muted ink) still decide the audit's largest counts.
- The first-run tour and the Action button card have not been seen on a device.
- What the third critic round still flagged is listed in the report, not chased.
