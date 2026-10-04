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

## Phase R, the same evening: nudges that reach the person (decision 67)

| Task | Commit | What it is |
|---|---|---|
| Spec | `db0936c` | `docs/design/nudges-that-reach-spec.md`: the Rams REVIEW of the ask (the sleep nudge, the step count and the "smart" trigger cut; Health as a clock, never a trigger) and the corrected design: the notification's inventory, the reactions, the body clock, three gesture rows, the permission, the states, the ship gate. |
| R1 API | `e405094` | `nudge_reactions` (migration `20261004000004`, **Lorenzo or Deploy applies it**); `nudges/reactions.py effects` is the engine's memory (three dismissals in a row, a month's silence; not for me until an unmute; wrong time +1 h per answer, at most two; too often doubles the cooldown, at most three times); every card carries its subject and its essential flag, every fire what the phone may move it for; `POST /nudges/reactions`; the plan's `muted`. |
| R2 + R3 iOS | `b40dc8a` | One category, two actions ("Log it" through `PendingLaunchAction.startVoiceLog`, "Not today"); title by subject, active with sound only when essential; one thread, no badge, nothing over the open app; the delegate created at launch so a cold-launch "Log it" arrives. `NudgeReactionQueue` and the answers (×, swipe, Not today, a log within the hour, the three long-press reasons, Turn back on). The permission card in the person's sentence after the first log. `HealthKitService` reads today's last workout end and last night's end; `NudgeFireTiming.shifted` moves a marked fire later on the phone; HealthKit background delivery re-plans on a saved workout; `BGAppRefreshTask` re-plans the next morning at 08:30. |
| R4 | this commit | The docs: DESIGN (the three gesture rows, the notification), UI_VERIFICATION, apps/ios/AGENTS, the App Store wording for the three Health reads, memory. |

**Until migration `20261004000004` is applied,** `POST /nudges/reactions` fails with a 500 and
the phone drops the answer (a refusal is not retried; only a transport failure is kept), so
answers given before the migration are lost, by design: the plan still works unchanged.

**The week on a phone (N10 and the rest the spec's 6.12 names), in order:**

1. Onboard with "Only when I'm slipping" and "I forget"; log a meal by voice. Today shows the
   permission card in that sentence; Allow shows the system sheet (no badge in it); Not now
   remembers, and Settings → Notifications → Delivery says "Not asked yet" and asks on a tap.
2. Leave dinner unlogged. At 20:00 "Your day" arrives with the system sound (essential). Long-press
   it: "Log it" opens the app into the voice log; "Not today" dismisses with no app.
3. Pick "Coach me along the way" instead; a coaching fire (Protein, Water, Fiber) arrives silent
   and passive, stacked under one thread. No badge on the icon at any point.
4. Finish a workout at, say, 16:40 with a protein fire planned for 17:00 (the plan fetched at
   noon). The saved workout wakes the app (background delivery); the fire lands at 17:25. The
   server log shows no workout, no sleep, no time: nothing left the phone.
5. Dismiss the same card three days running; the fourth plan has none of it for a month.
   Long-press a card, "Not for me": Settings → Notifications lists it under Muted; "Turn back
   on" brings it back on the next plan. "Wrong time" on Water moves it an hour later; "Too
   often" halves it.
6. Do not open the app for two days. The morning re-plan runs when iOS grants it (around 08:30)
   and the day's fires exist with the app unopened. To force it in the debugger:
   `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.vo-cal.app.replan"]`.

Open from the spec: N10 above; the subtraction check (the ×, if the swipe proves enough; the
pro tip, if nobody opens it). The new goldens (`three-reasons`, the permission card) need the
pinned simulator like the rest.

## Phase S, the same night: behavior change end to end (decisions 68 and 69)

Lorenzo asked for a Rams review of every screen with the screens drawn, and for the literature of
behavioral science applied end to end; then "keep Vo-Cal as a name for now; apply all your
recommendations". The review is the canvas "Vo-Cal Rams Review" on his claude.ai (one artboard
per screen as built, the finding beside it in the ten principles, and the screens that change);
the written half is `docs/design/behavior-change-spec.md`.

