# Phase S: Behavior change, end to end

> Status: Built 2026-10-04 (decisions 68, 69 and 70; Lorenzo: "keep Vo-Cal as a name for now; apply all your recommendations"; "apply the hero before noon too"). Open: the goldens on the pinned simulator, migration `20261004000005` (Lorenzo or Deploy).
> Owner: @lorenzo
> Branch: `claude/confident-volta-7er84f` (on top of Phases P, Q and R)
> Next: nothing in the build; the first run on a phone (handoff `docs/handoffs/2026-10-04-personalized-tracker.md`, Phase S)
> Design: `docs/design/behavior-change-spec.md` (the Rams REVIEW of the ask and the corrected design) and the canvas "Vo-Cal Rams Review" (every screen, the finding beside it). Where this file and the spec differ, the spec wins.

## Goal

The structure already carries the literature's strongest evidence (self-monitoring made cheap,
autonomy at every decision, flexible restraint, prompts at the person's level, lapses examined
before plans are cut). Phase S adds the volitional bridge and fixes the voice: the person says
when they will log and the reminders move there (B2); each week they say what got in the way and
one thing changes, and their own words come back to them (B1, B5); the obstacle is asked after
the outcome and two generic promises go (B3, B7); every nudge speaks as recognition, invitation,
agency (B4); the reveal names the one habit (6.7); Health follows Serein's pattern on the phone
(6.12). The result's "Logged" stays the last thing on its screen (B6). Today's hero names the
smaller distance (B8, decision 70).

What does not move: budgets, quiet hours, cooldowns (decision 63); copy final in the catalog, one
message per anchor, nothing generated (decision 67); Health on the phone, never sent (decision
52); no streak, badge, score, fear or diagnosis (spec 6.11).

## Tasks

### S0. Record the decisions

- [x] **Step 1.** Decisions 68 and 69 in memory; the master plan row; `.claude/memory/product.md`; the spec's B7 taken and 6.12 (Health the Serein way).
- [x] **Commit:** `docs(design): behavior change end to end, under the Rams audit`

### S1. API: the anchor, the voice, the fresh start

- [x] **Step 1.** Migration `20261004000005_tracking_log_anchor.sql`: `tracking_preferences.log_anchor text` (nullable; null is never asked). `tracking/schemas.py`: `LogAnchor` (after_eating, when_seated, before_bed, own); `TrackingPreference.log_anchor`, `TrackingUpdate.log_anchor`; `Experience.check_slots` (late_morning "HH:MM" or null, evening "HH:MM"). `projection.experience_for(level, frictions, anchor)`. Store and router merge the anchor like the level. `docs/DATABASE.md` row.
- [x] **Step 2.** `nudges/engine.py`: the consistency slots follow the anchor (after_eating 11:30 and 20:00; when_seated 12:30 and 20:00; before_bed no late-morning fire and 20:30, the evening check firing for the before-bed logger even without the forgetting friction; own and null unchanged). The quiet day's parked touch follows it too.
- [x] **Step 3.** `nudges/catalog.py`: the copy pass (spec 6.6, every message and the three pro tips); `message_for(nudge, anchor, fresh_start)`: one late-morning message per anchor naming the person's plan, the fresh-start variant of gone_quiet on a Monday or the first of the month (same id, same cooldown). `nudges/router.py` passes the anchor.
- [x] **Step 4.** `scripts/beta-metrics` counts who asked for what by anchor.
- [x] **Test:** the slot table per anchor; before_bed suppresses the late-morning fire and moves the evening one; the per-anchor words; the fresh-start variant on a Monday and the plain words on a Tuesday; the catalog's anatomy (no "!" in any message or pro tip, no "we" outside the recalibration, every message under 140 characters); `experience_for`'s slots; the wire contract additive (`log_anchor`, `check_slots`); `PUT /tracking` with the anchor; the metrics self-test.
- [x] **Commit:** `feat(api): the reminders follow when the person logs, and speak as recognition, invitation, agency` *(953 passed, ruff clean)*

### S2. iOS: the intake's order and its new question, the check-in that asks and remembers, the reveal's line, Health the Serein way

