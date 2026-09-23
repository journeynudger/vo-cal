# 01. What keeps breaking, in the owner's words

Each item: the verbatim quote, when and how it was reported, my interpretation (a separate
sentence, visibly mine and therefore fallible), where it probably lives, and what is out of
scope so nothing gets re-litigated.

## 1. "Highest priority is still getting proper CI tests in place so merges have to have some level of verification"

- **Quote (Bill, via Lorenzo, 2026-09-23):** "Neither your serein nor mine do this and it
  gives me anxiety to the extent that I just rarely change things for worry of regressing."
- **Interpretation:** the gate that exists must prove the things that actually break
  (the app compiles warning-free, the voice runtime scenarios pass, the parser corpus does
  not regress, the API suite passes), it must run on every push, and a local gate must
  refuse a push that fails it. Today's CI proves the API suite and the 53 library tests
  only (`00-ground.md`).
- **Lives in:** `.github/workflows/ci.yml`, a missing `.githooks/pre-push`, the ratchet
  tables (this phase).
- **Closed by:** the CI rewrite and the push hook (Phase 3.4), asserted by
  `TIDY-CI-*` and `TIDY-HOOK-*` rows so nobody can quietly delete a gate.

## 2. "no em dashes in any user-facing copy"

- **Quote (Lorenzo, standing rule, restated 2026-09-23):** product-wide; "a product-wide
  sweep already done".
- **Interpretation:** the sweep (commits `c25bc47`, `5af5227`, 2026-08-23) lived on the
  unmerged `feature/help-tour` branch, so main kept four literals in the app and five in
  the API copy. A rule, not a sweep, is what keeps it true.
- **Lives in:** any `Text("…")`, question, tip, HTTP detail.
- **Closed by:** the two commits cherry-picked onto this branch, the last placeholder
  fixed, `TIDY-WORDS-001` (Swift) and `TIDY-PY-WORDS-001` (Python) at a ceiling of zero.
  This is the Phase 1.4 slice: the Swift rule was watched failing on the pre-fix file
  (`observed=1 max=0`, `SettingsView.swift:327`) before it passed.

## 3. "Lifecycle of a capture must be defined"

- **Quote (Bill):** "editing transcriptions, typed text, etc. Deleting a capture (recently
  deleted w/ 30 day recover?)".
- **Interpretation for Vo-Cal:** the phone-to-server life of a capture is specified across
  `docs/VOICE_CAPTURE.md`, `docs/INVARIANTS.md` and `docs/ARCHITECTURE.md` but never as one
  page in travel order, and the deletion half is thin: a meal is tombstoned with no way
  back and no purge. Captures themselves are never deleted except with the account.
- **Lives in:** `services/api/src/api/meals/router.py` (`delete_meal`, `_reresolve`),
  `MealsStore.tombstone`, the Today screen's delete menu.
- **Closed by:** `docs/CAPTURE_LIFECYCLE.md` (Vo-Cal's own, phone to server), Recently
  deleted with Restore for thirty days (server + Settings), documented purge behavior.

## 4. "bulk correct common typos (Codex/Codecs, Tekhla/Thekla, Claude/Claw)"

- **Quote (Bill):** "How to ask user for clarification for conversations and other cases.
  Also consider cases where you have to maybe bulk correct common typos".
- **Interpretation for Vo-Cal:** the typo class here is a food or brand the transcriber
  mis-hears the same way every time ("oil coast" for Oikos). The user's rename on the edit
  sheet is the teaching gesture; today it teaches nothing because a rename through
  `/parse/refine` supersedes the parse and the confirm-time diff compares against the
  superseded parse, so no correction row is written and nothing learns.
- **Lives in:** `meals/router.py::_record_corrections` (diffs against the latest parse,
  not the root of the chain), `parser/router.py::parse`.
- **Closed by:** corrections diffed against the root parse of the supersedes chain, a
  per-user learned-corrections pass applied deterministically at parse time and recorded on
  the parse row, and a Settings list of what Vo-Cal learned with Forget.

## 5. "voice tracking is hit or miss"

- **Quote (Lorenzo, 2026-09-23):** "sometimes everything is on point, other times
  everything is wrong."
- **Status:** closed before this pass (branch `feature/voice-consistency`, merged as
  `a3ed8f5`): identity resolved once and persisted, curated head before live sources,
  calorie-eval 72/72, consistency-eval 7/7. Pinned by `tests/consistency_eval.py`,
  `test_resolver.py::test_identity_never_depends_on_the_amount` and the refine test in
  `test_parse_api.py`.

## 6. "figure out why fly bill is so high"

- **Quote (Lorenzo, 2026-09-23):** "make it cheaper with the same high quality".
- **Finding (Fly API, `fly auth token`, read-only):** the `vo-cal` app is one
  shared-cpu-1x 512 MB machine, always on: about $3 a month. All five organizations on the
  account report `paidPlan: true`, including two empty "Vocal" organizations (`vocal`,
  `vocal-262`; the second has a card on file and no apps). The Beacon organization runs a
  1 GB machine plus a started 512 MB machine on a "suspended" app; the Serein organization
  runs a 512 MB machine with a 10 GB volume. Plan fees per organization, not vo-cal's
  compute, are where the money goes; the invoice itself is only visible in the dashboard.
- **Out of scope for this repo:** changing another organization's plan or apps. Recommended
  in the final report.

## Out of scope for this pass

Mac capture, watch capture, CloudKit, on-device SpeechAnalyzer (Serein-only questions).
Authentication, account deletion, payments, the Supabase schema (a migration is user-run)
and the API shapes the shipped iOS build 26 reads: frozen (Phase 2.6).
