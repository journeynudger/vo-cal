# Nudges that reach the person, designed under the Rams audit (REVIEW, then DIETERIFY)

Date: 2026-10-04. Mode: **REVIEW** of Lorenzo's ask the same evening ("wire up notifications and
nudges as well; turning on notifications; reference what Beacon uses to send out notifications;
use Apple HealthKit; the new gestures the way Serein Life does; make the nudges really smart and
contextually aware based on what the user requested from the app"), then **DIETERIFY** applied to
it. The protocol is Lorenzo's "Dieter Rams" document; the earlier runs are
`docs/restructure/06-rams-audit.md`, `docs/design/personalized-tracker-spec.md` and
`docs/design/onboarding-that-asks-spec.md`. Two more sources are read here and quoted as sources,
not as Rams: Lorenzo's own nudge policy (`Nudges/Nudge-Policy.md` in the MyLife vault, "Nudge
Policy V2, Context-Aware Architecture", tagged V2) and Serein's interaction notes
(`Projects/Serein/Canonical/Interaction-Design-Notes.md`, tagged S). Quotation marks plus a tag
mean verbatim. Everything unmarked is applied reading, and is inference. No em dashes.

Nothing here is built when it is written.

---

## 1. Intake

**1.1 The purpose sentence.** A reminder reaches the person only when it is theirs: asked for,
timed to their day, silent otherwise.

