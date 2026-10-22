# Handoff, 2026-10-22: the new endpoints, smoked and audited line by line

Lorenzo's ask: run the smoke for the new endpoints, test end to end what can be tested here,
fix what the audit finds, and deploy to main. CI's macOS jobs were not the gate (the nightly UI
audit is red for its own reason, PR #29); this Linux box has no Xcode, so no Swift changed and the
iOS defects are listed below for a Mac session.

## How it was tested

- `scripts/smoke-prod` now checks the personalized tracker's endpoints (14 steps, `bebb5fd`):
  Today's mode and panels, `GET /tracking`, the nudge plan, the bar answering without changing
  anything, the meal plan and its suggestions, the protocol (made once for the throwaway smoke
  account), "Build it for me", the check-in, and the export's new tables. Deploy runs it against
  production after the migrations and the release.
- A real local stack in the scratchpad, not the fakes: Postgres 16 with every migration and the
  seed, PostgREST 12.2.3 capped at 1000 rows as Supabase is, an edge serving JWKS, the REST proxy
  and Storage, and the API on :8001 in production posture (no DEBUG, TEST_MODE or DEV_ENDPOINTS,
  ES256 tokens). A whole person's life was driven through it (onboarding in each mode, logs, the
  bar and its Undo, a plan drafted and saved, nudges and reactions, a check-in, a photo and an
  audio capture, the export, the deletion checked row by row and blob by blob), plus a person past
  the row cap and bursts of concurrent writes.

## What the audit fixed (one commit per class, each with the test that failed before it)

| Commit | What it is |
|---|---|
| `17f6d26` | A concurrent write never reverts another field's change: the store owns the version and reruns the caller's merge; a burst it cannot carry is a 409. Measured: 12 of 12 toggles lost a change before, 0 after. |
| `79575d3` | Deleting the account deletes its meal photos (`capture-photos` was left out). |
| `7b04dc4` | The 413 constant Starlette deprecated. |
| `e9eb70a` | A meal plan prices each food as itself: the composed-meal grammar zeroed a drafted burrito bowl and half a typed Chipotle bowl; a food saved without its weight is drafted in servings. |
| `ad071f2` | A recalibration measures the week from the protocol it is on (the basis weight is stored). |
| `e235a55` | A recalibration says only what it does, in pounds; a clamp that prevents the step is named. |
| `114de39` | The fiber why quotes the rate, the protein why the engine's minimum. |
| `9c131ac` | The calorie nudges speak to the number Today prints (the week's adjusted day). |
| `f10a8e2` | Nudges keep their timing promises (wrong time clamps before quiet hours) and count each answer once; a spent budget still lists what is muted. |
| `6caadb0` | One timezone read; a name it cannot use reads as UTC, never a 500. |
| `a18e53e` | The bar changes only what changes: a mute writes and undoes only what moves; before a protocol a number points to My details; no line promises a reminder that is off; Undo puts back a declined offer; meal-plan mode owns no tiles; moving into habits empties "Also show" (decision 72). |
| `060d667` | The bar reads only what was asked: questions, refusals and changes bounded in time are no change, in the rules and in the model's prompt; the model read is bounded inside the phone's 15 s; every `?date=` parses inside what the day arithmetic holds, and the bar reads a far date (a Buddhist-calendar 2569) as today. |
| `3c16c28` | Every read of a person's record reaches past the row cap: the newest version by the index, one row; the export and the deletion page every table; the export carries parses and corrections and no account id. |
| `181f0b3` | Today's lines agree with the numbers drawn beside them (counted from the phone's wholes) and with their day ("that day", never "so far" on a past day); a grouping row is no food of unknown sugar. |
| `dcc72e1` | The week's numbers stay on the server in habits; a check-in without the weight or how the week went is answered with a hold that says so (a 422 the phone read as a lost connection, and every retry stored another check-in). |
| `13bddd4` | A drafted plan lands where it was balanced: whole pieces round toward the aim and the weighed foods settle the rest (rounding alone had pushed more than a quarter of balanced drafts past the 10 percent check); no phantom "added" food; a food is its head noun; an empty draft is a 422. |
| `fe3bca7` | The plan card ticks a slot named "Breakfast"; a client cannot claim a coach wrote its plan; the receipt's provider failures are a 503; no photo or receipt fixture answers where real records live; guidance never quotes "½"; the nudge plan takes the phone's zone. |

