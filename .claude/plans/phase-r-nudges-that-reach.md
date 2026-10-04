# Phase R: Nudges that reach the person

> Status: Built 2026-10-04 (decision 67; Lorenzo: "wire up notifications / nudges as well ... make the nudges really smart and contextually aware based on what the user requested"). Open: N10 on a device over days, the goldens on the pinned simulator, migration `20261004000004` (Lorenzo or Deploy).
> Owner: @lorenzo
> Branch: `claude/confident-volta-7er84f` (on top of Phases P and Q)
> Next: nothing in the build; the week on a phone (handoff `docs/handoffs/2026-10-04-personalized-tracker.md`, Phase R)
> Design: `docs/design/nudges-that-reach-spec.md` (the Rams REVIEW of the ask and the corrected design). Where this file and the spec differ, the spec wins.

## Goal

A reminder reaches the person only when it is theirs: asked for, timed to their day, silent
otherwise. The engine keeps deciding what and whether (deterministic, the designer's); the phone,
which alone knows the body and the thumb, decides when and listens to the answer; the words on the
lock screen name the person's day, not the maker. Five moves (spec §5): the notification wired
(title by subject, level by essentialness, one thread, two actions, no badge, no sound on
coaching); the answer remembered (`nudge_reactions`; three dismissals retire a nudge for a month;
a long-press says it in one); the body as a clock on the phone (after a workout, after waking;
never as a trigger); the permission asked in the person's own sentence, once, never for
"Nothing"; the daily re-plan in the background for the person who stopped opening the app.

What does not move: the engine's budgets, quiet hours and cooldowns (decision 63); Health
read-only on the phone, never sent (decision 52); the capture lane rule (background work never
touches the mic); copy final in the catalog; no badge, no streak, no count (no gamification).

## Decisions taken with this plan

Recorded as decision 67 in `.claude/memory/decisions.md`. Open: N10 (background re-planning can
only be proven on a device over days; the handoff names the test).

---

## Tasks

### R0. Record the decision

- [x] **Step 1.** Decision 67 in memory; the master plan row; `.claude/memory/product.md`.
- [x] **Commit:** with the spec (db0936c).

### R1. API: the reactions, the plan's new fields, the engine's memory

- [x] **Step 1.** Migration `20261004000004_nudge_reactions.sql`: `nudge_reactions(id, user_id, nudge_id text, kind text, created_at)`, append-only, RLS select and insert own, no update or delete. `docs/DATABASE.md` row. Export (`account/export.py`) and deletion (`account/router.py`) cover it.
- [x] **Step 2.** `nudges/reactions.py`: `ReactionKind` (dismissed, acted, wrong_time, not_for_me, too_often, unmute), the store (append, list by person), and `effects(rows) -> Effects` (pure): silenced for 30 days after three dismissals in a row with no act; muted after `not_for_me` until an `unmute`; slot later by an hour per `wrong_time` (at most two); cooldown doubled per `too_often`. `POST /nudges/reactions` (one row; 204). The plan response gains `muted: [{id, title}]`.
- [x] **Step 3.** `nudges/schemas.py` (additive): `NudgeCard.essential`, `NudgeCard.title`; `ScheduledNudge.context` (`after_workout`, `after_wake`). `nudges/catalog.py`: `title_for(category)`. `nudges/engine.py`: `plan(..., effects)` drops silenced and muted nudges, applies the later slot and the doubled cooldown, sets `after_workout` on `protein_gap` and `hydration_low` and `after_wake` on every fire before 11:00. `nudges/router.py` reads the reactions and passes the effects.
- [x] **Test:** the effects' rules (pure); the plan omits a silenced nudge and a muted one; the fields on the wire; the endpoint (auth, 422 on an unknown kind, owner scoping); export and deletion cover the table. *942 passed, ruff clean.*
- [x] **Acceptance:** three dismissals of `treat_headroom` and the fourth plan has none; `not_for_me` on `fiber_boost` lists it under `muted` and an `unmute` brings it back; a build-31 client decodes the plan unchanged.
- [x] **Commit:** `feat(api): nudges remember the answer and carry their words and their clock`

### R2. iOS: the notification wired, the card's gestures, the permission in the person's sentence

- [x] **Step 1.** `NudgeNotificationService`: one category with "Log it" and "Not today"; title from the card (fallback: the category word), interruption `active` with sound for essential, `passive` without for the rest; relevance from priority; one thread; no badge; foreground presentation none (the card is the in-app surface); "Log it" routes through `PendingLaunchAction.startVoiceLog`; "Not today" queues a `dismissed` reaction (idempotent by nudge id and day), flushed when the app next plans.
- [x] **Step 2.** `NudgeCenter`: reactions (dismissed on × or swipe, acted on a log within an hour of a card or fire, the three long-press reasons, unmute); `muted` from the plan; the permission card after the first log (the person's sentence, Allow / Not now, remembered; never for "Nothing").
- [x] **Step 3.** `NudgeCardView`: swipe to dismiss (`select`), long-press "This wasn't right" with three rows; no haptic on surfacing. Settings → Notifications: "Muted" with "Turn back on", only when there is one; Delivery row states: Not asked yet (tap asks) · Not asked ("Nothing") · Allowed · Off in iOS Settings.
- [x] **Step 4.** Background re-plan: `BGAppRefreshTask` registered at launch (lane bookkeeping only; the task runs `NudgeCenter.refresh` and nothing on the capture path), scheduled for the next morning after every plan; `UIBackgroundModes` gains `fetch`, `BGTaskSchedulerPermittedIdentifiers` the one id.
- [x] **Test:** the request builder (title, level, sound, thread, actions, no badge) as a pure function (`NudgeNotificationService.content(for:)`); the reaction queue's idempotency (`NudgeReactionQueue`); render tests for the card's sheet and the permission card (the Muted section renders inside Settings → Notifications, whose golden the pinned simulator records). *No Swift toolchain in the build container: CI's iOS job is the compile proof; the goldens await the pinned simulator.*
- [x] **Commit:** `feat(ios): a nudge reaches the lock screen in the person's words and hears the answer` (one commit with R3: the clock is applied inside `reschedule`, so the two cannot ship apart)

### R3. iOS: the body as a clock

- [x] **Step 1.** `HealthKitService`: today's workouts (end times) and last night's sleep end, read only, nothing stored; the priming step and the Health usage string name all three reads; HealthKit background delivery for workouts wakes the app to re-plan (`com.apple.developer.healthkit.background-delivery`).
- [x] **Step 2.** `NudgeNotificationService.reschedule` applies the shifts, as a pure function over (fire, context, workoutEnd?, sleepEnd?, now) (`NudgeFireTiming.shifted`): `after_workout` → the later of the slot and workout end plus 45 minutes, when still ahead and before 21:00; `after_wake` → the later of the slot and sleep end plus 30 minutes; a fire pushed past 21:00 is dropped. Over the open app no banner shows (the delegate presents nothing), so nothing fires over the voice log; the post-log plan re-fetches.
- [x] **Test:** the shift function (pure, in `RenderTests.testNotificationContentAndFireTiming`); in the sim path Health was never asked, so the clock is `.unknown` and moves nothing (the mock has no body).
- [x] **Acceptance:** a protein fire planned for 17:00 (the plan fetched at noon) moves to 17:25 when the workout ends at 16:40 and the workout's background delivery re-plans; with no workout, 17:00; a workout that ended at 10:00 leaves the slot; a fire planned for 09:30 with sleep ending at 09:40 lands at 10:10; a fire at 20:30 after a workout ending 20:20 is dropped. (The plan's first example named a fire whose slot had already passed when fetched; the engine never schedules a passed slot, so the example was corrected to one the engine produces.)
- [x] **Commit:** with R2 (one commit; see R2).

### R4. Docs and ship

- [x] **Step 1.** `docs/DESIGN.md` (the three gesture rows, the notification in the inventory); `docs/UI_VERIFICATION.md`; `apps/ios/AGENTS.md`; `docs/ARCHITECTURE.md` and `docs/DATABASE.md` (with R1); the privacy manifest's note, `APP_PRIVACY.md` and `REVIEW_NOTES.md` for the three Health reads (none is collected; the usage string names all three); the handoff (the week on a phone); memory; the spec's 6.12.
- [x] **Commit:** `docs: nudges that reach the person`

## Exit Criteria

- A notification is titled by its subject, sounds only when essential, carries "Log it" and "Not today", and never badges.
- A nudge dismissed three times stays silent for a month; "Not for me" mutes it until the person turns it back on; both are the person's record.
- The after-training and after-waking shifts happen on the phone; the server never learns a workout or a night.
- The permission is asked once, in the person's sentence, never for "Nothing".
- `scripts/check-api` green; CI's iOS job green.

## Progress log

| Task | Status | SHA |
|---|---|---|
| R0 Decision | done 2026-10-04 | db0936c |
| R1 API | done (the migration awaits `make db-migrate` or Deploy) | e405094 |
| R2 iOS notifications | done 2026-10-04 (compile proof: CI's iOS job) | b40dc8a |
| R3 iOS body clock | done 2026-10-04, in the R2 commit | b40dc8a |
| R4 Docs | done 2026-10-04 | this commit |
