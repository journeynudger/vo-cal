# Handoff, 2026-10-04: the personalized tracker, built on `claude/confident-volta-7er84f`

What this session built, what it proved, and what it could not prove from a Linux box with no
Xcode. Read with `.claude/plans/phase-p-personalized-tracker.md` (the plan, ticked) and
`docs/design/personalized-tracker-spec.md` (the Rams review and the corrected design).

## What landed (one commit per task, in order)

| Task | Commit | What it is |
|---|---|---|
| P0 | `c6e1626` | Decisions 56 to 64 taken as recommended; the brief, the master plan, memory. |
| P1, P2 | `ddd63cf` | `tracking_preferences` (append-only, RLS), the tracking domain, `tracking/projection.py` (the one place that says what a mode shows), `meals/dashboard.py` (the server composes Today's `panels`), `mode` on parse and generate, `reveal` on the protocol, the week plan's adjusted day on Today (D6). |
| P5, P6 | `76d7ded` | One nudge engine: the legacy bank's situational moves ported, every nudge naming its modes, the ladder as an invitation card with a permanent decline; the legacy endpoint deleted. |
| P7 | `38e9527` | Recalibration runs the v2.0 titration and revise recomputes the whole protocol. |
| P10 | `0356bed`, `4d166ad` | `GET /account/export` (JSON, CSV for meals); Settings → Export my record. |
| P3 | `9df077d` | Sugar and sodium as optional nutrients on the whole path, shown only on a focus tile. |
| P4 | `354546e` | The iOS half: the first question, the mode-aware intake and reveal, Today drawn from the server's panels, the mode governing every printed number, Settings → How I track, the invitation card's answers. |
| P9 | `f9a1b4f` | Every surface states the same headline. |
| P8 API | `808316c` | `meal_plans` (append-only versions, `author`), `GET/PUT /meals/plan`, `check_plan` (one line, the facts), `match_slots` (ticks by name, once, in logged order), the `meal_plan_slots` panel first on Today in meal-plan mode, the `plan_slot_open` nudge, export and deletion cover the table. |
| P8 iOS | `8170c88` | `PlanBuilderView` after the reveal, in Settings → My meal plan and from the plan card; the plan card in `PanelView` (full width, first); `MealPlanService` (live and mock); the chooser offers the meal plan; typed slots carry no name so the server names them as it names a typed log. |

## Phase Q, the same day: the onboarding that asks (decision 66)

| Task | Commit | What it is |
|---|---|---|
| Spec | `fcfcf02` | `docs/design/onboarding-that-asks-spec.md`: the Rams REVIEW of the conversation's proposal (the "worth it" question cut as a twin of the mode) and the corrected design: two questions after the mode, the copy of every intake screen, the states, the ship gate. |
| Q1 API | `37c2e1a` | `tracking_preferences` gains `nudge_level` and `frictions` (migration `20261004000003`, **Lorenzo or Deploy applies it**); `experience_for` says what they change; the nudge plan obeys the stored level over the request's; invitations only for "Coach me along the way"; the evening reminder for "I forget"; the amount bar for "Portions and amounts". |
| Q2 iOS | `18f3aa8` | `VoiceChooser`, `FrictionChooser` after the mode; the copy pass; `NudgeCenter` adopts the stored level; Settings → Notifications in the person's sentences, writing the preference; How I track gains the frictions; the bar's hint, the tour's order, the usual toggle's default. |
| Q3 | this commit | `scripts/beta-metrics` prints who asked for what; the docs. |

Open from the spec: S6 (two of the three benefit interstitials as candidates to come out; Lorenzo
decides). First run on the Mac: the intake in each mode through the two new screens; "Nothing"
and the first log (no system prompt); Settings → Notifications changing the level and the echo.

## What is proven

- `scripts/check-api`: 920 passed, ruff clean, at every commit (903 before P8).
- `scripts/parser-eval`: SCORES unchanged.
- Every Swift file touched balances; every changed signature's call sites were checked by hand;
  CI's iOS job (compile, render, flow, voice) is green on the head commit. For P8: run
  37179726122 on `1b354ca` compiled the plan builder at zero warnings, every golden matched (the
  new ones skipped on that runtime), the five capture flows and the voice scenarios passed. The
  tap-on-the-page keyboard flow had failed twice on the shared runner while the keyboard had in
  fact gone; both keyboard flows now wait for the bar's typing shape and give the dismissal an
  8 s budget (`1b354ca`), a wider window and the same claim.

## What is NOT proven, and what to run first

1. **The iOS app was compiled by CI, not here.** This environment has no Swift toolchain; CI's
   iOS job on `0538dd5` (run 37173632708) compiled it at zero warnings and ran the render tests
   (goldens skipped on that runtime, the blank guard and the pure-function tests ran), the capture
   flow tests and the twelve voice scenarios. Green on the first run. The local loop has not seen it.
2. **The new goldens are not recorded.** `testTodayPerMode`, `testTodayHabitsEmptyAndFocusWrap`,
   `testProtocolRevealPerMode`, `testTrackingModeChooserAndHowITrack`, `testInvitationCard`,
   `testVoiceLogResultHabits`, and P8's `testTodayMealPlan` and `testPlanBuilder` (plus
   `testProtocolRevealPerMode` now draws five reveals, and the chooser five options) need
   `RECORD_SNAPSHOTS=1 bin/ios-render-tests` once, on the pinned
   simulator, and a human reading `/tmp/ui/*.png` before the goldens are committed. On CI they
   skip the golden compare (another runtime) and still prove the pages render.
