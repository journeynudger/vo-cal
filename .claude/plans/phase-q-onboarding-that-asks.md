# Phase Q: The onboarding that asks

> Status: Active (decision 66, 2026-10-04; Lorenzo: "write the spec first, dieter rams style, then build it")
> Owner: @lorenzo
> Branch: `claude/confident-volta-7er84f` (on top of Phase P)
> Next: the first run on the Mac; S6 is Lorenzo's
> Design: `docs/design/onboarding-that-asks-spec.md` (the Rams REVIEW of the proposal and the corrected design). Where this file and the spec differ, the spec wins.

## Goal

Two questions after the mode, each changing something the person sees that day, and a copy pass
over the whole intake. "How much should Vo-Cal say?" asks the delivery level in the person's own
words and stores it in the preference, where the server reads it (today it is a phone setting the
record never sees). "What makes tracking hard for you?" asks four frictions, any or none, and each
moves exactly one thing: an evening reminder, the amount checks' bar, the bar's hint, the usual
toggle's default. Nothing is reworded per person; no answer is ever named back as a kind of
person. The surface: `supabase/migrations`, `services/api/src/api/{tracking,nudges,parser}`,
`apps/ios/VoCal/{Views/Onboarding,Views/Settings,Views/Capture,Views/VoiceLog,Services}`,
`scripts/beta-metrics`, `docs/`.

The capture core, the parse ladder's resolution, the protocol engine and the composed Today do
not move. The mode question (decision 57) is not reopened.

## Decisions taken with this plan

Recorded as decision 66 in `.claude/memory/decisions.md`. Open: S6 (two of the three benefit
interstitials as candidates to come out; the owner decides from the spec).

---

## Tasks

### Q0. Record the decision

- [x] **Step 1.** Decision 66 in memory; the master plan row; `.claude/memory/product.md`. *Landed with the spec, fcfcf02.*
- [x] **Commit:** with the spec (fcfcf02).

### Q1. API: the level and the frictions in the preference, obeyed

- [x] **Step 1.** Migration `20261004000003_tracking_experience.sql`: `tracking_preferences` gains `nudge_level text` (nullable: never chosen) and `frictions jsonb NOT NULL DEFAULT '[]'`. `docs/DATABASE.md` row updated. The user runs `make db-migrate` or Deploy applies it.
- [x] **Step 2.** `tracking/schemas.py`: `NudgeLevel` (essential, standard, off), `Friction` (forgetting, portions, eating_out, time); `TrackingPreference` gains `nudge_level`, `frictions`, `experience`; `TrackingUpdate` gains `nudge_level`, `frictions`. `tracking/projection.py`: `experience_for(level, frictions)` is the one place (offers_invitations, evening_reminder, amount_checks, bar_hint, seed_usuals). Store and router carry the fields; a client that sends neither changes nothing.
- [x] **Step 3.** `nudges/router.py`: the stored level wins over the request's when the preference has one; invitations only at `standard`; `planned_meals` and `evening_reminder` signals. `nudges/catalog.py`: `evening_unlogged` (essential, slot 20:00, cooldown 1, spoken only when the person asked). `nudges/engine.py`: the trigger.
- [x] **Step 4.** `parser/router.py` (and the photo path): the amount checks at the variant bar for `portions`; the threshold stays a parameter of `clarify.py`, never a second constant. `scripts/parser-eval` SCORES unchanged (the default bars do not move).
- [x] **Test:** `tests/test_tracking_api.py` (the fields, the experience, the merge), `tests/test_nudges_api.py` (the evening reminder scheduled and immediate, silent unasked, the stored level over the request, the invitation gate), `tests/test_clarify_merge.py` (oatmeal: under the standard bar, over the variant bar, asked only when eager).
- [x] **Acceptance:** a person who chose "Nothing" gets an empty plan whatever the client sends; a person who said "I forget" gets the evening reminder and nobody else does; the SCORES file is byte for byte the same. *932 passed, ruff clean, SCORES unchanged.*
- [x] **Commit:** `feat(api): the preference carries how much the app says and what gets in the way`

### Q2. iOS: the two questions, the words, the obedience

- [x] **Step 1.** Intake: two steps after the mode in every mode (`.voice`, `.friction`), a `ChoiceList` for the first, a multi-select list for the second (nothing preselected; continuing with nothing ticked is an answer). The copy of spec 6.6 applied to every screen, the welcome line included.
- [x] **Step 2.** Models: `NudgeLevel` on the wire, `Friction`, `TrackingPreference.nudgeLevel/frictions/experience` (tolerant), `TrackingUpdate.nudgeLevel/frictions`; `IntakeDraft` carries both; the onboarding writes them with the mode (and again after sign-in) and sets `NudgeCenter.level` at once so the first log's permission ask obeys "Nothing".
- [x] **Step 3.** `NudgeCenter` adopts the stored level on every refresh (the phone's value is a cache); Settings → Notifications becomes "How much Vo-Cal says" in the three sentences and writes the preference; Settings → How I track gains "What gets in the way".
- [x] **Step 4.** The obedience: the bar's hint for `eating_out`; the tour's photo step before typing; "Save as a usual" on by default for `time` until three usuals exist; the mock services carry the fields.
- [x] **Test:** render tests for the two new screens and the Notifications page; the composer twin for `experience` pinned (`testVoiceAndFrictionChoosers`, `testNotificationSettingsInThePersonsWords`, `testExperienceComposerMirrorsTheServer`; How I track's render gains the frictions).
- [ ] **Acceptance:** `bin/ios-app-build` zero warnings (CI); a fresh install in each mode asks the two questions and Today, the bar and the result obey them. *CI's iOS job is the compile proof (no Swift toolchain here); ticked when green.*
- [x] **Commit:** `feat(ios): the onboarding asks how much to say and what gets in the way`

### Q3. The maker's side and the docs

- [x] **Step 1.** `scripts/beta-metrics`: who asked for what (the latest preference per person: mode, level, frictions), so the six numbers can be read by answer.
- [x] **Step 2.** `docs/DESIGN.md` §2 and the components; `docs/UI_VERIFICATION.md` rows; `apps/ios/AGENTS.md`; `docs/ARCHITECTURE.md` if the endpoint shape changed; the handoff; memory.
- [x] **Commit:** `docs: the onboarding that asks`

## Exit Criteria

- A fresh install is asked, in its own words, how much the app should say and what gets in the way, and the answers act the same day.
- The delivery level has one owner (the preference), is exported with the record and is deleted with the account.
- No copy forks by answer; no answer is named back to the person.
- `scripts/check-api` green; SCORES unchanged; CI's iOS job green.

## Progress log

| Task | Status | SHA |
|---|---|---|
| Q0 Decision | done 2026-10-04 | fcfcf02 |
| Q1 API | done (the migration awaits `make db-migrate` or Deploy) | 37c2e1a |
| Q2 iOS | built; CI compiles it | 18f3aa8 |
| Q3 Docs | done | Q3-SHA |
