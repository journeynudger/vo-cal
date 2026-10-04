# apps/ios — the SwiftUI client

**READ FIRST for any voice work: `docs/VOICE_CAPTURE.md` + `docs/INVARIANTS.md` (mandatory).**

- The `.xcodeproj` is GENERATED from `project.yml` (XcodeGen) and gitignored — edit
  `project.yml`, then `make ios-generate`. Never hand-edit the project.
- Build check: `bin/ios-app-build` (compile, zero warnings, no simulator). Voice runtime:
  `bin/ios-sim-voice-test` (12 scenarios on the pinned iPhone 17 Pro sim) — required after
  touching the coordinator/outbox/kernel; never use it as a compile check.
- Config per build-config: `VOCAL_API_BASE_URL` (Debug → `http://localhost:8000`,
  Release → prod Fly URL) surfaces through Info.plist into `APIClient`.
- Versioning: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, bumped by
  `.claude/skills/publish/scripts/bump-version.sh`. **`project.yml` is the single
  authoritative build number.**
- **TestFlight has ONE delivery lane: the `.claude/skills/publish` skill** (`bump-version.sh`
  → `xcodebuild archive` → `-exportArchive destination=upload`). Decision 2026-07-16: Xcode
  Cloud delivery is RETIRED (disabled in App Store Connect) and the manual **Xcode GUI**
  (Product ▸ Archive ▸ Distribute), `altool`, and Transporter upload paths are FORBIDDEN for
  this app — they bypass `bump-version.sh` and ship a stale/duplicate build number. Root
  cause of the old collisions: two automated lanes + a GUI path all read the same mutable
  `project.yml` number and delivered to one train. An out-of-band GUI upload of build 14
  collided with Xcode Cloud and forced a skip to 15 (commit `25f0739`) — that is why there
  is now exactly one lane and one upload command.
- The bump commit **MUST land on `main` as part of shipping**: a build uploaded from a
  `project.yml` that never reached `main` leaves the next ship recomputing the same number →
  App Store Connect rejects the duplicate. `bump-version.sh` refuses to move backwards, but
  it compares only against `project.yml`, never App Store Connect — so a stale / reverted /
  branch-local `project.yml` is the one remaining way to collide. Keep it current on `main`.
  (`ci_scripts/ci_post_clone.sh` + `ci_scripts/Package.resolved` are kept only so Xcode Cloud
  could be re-enabled deliberately; they are inert while the ASC workflow is off. If you ever
  re-enable it, retire the local lane in the same change — never run both.)
- Decode rule (paid for twice): a Swift response field must be Optional or custom-decoded
  unless the server ALWAYS emits it; server dates carry microseconds (`VoCalJSON` handles).
