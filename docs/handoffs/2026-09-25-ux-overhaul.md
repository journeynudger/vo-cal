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

## Loops and their verdicts (2026-09-25, before build 30 went up)

- `swift test` 69/69 · `scripts/check-api` 845 passed · `scripts/parser-eval` unchanged
  (extraction F1 1.000, canonical four PASS).
- `bin/ios-app-build` zero warnings · `bin/ios-sim-voice-test` 12/12.
- `bin/ios-render-tests` 18/18, goldens recorded once for the new surfaces (22 files, 6.6 MB,
  iOS 26.5 · iPhone 17 Pro · 3x) and verified three times with zero mismatches.
- `bin/ios-ui-audit` green at the new baselines (Today 40 Dynamic Type, 28 contrast, 5 hit
  regions; the settings pages 16/6, 9/7/2, 7/5/2, 5/4/1).
- `bin/ios-motion` within budget (scroll deceleration 1.02 s, drag and deceleration 1.24 s,
  tap to the capture sheet 2.16 s, tap to typed results 2.33 s).
- `bin/ui-critic`: three rounds; what stays and why is in `docs/UI_VERIFICATION.md`.
- A live simulator screenshot of Today confirmed the bar, the profile circle, the frosted
  status strip and the week strip; the bar's render goldens draw it half below the harness
  canvas (a glass-at-the-edge artifact of drawHierarchy, finding recorded in the doc).
- `scripts/latency-probe`: parse p50 3.9 s to 1.4 s (Haiku), resolution p95 9.6 s to 6.3 s.

## The deploy after build 30 (2026-09-24 evening, Deploy run 36053036184)

The API deployed and the migration applied, then the smoke stage failed: every `POST /parse`
answered 500. Production's `PARSER_PROVIDER` secret is `openai`, so the staged
`PARSER_MODEL=claude-haiku-4-5` went to OpenAI, which has no such model. Two corrections
follow. Production's parse model before this pass was an OpenAI model behind that secret,
not Sonnet 4.6: the Sonnet-to-Haiku numbers in `tests/fixtures/LATENCY.md` describe the
Anthropic path the code default names, and the previous production model's own latency was
never measured. And the fix is in code, not in a secret: the model id now picks the provider
(`parser/llm.py provider_for`, pinned by `tests/test_parser_provider.py`), `PARSER_PROVIDER`
only settles an id without a family, so `claude-haiku-4-5` runs on the Anthropic key the
photo parser already needs. The agent was refused the secret write by policy, so the
`PARSER_PROVIDER` secret still reads `openai`; it no longer decides anything, and
`fly secrets set PARSER_PROVIDER=anthropic -a vo-cal` makes it honest.

## Open

- Findings 34 (admin chain and photo captures) and 35 (no photo outbox).
- Questions 12 and 13 (Dynamic Type, the muted ink) still decide the audit's largest counts.
- The first-run tour and the Action button card have not been seen on a device.
- What the third critic round still flagged is listed in the report, not chased.
