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

## Build 31: what the phone found in build 30, and the fixes (2026-09-24 evening)

Lorenzo's device pass found six things every loop had missed, because no loop drove the bar.

- **The plus opened the week's budget.** Two causes, and the second was the one. A finger
  landing a few points above the 44 pt plus hit the week card or the unfinished row behind
  the bar (no dead zone; Serein's was cut in the port). And the plus itself took no touch:
  a `.glassEffect` contributes no hit region, so a glyph on glass is hittable only through
  what is drawn on it, and its hairline rim did not count; accessibility still reported it
  at its frame and activated it, so every hand check through the simulator tool passed
  while a touch on the plus was a touch on the week card. Bisected with a launch-argument
  variant switch under `CaptureFlowTests` (nine launches, repeats stable): a 1.5 pt rim
  takes the touch at any tint, a 0.75 pt rim and no rim do not, interactive or not. Serein's
  glass buttons carry `contentShape(Circle())`; the port dropped it. Now the glass modifier
  makes its shape the hit region for every surface, the plus is the mic's 56 pt twin with the
  same bright face, a 36 pt dead zone swallows a near miss, and the finding is written at
  `LiquidGlass.swift`. Findings 44 and 38.
- **The keyboard had no way out.** Serein's catchers were cut in the port: no tap on the page
  put the keyboard away, and the mark with nothing to send was disabled. Now the shell lays a
  catcher under the bar (a tap anywhere else closes the menu or puts the keyboard away), and
  the empty mark is "Done".
- **The bar is Serein's to the letter now.** Camera and Photos grow from the plus's droplet
  and own the row; composing is one card with the photo inside its top corner, the words
  beneath, the plus and the mark in its bottom corners; the shell presents the camera and the
  library, never the inset. `docs/DESIGN.md` "The bar, to the letter".
- **The mic jumped on "Listening".** Measured at 28 pt by the new flow test once the mic
  was reachable: the reserved Stop slot was an empty `Group`, which is no view, so the slot
  did not exist until Stop arrived and the spacers rebalanced. A clear view holds it now.
  Also: one branch and one identity for the three capture rungs, the ring animated in
  place, no repeat-forever pulse. Finding 45.
- **Calories and protein are twins:** title, a 40 pt numeral, a bar, one line, one height.
- **The Action button card** sits on the page above the bar, on its own frost, never inside
  a sheet. Later stays.
- **Usuals are renamed the way meals are:** press and hold a chip, Rename, the same alert;
  `PATCH /meals/usuals/{id}/name`, 409 when another usual carries the name.
- **The loop that was missing:** `bin/ios-flow-tests` drives the bar and the capture's first
  seconds on the real app, in CI's iOS job. It asks only what is objective: keyboard out on a
  page tap and on the empty mark, menu open and closed, a near miss that opens nothing, and
  the mic's centre sampled through the start, moving under a point. It taps by synthesized
  touch, never by accessibility activation, because that is the difference that hid the
  plus for a build.

### Loops and their verdicts for build 31 (2026-09-24 evening)

- `swift test` 69/69 · `scripts/check-api` 859 passed (the usual rename's tests among them) ·
  `bin/ios-app-build` zero warnings.
- `bin/ios-flow-tests` 5/5 on the pinned simulator: the keyboard out on a page tap and on the
  empty mark, the menu open and closed by touch, a near miss that opens nothing, the mic's
  centre sampled through Starting and Listening within a point.
- `bin/ios-render-tests` re-recorded once (the bar's five states, Today's cards, the tour's
  Today, the coach card: all changed by design) and verified green: 21 goldens.
- `bin/ios-motion` within budget: scroll deceleration 1.04 s, drag and deceleration 1.26 s,
  tap to the capture sheet 2.16 s, tap to typed results 2.35 s.

## Open

- Findings 34 (admin chain and photo captures) and 35 (no photo outbox).
- Questions 12 and 13 (Dynamic Type, the muted ink) still decide the audit's largest counts.
- The first-run tour and the Action button card have not been seen on a device.
- What the third critic round still flagged is listed in the report, not chased.