(The ask's sentence was "make the nudges really smart and contextually aware". That is the
maker's. The one above is the person's, and it is also the policy's: "The goal is not '3 nudges
per day.' The goal is 'every nudge that arrives feels like it was meant for exactly this
moment.'" (V2).)

**1.2 The person.** The same as the two specs before: imagined more than met, their notification
budget already spent by every other app. What is new: they have now told the app how much to say
(decision 66) and what gets in their way. A person who said "Only when I'm slipping" has drawn
a line; this design's whole job is to stand on the right side of it.

**1.3 The room.** The lock screen, mostly: a glance, a thumb, a long-press. The room has rules
the app does not set: iOS decides whether a banner shows, whether it sounds, whether it waits for
the summary. The second room is Today with nothing logged, where the one card sits above the
empty list. The third is the body: a workout just ended, a night just finished. The design is
judged in all three.

**1.4 The system.** `nudges/engine.py` (deterministic: signals, ledger, local clock, level, mode →
a plan of at most one immediate card and the day's scheduled fires), `NudgeCenter` (plans on
Today-open and after a log; the ledger; the level, now the preference's), `NudgeNotificationService`
(Beacon's shape: idempotent permission, a delegate, local notifications only; no push, no server
sender), `HealthKitService` (one read, active energy, on the phone), `NudgeCardView` (one card, a
close, a pro tip, the invitation's three answers), `PendingLaunchAction` (an ask from outside the
app, honored once, fresh).

**1.5 The frame of the feasible.** Local notifications only: every trigger derives from the
person's own logs, so no push key, no token registry, no server sender (the ported decision
stands). Health data is read on the phone and never sent (decision 52); anything Health-aware
runs on the device. The app is foreground-only for capture; background work is allowed for
re-planning and never for the mic (`AppRuntimeCoordinator`, the lane rule). The project targets
iOS 26 on the pinned simulator; the APIs used here (categories and actions, interruption levels,
relevance, background refresh, HealthKit background delivery) are all iOS 15 to 17 era and stable.
The sibling repositories (`../beacon`, `../Serein`) are not in this environment; what was ported
from them is in this codebase with its provenance comments, and the vault's design notes are read
instead. Additive wire shapes only.

**1.6 The artifacts.** The engine and its forty tests; the notification service (title "Vo-Cal",
body, default sound, no category, no level); the card on Today; the Health step and its one read;
the vault's policy and Serein's notes. Read in code; this environment cannot run the app.

**1.7 The lifespan.** Years. A reaction a person gives to a nudge is part of their record.

**1.8 Provenance.** Decided: the one engine and its budgets (63), the level in the preference
(66), Health read-only on the phone (52), the capture lane rule, "no gamification". Inherited
without a decision: the notification's title "Vo-Cal", the default sound on every fire, the
absence of actions, the ledger that cannot tell a dismissal from a tap. Those get the freer move.

---

## 2. The necessity gate

**Q2.** "Is the product that we are designing really necessary? ... Is innovation in this instance
really necessary?" (I06, q2). Every tracker sends reminders; most send them to everyone, at fixed
hours, with a streak attached. None asks first, none reads the body, none retires a reminder the
person keeps swiping away. The innovation is not the notification; it is the obedience (the
level, the frictions), the body as a clock (a workout ended, a night ended), and the memory (a
nudge dismissed three times goes quiet on its own). **Passes on those three alone.** A fire that
cannot name which of the three it serves fails Q2.

**Q3.** Enrichment, covetousness, or something new. The risk is the badge, the streak, the
"you're on fire". Serein's rule holds here verbatim: "Badge the app icon with a count. Counts are
center-demanding and create anxiety." (S) **Passes if nothing counts: no badge, no streak, no
unread.**

**Q7.** "Does it make them more free or more dependent?" (I06, q7). A reminder the person asked
for and can answer from the lock screen with one press ("Log it") makes them freer than a banner
that only opens the app. A reminder that keeps coming after it was swiped away three times makes
them dependent on finding a setting. **Passes with the retirement rule.**

**Q12.** Convenience or passivity. The "Log it" action opens the voice log; the person still says
what they ate. Nothing is logged for them. **Passes.**

**Q14.** Simpler on the whole? One permission, asked once, after the first log, never for the
person who chose "Nothing". Actions on the notification replace an open-then-tap. **Passes.**

**Q15.** Curiosity. The one place is the long-press: "This wasn't right" with three reasons. It
tells the person the app can be told. **Passes.**

The gate passes. Now the findings against the ask as made.

---

## 3. What holds in the ask

- **Wire it for real.** Today a scheduled fire is a title, a body and a sound; a tap opens the app.
  Beacon's shape (idempotent permission, the delegate) is already here and stays.
- **Health as context, on the phone.** The after-training window and the night's end are the two
  body clocks that matter to a food tracker, and both can be read without sending a byte.
- **Serein's gestures.** The invitation layer's rules are the right ones for a nudge card: "One at
  a time. No carousel ... Quiet dismiss. If dismissed twice, decay aggressively." (S) "Feedback =
  long-press path." (S)
- **Contextually aware by what the person asked.** The level and the frictions are the context
  the person supplied; the mode is the vocabulary (decision 63). The policy's six dimensions name
  what else is available on a phone: time, activity, internal state; not identity, not location,
  not relationships (1.5).

---

## 4. Findings against the ask, structural first

### [N1] REVISE · structural · "Smart" must stay deterministic

WHAT IT IS. "Really smart and contextually aware" invites a model into the loop: a nudge composed
per person, per moment.

WHAT HE SAYS. "The LLM extracts; deterministic code calculates." (AGENTS.md, mission 6); and the
policy: "The designer determines ... The algorithm determines the specific timing, phrasing, and
selection of any given nudge within the boundaries the designer has set ... But it never decides
what 'right' means." (V2)

WHAT FOLLOWS. The engine is already the designer's: a catalog with final copy, triggers over
deterministic signals, budgets that cannot be argued with. Smartness here is more context in the
signals and more memory in the ledger, not a model choosing words. Copy stays final in the
catalog (decision 63); the client never rewrites it.

THE MOVE. Three new deterministic inputs and nothing else: the body's clocks (on the phone), the
person's reactions (durable), and the level and frictions already there. No generated copy.

### [N2] REVISE · structural · Health context cannot travel to the server

WHAT IT IS. The engine plans on the server; a workout is known only on the phone; decision 52
says Health data is never sent.

WHAT HE SAYS. "Nothing must be arbitrary or left to chance." (I06)

WHAT FOLLOWS. Either the phone sends a Health-derived signal (a byte that is still Health data) or
the server plans without the body and the phone adjusts. The second keeps decision 52 whole: the
server composes the day's fires and marks which of them may move with the body; the phone, which
alone knows the body, moves them. The server never learns whether a workout happened.

THE MOVE. A scheduled fire carries a `context` the phone evaluates: `after_workout` (deliver
forty-five minutes after today's last workout ended, if one ended and the slot has not passed;
else at the slot) and `after_wake` (never before thirty minutes after last night's sleep ended, when
sleep is known). The engine decides which nudges carry which; the phone obeys; nothing is sent.

### [N3] REVISE · structural · The ledger cannot tell a swipe from a tap

WHAT IT IS. `recently_shown` records that a nudge was shown on a day. A dismissed card and a tapped
notification write the same entry. The engine cannot retire what the person keeps refusing.

WHAT HE SAYS. "When a nudge generates no response three times: Retire it. Don't escalate. Don't
rephrase and try again. Three non-responses is a signal." (V2); "If dismissed twice, decay
aggressively." (S)

WHAT FOLLOWS. The memory the policy asks for needs a durable record of how the person answered:
dismissed, acted, or told wrong. Server-side, because the phone's ledger is advisory and
prunable and the engine is where the rule lives.

THE MOVE. `nudge_reactions`, append-only (nudge id, kind, created_at). The engine reads them: three
dismissals in a row with no act, thirty days of silence for that nudge; "not for me", silence for
that nudge until the person turns it back on; "too often", its cooldown doubles. Exported with
the record, deleted with the account.

### [N4] REVISE · material · The notification's words are the maker's

WHAT IT IS. Every fire is titled "Vo-Cal", sounds by default, interrupts at the system's default
level, and groups with nothing.

WHAT HE SAYS. "they have to stay in the background when we don't need it and have to be there
when we need it" (T02); Serein: "It never vibrates, never badges, never counts down. It is
available, not insistent." (S)

WHAT FOLLOWS. A title that names the app names the maker; a title that names the subject names
the person's day. A tip about fiber that sounds like an alarm is insistent; a reminder the person
asked for ("Only when I'm slipping") may be active. The difference is the catalog's own
`essential` flag, already there.

THE MOVE. Title by category in the person's words (Your day · Calories · Protein · Water · Produce ·
Fiber · Your plan). Essential nudges are `active` with the system sound; coaching is `passive`,
no sound, no wake. Never `timeSensitive`, never `critical`. One thread, so they stack as one.
Relevance from the catalog's priority, so the summary orders them. No badge, ever.