| Task | Commit | What it is |
|---|---|---|
| S0 | `2f3dad2` | The spec (the necessity gate, what holds, eight findings, the diagnosis, the corrected design, Health the Serein way, what is refused); decisions 68 (the name stays; S6, F6, F7 taken) and 69; plan S. |
| S1 API | `4d79fef` | `tracking_preferences.log_anchor` (migration `20261004000005`, **Lorenzo or Deploy applies it**); `check_slots_for` and the engine's `slot_for`, one table: the before-bed logger never hears the late-morning check and gets the evening one at 20:30; `message_for`: the late-morning check in the person's own plan's words, the fresh-start line on a Monday or the first; every catalog message rewritten to recognition, invitation, agency; the metrics by anchor. |
| S2 iOS | `d1e6c07` | `AnchorChooser` and the intake's order (thirteen screens, nine in habits; Momentum and Long-term results gone; Realistic pace without its exclamation); the check-in that opens with last week's note, asks what got in the way (writing the preference) and shows the phone's steps; the reveal's one line; the Action button card's sentence; Today's badge gone; `NudgeFireTiming` holds every fire for the hour after waking and the coaching fires after a short night; Health reads steps. |
| S3 | this commit | The docs: DESIGN (the intake, the check-in, the copy rule, the dated section), UI_VERIFICATION, both AGENTS, the catalog's docstring, the App Store wording for the steps read, memory. |

**Until migration `20261004000005` is applied,** `PUT /tracking` with a `log_anchor` fails on
the insert (an unknown column), which means the onboarding's fire-and-forget write of the mode,
the level, the frictions and the anchor all fail together for a new account: apply it before the
next TestFlight build, with `20261004000001` to `20261004000004`.

**The first run on a phone, in order:**

1. Onboard in the five with "All at once, before bed" at "When will you log?": the intake runs
   mode, basics, ruler, goal, realistic pace (no exclamation, the water-then-fat line under the
   axis), what gets in the way, when you log, how much to say, real life, training, hunger,
   stress, meals. The reveal carries "Everything here follows from one habit: say what you eat."
   The Action button card says "Hold it before you turn in. Say the whole day."
2. Log nothing until noon: no "Nothing logged yet today" arrives (the before-bed logger never
   hears it). At 20:30 "Anything from today still unlogged?" arrives, essential, with sound.
3. Change the anchor in Settings → How I track to "Right after I eat"; the next morning's late
   check reads "Nothing logged yet today. You said right after you eat: the next meal is the
   moment."
4. On a Monday with two quiet days behind: "New week, clean page. One logged meal and you're back
   in it." On a Tuesday: "A few quiet days. Nothing to catch up on; today is its own page."
5. The weekly check-in: write a sentence under "Anything you want next week's you to read?";
   the next check-in opens with it under "You wrote last week". Tick "Eating out" under "What got
   in the way this week?": the bar reads "Say it, type it, or snap your plate." from then on.
   With Health connected and a week of steps, the steps line sits under the week card.
6. With a watch: a night under six hours holds the protein and water fires that day and keeps
   the essentials; any fire inside the first hour after waking waits for the hour to pass.