Verified at the end: `scripts/check-api` 1,197 passed; `scripts/parser-eval` unchanged (F1 1.000,
field accuracy 1.000); the extended smoke green against the local stack; past the row cap, zero
failures; eight concurrent saves, 7 and 6 landed with the rest an honest 409, no 500.

## For the Mac session (iOS, no Swift changed here)

- **Check-in** (`CheckInView`, `CheckinService`): gate Submit until weight and adherence are in;
  parse the number with a POSIX locale; keep the 201's id so a retry is not a second check-in.
  Server side, a short check-in is now answered (`dcc72e1`).
- **Day strings**: the bar (`MealCaptureService.answer`) uses `Calendar.current`;
  `ProgressSettingsView` and `CheckinService` format with the phone's calendar and locale. A Thai
  iPhone sends 2569. Use `LiveTodayService.dayString` everywhere. The server reads a far bar date
  as today (`060d667`).
- **printsNumbers** defaults to true until the preference loads (`TodayView`, `SettingsView`): a
  person in habits can see numbers for a moment. The summary no longer sends them (`dcc72e1`).
- **Mock twins**: `PanelComposer` still lists the five's tiles as meal-plan mode's own;
  `MockTrackingService` keeps "Also show" on the move into habits; `MockAssistant`'s rules lack
  the question, refusal and time guards. Mirror `a18e53e` and `060d667`.
- **The bar's Undo** says "Undone." before the reactions it posts have landed.
- **Nudges**: send `tz` with `POST /nudges/plan` (accepted from `fe3bca7`); every immediate card is
  marked shown though Today draws it only on a day without meals.
- **The plan builder**: a 422 from "Build it for me" must leave the rows as they were (the server
  no longer returns an empty draft); Cancel; the receipt notice at the 40-food cap; strict enum
  decodes in the Undo payload and the drafted slots should be tolerant.
- **The check-in's frictions**: it writes a frictions list it never loaded, overwriting the
  person's.
- **"You wrote last week"** shows for a note written minutes ago.

## Decisions for Lorenzo (each a trade-off, not a defect)

- **G4**: the calorie pass grows dishes and snacks with no protein or fat guard; guarding them
  can leave a short list under its calories. Which bound wins?
- **N4**: the essential level's weekly cap never binds (the ledger keeps one day per nudge).
  **N8**: a reminder parked overnight fires at 09:30 whatever the anchor. **N9**: the invitation
  cooldown is per card, not per direction. **N12**: "New week, clean page." fires on the 1st of
  the month whatever the weekday.
- **T8**: an unknown stored mode reads as the five (fails open to numbers).
- An admin recompute can undo a person's applied revision.
- `intake_responses` and `week_plans` have no unique version index (a migration, Lorenzo's to
  run); the stores now read the newest row correctly, but a concurrent pair can still write the
  same version.

## Follow-ups found in passing (server, not this PR's)

- The admin review reads meals, corrections and parses platform-wide in single selects: past
  1,000 rows its numbers undercount (`admin/store.py`).
- `/parse` and `/parse/photo` answer 500 on a model provider error (the receipt now 503s).
- `FakeTranscriber` answers any audio with a recorded transcript when a hosted deployment lacks
  `ELEVENLABS_API_KEY`: the capture path, so it needs the voice protocol (`docs/VOICE_CAPTURE.md`).
- PF2: a typed plan slot could carry its `parse_id`, as `POST /meals` does, so a save prices it
  from the parse's own identities (needs the client to send it).