### [N5] REVISE · material · A tap is the only answer the lock screen offers

WHAT IT IS. A notification tapped opens Today. There is no way to log from it, and no way to say
no to it.

WHAT HE SAYS. "Does it help people or incapacitate them?" (I06, q7)

WHAT FOLLOWS. The two answers a reminder about food has are "yes, now" and "not today". The first
is the voice log, which the Action button already opens from outside the app
(`PendingLaunchAction`); the second is a dismissal the engine should hear (N3).

THE MOVE. One category with two actions: "Log it" (opens the voice log through the same door the
Action button uses) and "Not today" (a dismissal reaction, the nudge's cooldown holds). An
invitation never leaves the app: it is about the person's setup and wants its three answers in
words, on the card.

### [N6] REVISE · material · The card has a close and nothing else

WHAT IT IS. The in-app card dismisses by an × and expands a pro tip. It cannot be told it was
wrong, and it is not swiped.

WHAT HE SAYS. "Feedback: Long-press → 'This wasn't right' → bottom sheet with three reasons" (S)

WHAT FOLLOWS. Serein's long-press is the vault's "retire after three" with a shortcut: the person
says once what three silences would have said. The reasons must be about the nudge, never about
the person, and must each map to one deterministic consequence (N3).

THE MOVE. Long-press on the card: "This wasn't right", a sheet with three reasons: Wrong time
(the nudge's slot moves an hour later for this person, once per reason), Not for me (silence for
that nudge until turned back on in Settings), Too often (its cooldown doubles). Swipe to dismiss
as the quiet dismiss; the × stays for the thumb that does not swipe. No haptic on surfacing,
`select` on dismiss, `warning` never.

### [N7] CUT · material · Sleep, workouts and steps as new nudges

WHAT IT IS. The ask's "using Apple HealthKit" could be read as nudges about the body: you slept
badly, you walked a lot, you trained hard.

WHAT HE SAYS. "No unsolicited nutritional nagging." (Lorenzo and Francesco, the Vocal product
prompt, 2026-06-18); "Location context should never produce a nudge on its own. Location is an
index that makes other nudges more precise." (V2)

WHAT FOLLOWS. The body is an index, not a trigger. A nudge about sleep is a second product. A
nudge timed to the end of a workout is this product, better timed.

THE MOVE. Cut every Health-triggered nudge. Health moves the time of nudges the engine already
chose (N2) and nothing else.

### [N8] REVISE · fine · The permission ask

WHAT IT IS. Asked after the first log, for everyone whose level is not off, as the system sheet
with no words of ours before it.

WHAT HE SAYS. "It does not attempt to manipulate the consumer with promises that cannot be
kept." (I06)

WHAT FOLLOWS. The person just said how much the app should say. The ask should repeat their
sentence back and nothing more: it is their promise being enabled, not ours being sold.

THE MOVE. After the first log, before the system sheet, one line on Today's card: "You asked for a
reminder only when a day goes quiet. Allow notifications to get it." (or the coaching sentence),
with Allow and Not now. Not now is remembered; the row in Settings → Notifications says "Not
asked" or "Asked, not allowed" and opens iOS Settings. The person who chose "Nothing" never sees
any of it (spec Q, S7).

### [N9] HOLDS · The silence rules

The budgets (two a day; one a day and three a week at the quiet level), the quiet hours (09:00 to
21:00), the cooldowns, the invitation's fortnight: all stand. New above them: the policy's sacred
silences that the phone can honor without a byte leaving it: no fire within thirty minutes of
waking (N2), none during the forty-five minutes after a workout ends (the window the after-training
nudge waits for), none while a capture is running.

### [N10] OPEN · Background re-planning

WHAT IT IS. The plan is fetched when the app opens or after a log. A person who stops opening the
app, the one gone_quiet exists for, has only the fires scheduled on their last visit.

RECOMMENDATION. A daily background refresh (`BGAppRefreshTask`, morning) re-plans and reschedules
so the quiet person still hears the one reminder; HealthKit background delivery for workouts wakes
the app to move the after-training fire. Both are off the capture lane by construction. Built
here as the recommendation says; OPEN because background scheduling cannot be exercised in CI,
only on a device over days. The handoff names the test.

---

## 5. Diagnosis

The ask's shape was right and its words were the maker's: "smart" and "HealthKit" read as more
voice and more triggers, when the person has just asked for less voice and better timing. Every
move above is the same move: the engine keeps deciding what and whether (deterministic, the
designer's); the phone, which alone knows the body and the thumb, decides when (N2) and listens to
the answer (N3, N5, N6); the words on the lock screen name the person's day, not the maker (N4).

**The short list, in order.**
1. The notification wired: title by subject, level by essentialness, one thread, two actions, no badge, no sound on coaching (N4, N5).
2. The answer remembered: `nudge_reactions`; three dismissals retire a nudge for a month; the long-press says it in one (N3, N6).
3. The body as a clock, on the phone: after a workout, after waking; never as a trigger (N2, N7, N9).
4. The permission asked in the person's own sentence, once, never for "Nothing" (N8).
5. The daily re-plan in the background, for the person who stopped opening the app (N10).

---

## 6. The design, corrected (DIETERIFY passes applied)

Tokens, radii, type and spacing are `docs/DESIGN.md`'s. The gesture vocabulary is the one table
there; this adds three rows to it (6.6).

### 6.1 Restated purpose

A reminder reaches the person only when it is theirs: asked for, timed to their day, silent
otherwise.

### 6.2 The notification (element inventory)

| Element | Rule |
|---|---|
| Title | The subject, in the person's words, by the catalog's category: consistency "Your day" · calories "Calories" · protein "Protein" · water "Water" · produce "Produce" · fiber "Fiber" · plan "Your plan". Never "Vo-Cal", never the nudge id |
| Body | The catalog's message, verbatim. The pro tip never travels to the lock screen |
| Interruption | `active` with the system sound for an essential nudge (it protects the habit the person asked us to protect); `passive`, no sound, for coaching. Never `timeSensitive`, never `critical` |
| Relevance | The catalog's priority over 100, so iOS orders the summary as the engine would |
| Thread | One, "nudges", so the day's fires stack as one |
| Badge | None, ever (S) |
| Actions | "Log it" (opens the voice log through `PendingLaunchAction`; foreground), "Not today" (a `dismissed` reaction, no app open). An invitation has no notification |
| Identity | `nudge.<id>`, as today, so a re-plan converges the schedule |

### 6.3 The plan's new fields (additive, `nudges/schemas.py`)

`ScheduledNudge` gains `context`: `after_workout: bool` (the engine sets it on `protein_gap` and
`hydration_low`: the two nudges whose moment is after training) and `after_wake: bool` (set on
every fire scheduled before 11:00). `NudgeCard` gains `essential: bool` (the catalog's flag, so the
phone sets the level without a second table) and `title: str` (the subject, so the words are the
server's). A build-31 client ignores all four.

### 6.4 The reactions (`nudge_reactions`, append-only)

| Kind | Who writes it | What the engine does |
|---|---|---|
| `dismissed` | the card's × or swipe, the notification's "Not today" | three in a row with no `acted` between: that nudge is silent for 30 days |
| `acted` | "Log it" on the notification, a log within an hour of a fire or a card | resets the run |
| `wrong_time` | the long-press sheet | that nudge's slot moves one hour later for this person (at most twice; the quiet hours still hold) |
| `not_for_me` | the long-press sheet | silent until the person turns it back on in Settings → Notifications, "Muted" |
| `too_often` | the long-press sheet | that nudge's cooldown doubles for this person |

`POST /nudges/reactions` (one row), read by `POST /nudges/plan` through a store. Exported with the
record (`account/export.py`), deleted with the account. Counts only in logs (MUST NOT 5).

### 6.5 The body as a clock (on the phone, `HealthKitService`)

Two reads join active energy: today's workouts (end times) and last night's sleep (end time). The
priming step's line names all three: "What you burned, your workouts and your sleep, read on your
phone, never sent. Reminders fit around them." `NudgeNotificationService.reschedule` applies, per
fire: `after_workout` → the later of the slot and the last workout's end plus 45 minutes, when a
workout ended today and that time is still ahead and inside quiet hours; `after_wake` → the later
of the slot and sleep end plus 30 minutes, when sleep is known. A fire moved past 21:00 is dropped,
not delayed into the night. HealthKit background delivery for workouts wakes the app to re-plan;
the server never learns.

### 6.6 The card's gestures (three rows for DESIGN.md's table)

| Gesture | Where | What it does |
|---|---|---|
| Swipe (either way) | the nudge card | The quiet dismiss (`dismissed`), `select` haptic, the card leaves as the meal rows do |
| Long-press (context menu) | the nudge card | "This wasn't right": Wrong time · Not for me · Too often (6.4). One sheet, three rows, no text field: the reasons are the design's, the words are the person's to pick |
| Long-press (system) | a nudge notification | Log it · Not today (6.2) |

No haptic when the card appears (S: never vibrates on surfacing). The × stays.

### 6.7 The permission (N8)

After the first log, for a level other than "Nothing", once: the card on Today reads the person's
own sentence ("You asked for a reminder only when a day goes quiet." / "You asked to be coached
along the way.") with "Allow notifications" and "Not now". Allow shows the system sheet. Not now
is remembered (no re-ask; Settings → Notifications, Delivery: "Not asked yet", a tap asks). The
person who chose "Nothing" never sees it; their Delivery row reads "Not asked".

### 6.8 Settings → Notifications gains

Under the three sentences: "Muted" (the nudges the person said were not for them, each a row with
its subject and "Turn back on"), shown only when there is one. Nothing else.

### 6.9 The states, enumerated and decided

- **A fire while the app is open**: the card, never a banner (the delegate shows nothing in the
  foreground; today it shows a banner over the open app).
- **A fire during a capture**: held (the delegate suppresses while the voice log is on screen); the
  plan is re-fetched after the log and the fire returns if still due.
- **A workout that ends after the slot**: the fire stays at the slot. The body may advance a fire's
  reason, never make it late past quiet hours.
- **No workout today**: the slot, as today.
- **Sleep unknown** (no watch, no permission): the slot, as today.
- **Three dismissals**: the fourth plan omits that nudge; nothing says so. After 30 days it may
  return; a fourth run of three silences it again.
- **"Not for me"**: the nudge joins "Muted" in Settings; the engine never plans it until it leaves
  that list.
- **"Log it" from the lock screen**: the app opens on the voice log, listening (the Action button's
  door); the reaction `acted` is written; the ledger entry stands.
- **"Not today"**: no app open; the reaction is written when the app next runs (queued locally,
  idempotent by nudge id and day).
- **Permission denied in iOS**: planned fires are still scheduled (iOS drops them); Settings says
  so and opens iOS Settings, as today.
- **A server that predates the fields**: no title (the phone falls back to the category word), no
  context (the slot), no essential flag (passive); reactions 404 and are dropped.
- **Before the migration**: `POST /nudges/reactions` fails; the phone drops the reaction silently
  and the engine plans as before.

### 6.10 The claim audit

A notification claims nothing: its body is the catalog's sentence, which already passed the
banned-words list. "Log it" opens the voice log and logs nothing itself. "Not today" is exactly a
dismissal. The permission card repeats the person's own sentence. "Muted" lists exactly the
nudges the engine will not plan. The body's clock moves a fire's time and never its words.

### 6.11 The restoration check

Did the passes remove anything warm? The default sound on every fire carried urgency; it stays
where urgency is the person's (essential) and leaves where it was the maker's. The title "Vo-Cal"
carried the brand; the brand is the app icon beside every notification already. The × carried
the quiet exit; the swipe joins it. Nothing came out that did not go back in another place.

### 6.12 Evidence

Built the same evening (`e405094` the API, `b40dc8a` the phone). Pinned: the reactions' rules and
the plan that remembers them (`test_nudges_api.py`); the notification's content from the card
alone, the reaction queue's idempotency, the body clock's five cases and the next morning's date
(`RenderTests.testNotificationContentAndFireTiming`); the sheet and the permission card drawn
(`testNudgeReasonsSheetAndPermissionCard`, goldens to record on the pinned simulator). The rest
is a week on a phone, written out in the handoff: the quiet person's morning fire arriving with
the app unopened (N10), the after-training fire landing after a real workout, the swipe and the
long-press under a thumb. The restoration check (6.11) re-read after the build: the × stayed
beside the swipe, the sound stayed on the essential fires, the brand is the icon; nothing warm
left without a place.

---

## 7. The ship gate, pre-filled for the builder

1. **Purpose.** A reminder reaches the person only when it is theirs. Serve it or do not ship.
2. **Honesty.** No badge. No sound on coaching. The permission card in the person's sentence. "Muted" is exactly what is muted.
3. **Butler.** Budgets unchanged. Three dismissals silence. Sacred silences honored on the phone.
4. **Order.** Strip the titles: does the body alone say the subject? (Expected no for calories and protein; the titles stay.)
5. **Register.** No engine word on the lock screen or the sheet: no "essential", no "cooldown", no nudge id.
6. **Detail.** The states of 6.9, each exercised on a device.
7. **Year five.** A new body clock is a new `context` key; a new reason is a new kind; neither needs a client build to be ignored.
8. **Resources.** Nothing added that nobody needs: no text field on the sheet, no sleep nudge, no step count.
9. **Subtraction.** What can still come out: the ×, if the swipe proves enough; the pro tip, if nobody opens it.
10. **Restoration.** Section 6.11, re-read after the build, not before.

"Have I succeeded in improving things? Making them better than others did? Is my design good
design?" (I06, Boston, October 1984, archive 1.1.5.1)