B8 is built (decision 70): with less than half the target eaten the hero reads "Calories so far"
over the eaten figure, with what is left as the line. The new goldens (the anchor chooser, the check-in twice, the reveal with its line, the
intake's screens) need the pinned simulator like the rest.

## Phase T, the same night: the bar answers (decision 71)

Lorenzo: "not saying we should build in a chat, but i am saying it should respond when someone
has a response and in that they could chat with it if they choose to but it more importantly
shows them what they need". Spec `docs/design/the-bar-answers-spec.md`; plan
`.claude/plans/phase-t-the-bar-answers.md`.

| Commit | What |
|---|---|
| `3afc28e` | docs(design): the bar answers, under the Rams audit (the chat screen CUT; decision 71) |
| `c0c61f0` | feat(api): `POST /assist`, `claude-haiku-4-5` reads the form, deterministic apply, the rules offline, Undo as the previous values; `apply_update` and `today_for` factored out |
| `824c10c` | feat(ios): the sheet's `answered` state, `AssistReplyView`, `MockAssistant` (the rules twin), the shell opens Settings for a pointer |
| `0536d00` | docs: the bar answers |
| `f504ea2` | fix(api): the reader keeps the tidy ratchets (no `noqa`, the SDK's own error family, one small reader per concern); CI's API job had counted the first version against them |
| `e629f9f` | fix(ios): the answer render test leaves the mock preference as it found it (a `defer`, pure checks before the renders); the capture-flow and motion suites launch with `-TrackingMode five`. CI's five flows had waited for a calories card after the test left the simulator on habits |

CI run 37207913005 on `e629f9f` is green: API, Libraries, iOS app (compile at zero warnings, every
golden matched or skipped on that runtime, the five flows, the voice scenarios).

No migration: the assistant stores nothing. What it changes is a tracking version or a reaction
row, the records Settings already writes.

The first run on a phone, with `ANTHROPIC_API_KEY` set on the server (without it the rules
answer; the log line `[assist] client=rules` says so):

1. Type "switch to habits" into the bar. The sheet should show "You asked", the line "You're
   following Build better habits now.", the row How I track · Habits, Undo, the field and the
   mic. Today behind it redraws for habits when the sheet closes. Tap Undo: "Undone.", the row
   gone, Today back on the five.
2. Say "how much protein do I have left". The protein card, as Today draws it. Swipe the answer
   sideways: the sheet closes with one tick.
3. Say "stop the protein reminders". The row Muted · Protein; Settings → Notifications lists it
   under Muted; Undo wakes it.
4. Type "make me a sandwich": the honest no, no Undo. Type "I had a thing": the old failure copy.
5. In the answer, type "actually, coach me along the way" into the field: the level changes with
   the thread resolving "actually".

## What is proven

- `scripts/check-api`: 974 passed, ruff clean, at every commit (920 before Phase S; 903 before P8).
- `scripts/parser-eval`: SCORES unchanged.
- Every Swift file touched balances; every changed signature's call sites were checked by hand;
  CI's iOS job (compile, render, flow, voice) is green on the head commit (`e629f9f`, run
  37207913005, after Phase T). For P8: run
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
- The bar's answer: `services/api/src/api/assist/` (schemas, lines, llm, apply, router);
  `apps/ios/VoCal/Services/AssistModels.swift`, `Services/Mocks/MockAssistant.swift`,
  `Views/VoiceLog/AssistReplyView.swift`, the `answered` state in `ViewModels/VoiceLogState.swift`
  and the no-food branch in `VoiceLogViewModel` (`answer`, `undoAnswer`, `sayMore`).
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
- B8 (decision 70): open Today after one small meal and the hero should read "Calories so far"
  with the eaten figure; after the midpoint, "Calories left" as before. The two benefit screens are gone (decision 68); if one is missed, the first
  run above says which claim it made.
- T (decision 71): the five steps above on a phone with a key set; the three goldens
  (`testTheBarAnswers`) on the pinned simulator; whether the field under the answer earns its
  place after a week (spec 5.2's "if they choose to") or the mic alone is the door.
- N10 (decision 67): the quiet person's morning fire with the app unopened is provable only on a
  device over days; the week above is the test. Migration `20261004000004` is Lorenzo's or
  Deploy's to apply. The `com.apple.developer.healthkit.background-delivery` entitlement is new in
  `project.yml`; `make ios-generate` writes it, and the provisioning profile must carry HealthKit
  (it already does for the energy read).
