# Phase S: Behavior change, end to end

> Status: Active (decisions 68 and 69, 2026-10-04; Lorenzo: "keep Vo-Cal as a name for now; apply all your recommendations")
> Owner: @lorenzo
> Branch: `claude/confident-volta-7er84f` (on top of Phases P, Q and R)
> Next: S2
> Design: `docs/design/behavior-change-spec.md` (the Rams REVIEW of the ask and the corrected design) and the canvas "Vo-Cal Rams Review" (every screen, the finding beside it). Where this file and the spec differ, the spec wins.

## Goal

The structure already carries the literature's strongest evidence (self-monitoring made cheap,
autonomy at every decision, flexible restraint, prompts at the person's level, lapses examined
before plans are cut). Phase S adds the volitional bridge and fixes the voice: the person says
when they will log and the reminders move there (B2); each week they say what got in the way and
one thing changes, and their own words come back to them (B1, B5); the obstacle is asked after
the outcome and two generic promises go (B3, B7); every nudge speaks as recognition, invitation,
agency (B4); the reveal names the one habit (6.7); Health follows Serein's pattern on the phone
(6.12). The result's "Logged" stays the last thing on its screen (B6). B8 is drawn, not built.

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

- [ ] **Step 1.** `TrackingModels`: `LogAnchor` (label, support, the button card's sentence), `TrackingPreference.logAnchor`, `TrackingUpdate.logAnchor`, `Experience.checkSlots` (tolerant); `Experience.composed` twin. `IntakeDraft.logAnchor`; `AnchorChooser`; `IntakeFlowView`: the `.anchor` step, the order of spec 6.5 (thirteen and nine screens), `MomentumBenefitView` and `LongTermResultsBenefitView` deleted with their ids, Realistic pace without the exclamation and with the support line. `OnboardingFlowView` writes the anchor with the intake. `HowITrackView` gains "When you log". `MockTrackingService` stores the anchor.
- [ ] **Step 2.** `CheckInView`: "You wrote last week" (the previous check-in's note, verbatim, quoted; absent when none; a note older than a week says its date), "How close did the week feel to the plan?" (Far from it … Right on it), "What got in the way this week?" (the four frictions, any or none; written to the preference on submit), "Anything you want next week's you to read?"; the week's steps line from Health when present.
- [ ] **Step 3.** `ProtocolRevealView`: the one line under the hero (spec 6.7). `ActionButtonSetupCard`: the sentence by anchor. `TodayView`: the "avg N% sure" badge removed (F6).
- [ ] **Step 4.** Health the Serein way (spec 6.12): `NudgeFireTiming` silences the first hour after waking for every fire; `BodyClock.sleepDuration` and `shortNight` (under six hours) hold the coaching fires in `reschedule`; `HealthKitService` reads last night's asleep total and the week's average steps (`stepCount`); the usage string names the fourth read.
- [ ] **Test:** render tests for the anchor chooser, the corrected check-in (with and without a previous note), the reveal's line; the fire timing's new cases (the wake hour for a non-marked fire; a short night holds a coaching fire and keeps an essential one); the catalog twin where the mock speaks; the A11y ids.
- [ ] **Commit:** `feat(ios): the intake asks when, the check-in asks what got in the way and remembers, the nudges speak as the design does`

### S3. Docs and ship

- [ ] **Step 1.** `docs/DESIGN.md` (the intake as it is now, the nudge anatomy as a copy rule, the check-in), `docs/UI_VERIFICATION.md`, `apps/ios/AGENTS.md`, the nudges module's docstring (the anatomy rule), `docs/ARCHITECTURE.md`, the App Store wording for the steps read, the handoff (Phase S, the week on a phone), memory, the spec's 6.13 evidence; PR body; CI green.
- [ ] **Commit:** `docs: behavior change end to end`

## Exit Criteria

- A before-bed logger never receives the late-morning check; an after-eating logger's late-morning check names their own plan.
- The check-in opens with last week's note and closes with a question to next week; a lapse answer changes next week's moves.
- No nudge in the catalog carries an exclamation mark, a diagnosed feeling or a grade.
- The intake is thirteen screens (nine in habits) in the order wish, outcome, obstacle, plan.
- A fire inside the first hour after waking waits; a short night holds the coaching fires on the phone; nothing about sleep, workouts or steps leaves the phone.
- `scripts/check-api` green; CI's iOS job green.

## Progress log

| Task | Status | SHA |
|---|---|---|
| S0 Decisions | done 2026-10-04 | 2f3dad2 |
| S1 API | done 2026-10-04 (the migration awaits `make db-migrate` or Deploy) | S1-SHA |
| S2 iOS | | |
| S3 Docs | | |