3. **The habits reveal is variant a** (counts shown: "Your habits · Three things, every day.",
   Water 96 oz, Produce 6 a day, Logged today "Every day"). The plan asked for both variants to be
   drawn and judged from the renders. Variant b (counts withheld) is a two-line change in
   `ProtocolRevealView.row(_:_:)`; draw it before deciding, as spec R12 asks.
4. **The accessibility audit baselines** (`AccessibilityAuditTests.baseline`) were counted on the
   five's old layout. The five's panels reproduce it element for element (same fonts, same tiles,
   no support line under a reach tile), so the counts should hold; the nightly `ui-audit` job says.
   Habits, calories and macros have no baseline yet: add a page per mode when the counts exist.
5. **The migrations** `20261004000001_tracking_preferences.sql` and
   `20261004000002_meal_plans.sql` are applied by Deploy or by `make db-migrate`, never by an
   agent. Until the first is applied, `GET /tracking` returns the default (the five) and
   `PUT /tracking` fails; the app's writes are fire-and-forget, so onboarding still completes and
   Today shows the five. Until the second is applied, `PUT /meals/plan` fails and the builder
   says so ("The server couldn't save the plan (error 500)"); Today in meal-plan mode shows
   "No plan yet".
7. **The plan builder's live path has not been driven end to end** (no simulator, no backend
   here). Pinned instead: the API round trip in `test_meal_plan_api.py` (PUT from a usual and
   from typed items with server re-pricing, Today ticking by name) and the mock's twin in
   `testPlanComposerTicksByName`. First run on the Mac: onboarding in meal-plan mode, type three
   meals, Save plan, read the line, sign in, then log one of the three by voice and watch its
   slot tick on Today.
6. **The five's Today looked identical before and after on paper**: the server now sends no
   support line under a reach tile (the tile prints "72 / 96 oz" itself) and the protein line as
   its status ("12 g to optimal", "In your optimal range", "4 g over optimal"), which is what the
   client computed before. Confirm with `testTodayPopulated` against its existing golden.

## Where things live now

- Mode and focus: `services/api/src/api/tracking/` (schemas, store, router, projection);
  `apps/ios/VoCal/Services/TrackingModels.swift`, `Services/Protocols/TrackingService.swift`.
- The composed dashboard: `meals/dashboard.py` (server); `Views/Today/Panels/PanelView.swift`
  (draws a kind), `PanelComposer.swift` (the mock's and the one-deploy-behind fallback's twin).
- The chooser: `Views/Onboarding/TrackingModeChooser.swift`, used by `IntakeFlowView` (first step)
  and `Views/Settings/HowITrackView.swift`.
- Invitations: `nudges/invitations.py`; the card's answers in `NudgeCardView`, the writes in
  `NudgeCenter.acceptInvitation` and `declineInvitation`.
- The meal plan: `services/api/src/api/meals/plan.py` (store, check, matching, the panel);
  `apps/ios/VoCal/Services/MealPlanModels.swift`, `Services/Protocols/MealPlanService.swift`
  (live and mock), `Views/MealPlan/PlanBuilderView.swift`, the plan card in `PanelView`,
  `PlanComposer` (the mock's twin) in `PanelComposer.swift`.
- The sim: `-TrackingMode <habits|calories|five|macros|meal_plan>` composes for one mode;
  otherwise Settings → How I track changes the stored mock preference. The mock plan lives in
  UserDefaults (`MockMealPlanService`; the canned one ticks three of the populated day's four).

## Open for Lorenzo

- D1 (the name): three tests only Lorenzo and Francesco can run. The method's name goes in one
  place when it settles, `ProtocolSettingsView` (the comment marks the line).
- D5 (the meal plan): taken as (a) and built (decision 65). Still Lorenzo's: the first live
  run above, the goldens, and whether the planned-calories line under the builder stays (spec
  6.12's restoration check names it as the one thing that may still come out).
- R12 (the habits reveal): variant a is built; the renders decide.