- [x] **Step 1.** `TrackingModels`: `LogAnchor` (label, support, the button card's sentence), `TrackingPreference.logAnchor`, `TrackingUpdate.logAnchor`, `Experience.checkSlots` (tolerant); `Experience.composed` twin. `IntakeDraft.logAnchor`; `AnchorChooser`; `IntakeFlowView`: the `.anchor` step, the order of spec 6.5 (thirteen and nine screens), `MomentumBenefitView` and `LongTermResultsBenefitView` deleted with their ids, Realistic pace without the exclamation and with the support line. `OnboardingFlowView` writes the anchor with the intake. `HowITrackView` gains "When you log". `MockTrackingService` stores the anchor.
- [x] **Step 2.** `CheckInView`: "You wrote last week" (the previous check-in's note, verbatim, quoted; absent when none; a note older than a week says its date), "How close did the week feel to the plan?" (Far from it … Right on it), "What got in the way this week?" (the four frictions, any or none; written to the preference on submit), "Anything you want next week's you to read?"; the week's steps line from Health when present.
- [x] **Step 3.** `ProtocolRevealView`: the one line under the hero (spec 6.7). `ActionButtonSetupCard`: the sentence by anchor. `TodayView`: the "avg N% sure" badge removed (F6).
- [x] **Step 4.** Health the Serein way (spec 6.12): `NudgeFireTiming` silences the first hour after waking for every fire; `BodyClock.sleepDuration` and `shortNight` (under six hours) hold the coaching fires in `reschedule`; `HealthKitService` reads last night's asleep total and the week's average steps (`stepCount`); the usage string names the fourth read.
- [x] **Test:** render tests for the anchor chooser, the corrected check-in (with and without a previous note), the reveal's line; the fire timing's new cases (the wake hour for a non-marked fire; a short night holds a coaching fire and keeps an essential one); the catalog twin where the mock speaks; the A11y ids.
- [x] **Commit:** `feat(ios): the intake asks when, the check-in asks what got in the way and remembers, the nudges speak as the design does` *(no Swift toolchain in the build container: CI's iOS job is the compile proof; the goldens await the pinned simulator)*

### S3. Docs and ship

- [x] **Step 1.** `docs/DESIGN.md` (the intake as it is now, the nudge anatomy as a copy rule, the check-in), `docs/UI_VERIFICATION.md`, `apps/ios/AGENTS.md`, the nudges module's docstring (the anatomy rule), `docs/ARCHITECTURE.md`, the App Store wording for the steps read, the handoff (Phase S, the week on a phone), memory, the spec's 6.13 evidence; PR body; CI green.
- [x] **Commit:** `docs: behavior change end to end`

### S4. The hero names the smaller distance (B8, decision 70)

- [x] **Step 1.** `meals/dashboard.py`: the calories panel carries `framing` (`to_date` while less than half the target is eaten and something is; `to_go` otherwise), its title and line follow ("Calories so far"; "1,620 left of 2,040 today"). `Panel.framing` additive, default `to_go`.
- [x] **Step 2.** iOS: `TodayPanel.framing` (tolerant; an unknown word is to-go), `PanelComposer.calories` twin, `PanelView.caloriesCard` draws the framed numeral (ink so far, gold left) with its own id. The spec's B8, the canvas's note, the docs.
- [x] **Test:** the composer per framing (early, later, empty, the midpoint, over; the five's twin; a tile leaves the default); the iOS twin and the tolerant decode; the card before the midpoint rendered with the phone's burned figure.
- [x] **Commit:** `feat: the calories hero names the smaller distance`

### S5. Apple Health's door for an updater (2026-10-22, branch `claude/heuristic-dijkstra-e3bdc6`)

Builds 30 and 31 asked Health for active energy alone, and the onboarding step was the only ask, so every updater's reminders never learned the night or a workout and their check-in never showed steps. Spec 6.12, the door paragraph, says why the row sits on Settings → Notifications and not on the check-in.

- [x] **Step 1.** `HealthKitService.readAccess()`: HealthKit's request status for the four reads, classified at the boundary (`.unasked`, `.answered`, nil when unavailable or unknown); the four reads made in one place; the workout observer started again on the sheet's answer (an observer on a read never asked ends at once with HealthKit error 5, probed on the pinned simulator).
- [x] **Step 2.** Settings → Notifications: "Sleep and workouts", "Connect" under Delivery, and "Use Apple Health to time reminders around your sleep and workouts. Read on your phone, never sent." under the card, only while a read is unasked and the level is not "Nothing"; the tap shows the system sheet, then the door closes and the reminders re-plan. The page's system answers are injectable (`SystemAnswers`) so renders draw exactly their state. `A11y.Settings.healthAsk`.
- [x] **Test:** `testHealthDoorForAnUpdater` (the classification, the door's rule, the page with the door open, golden recorded once on the pinned simulator); `testNotificationSettingsInThePersonsWords` drawn with fixed answers (no door) and its golden recorded. Throwaway probes, not committed: HealthKit before any ask, the row at 375 pt. Walked on the pinned simulator (2026-10-22) with HealthKit where build 31 left a tester (active energy answered alone; the four reads still "should request"): no sheet on launch; the row under Delivery; the tap's sheet listed sleep, steps and workouts alone; after Allow the row was gone, and still gone after a relaunch.
- [x] **Commit:** `feat(ios): Apple Health's door for an updater, on Settings → Notifications`

## Exit Criteria

- A before-bed logger never receives the late-morning check; an after-eating logger's late-morning check names their own plan.
- The check-in opens with last week's note and closes with a question to next week; a lapse answer changes next week's moves.
- No nudge in the catalog carries an exclamation mark, a diagnosed feeling or a grade.
- The intake is thirteen screens (nine in habits) in the order wish, outcome, obstacle, plan.
- A fire inside the first hour after waking waits; a short night holds the coaching fires on the phone; nothing about sleep, workouts or steps leaves the phone.
- A person who answered Health before a read existed reaches it from Settings → Notifications, asked once, never on launch, never for "Nothing".
- `scripts/check-api` green; CI's iOS job green.

## Progress log

| Task | Status | SHA |
|---|---|---|
| S0 Decisions | done 2026-10-04 | 2f3dad2 |
| S1 API | done 2026-10-04 (the migration awaits `make db-migrate` or Deploy) | 4d79fef |
| S2 iOS | done 2026-10-04 (compile proof: CI's iOS job) | d1e6c07 |
| S3 Docs | done 2026-10-04 | 5ff9100 |
| S4 The hero's framing | done 2026-10-04 (955 passed; the golden awaits the pinned simulator) | 5770f76 |
| S5 Apple Health's door | done 2026-10-22 (zero warnings; both goldens matched; flows 5/5 and voice 12/12 on the pinned simulator) | this commit |