- UI reads `VoCalTheme` tokens only — no inline hex. Claim-ladder honesty: "Listening"
  needs byte-flow, "Saved" a commit receipt, "Logged" a server row (MUST-NOT #6).
- Sim/UITest paths run on mocks (`RuntimeMode.usesMockServices`): the mock meal service
  plays canned scenarios so every UI state is reachable with no mic/network.
- Upload: `CaptureUploadWorker` (Services) makes level-triggered passes over the outbox's
  relay jobs through `CaptureRelayDoor` on the coordinator; the voice sheet's eager upload
  goes through the same worker. Never call the outbox from a view or a service.
- Unfinished recordings: `CaptureOutcomeStore` (Services) subtracts the `CaptureOutcomeLedger`
  (VoCalCapture, append-only) from the outbox per local day; Today lists the rest with Finish
  and Discard. Record an outcome, never delete a capture. `docs/CAPTURE_LIFECYCLE.md` first.
- Personal foods: `LabelFoodSheet` (from an item's edit sheet) and `BatchFoodSheet` (under the
  result) declare a food; the server prices it by name from then on (`PersonalFoodsService`,
  mock seeded). The phone never sums macros: a label is saved, then the item is re-identified
  through refine; a batch is summed and divided server-side.
- Gestures and touches: `docs/DESIGN.md`, last section. `VoCalHaptics` only on proof
  (`captureSaved` on `.finalized`, never on a deferred commit); `HorizontalPull` for a pull
  inside a scroll, never a `DragGesture` on a row.
- Crash evidence: MetricKit crash/hang reports land in the app group at
  `vocal/local/diagnostics/*.json` (newest 20; `CrashDiagnosticsRecorder`), shared from
  Settings > About when any exist. The simulator never receives MetricKit payloads.
- Simulator logs → unified pipeline log: `scripts/ios-log-stream.sh` (tags `[ios]` into
  `.logs/server.log`). Headless boxes without a booted sim get server tags only.
- IntakeDraft: sex deliberately has NO default (field bug 2026-07 — a silent "female"
  preselection miscomputed male protocols). Don't re-add one. The mode has none either
  (decision 57): the first question is how the person follows their nutrition.
- The mode governs every printed number (decision 58, spec R8). Today draws the server's
  `panels` through `PanelView` (unknown kinds skipped; `PanelComposer` is the mock's and the
  one-deploy-behind fallback's twin of `meals/dashboard.py`); `TodayDashboard.printsNumbers`
  gates the rows, the chips, the week card and the Health line; `ParseResult.printsNumbers`
  gates the result, its cards and the receipt. Never print a calorie from a path that did not
  ask the mode. On the sim, `-TrackingMode <habits|calories|five|macros|meal_plan>` composes
  for one mode without taps (`MockTrackingService`); Settings → How I track changes it otherwise.
- How much the app says is the preference's (decision 66), never the phone's: `NudgeCenter.level`
  is a cache that adopts the stored `nudge_level` before every plan; Settings → Notifications and
  the intake write `PUT /tracking` and follow the echo. The engine's words ("essential",
  "standard") stay on the wire; every screen says the person's sentence (`NudgeLevel.label`).
  A friction (`Friction`) moves exactly one thing, read from `Experience` (the server's, or
  `Experience.composed`, its twin): the bar's hint, the tour's order, the usual toggle's default
  on the phone; the evening reminder and the amount bar on the server. No copy forks by answer.
- A nudge reaches the lock screen (decision 67) through `NudgeNotificationService.content(for:)`
  alone: the title is the card's subject, `active` with sound only when `essential`, `passive`
  otherwise, one thread, no badge, and nothing is presented over the open app. The answer goes
  through `NudgeCenter.react` (`NudgeReactionQueue`, idempotent by nudge, kind and day, flushed
  before every plan; a transport failure keeps it, a refusal drops it): the × and the swipe, "Not
  today", a log within the hour of a card or a fire, the three long-press reasons and "Turn back
  on" are the whole set. The body is a clock on the phone only (`NudgeFireTiming.shifted` over
  `HealthKitService.bodyClock`): a fire moves later, never earlier, never past 21:00, and nothing
  about a workout or a night leaves the phone. The permission is asked by the card on Today or
  Settings' Delivery row, never by the system sheet on its own and never for "Nothing". Two
  registrations run at launch (`NudgeNotificationService.attach`, `NudgeBackgroundRefresh.register`):
  closures stored, no work; the first fetch starts from Today. The daily re-plan
  (`com.vo-cal.app.replan`) runs `NudgeCenter.refreshNow` and nothing on the capture lane.
- Behavior change end to end (decision 69, `docs/design/behavior-change-spec.md`): the intake's
  order is the spec's 6.5 (`IntakeFlowView.steps(for:)`; the obstacle after the outcome, never
  before); `AnchorChooser` asks when the person will log and the answer rides `PUT /tracking` as
  `logAnchor`; the server says what it moves (`Experience.checkSlots`, with `CheckSlots.composed`
  as the mock's twin) and the phone never computes a slot of its own. The check-in opens with
  the previous note verbatim (`CheckinService.previousNote`, never summarized), asks the four
  frictions and writes them on submit, and shows the week's steps from Health without sending
  them. Nudge words come from the catalog as given; app copy follows the same rule (no "!", no
  diagnosed feeling, no grade). `NudgeFireTiming` holds every fire for the first hour after
  waking and holds the coaching fires after a short night (`holds(_:clock:)`); the essentials
  always keep their place. The reveal's one line and the Action button card's sentence are the
  person's plan, not a prompt.
- The meal plan (decision 65) is the person's, never the engine's: `PlanBuilderView` arranges
  usuals and typed meals, `PUT /meals/plan` prices and checks them, and the client prints the
  server's line as given. A fresh typed slot sends NO name, so the server names it exactly as it
  names a typed log and the plan card's tick (matched by name, server-side) can land. The mock's
  plan lives in UserDefaults (`MockMealPlanService`); `PlanComposer` is its twin of `meals/plan.py`.
- The bar answers (decision 71, `docs/design/the-bar-answers-spec.md`): there is no chat
  screen. `VoiceLogViewModel` sends a sentence to `MealCaptureService.answer` only after the
  parse found no food in it (`isNoFood`, `heardNoFood`), never before; `VoiceLogState.answered`
  is one state of the sheet and `AssistReplyView` draws it with the components Settings and
  Today already use (`SettingsRow`, `PanelView`). "Changed" is said only from the server's echo;
  Undo goes through `TrackingService.update` and `NudgeCenter.react`, the same calls a tap makes.
  The thread (`AssistTurn`, at most six) lives in the view model for the sheet and is cleared
  by `cancel()`. `MockAssistant` is the sim's twin of `assist/llm.py read` and `assist/lines.py`:
  when a line changes on the server, change it there too and in `testTheBarAnswers`. The mock
  parse refuses a request (`MockAssistant.isRequest`, the live parser's 422) so the sim reaches
  the answer from the keyboard, and keeps parsing what the rules cannot read. Decode
  tolerantly: an unknown reply kind draws the line alone.
