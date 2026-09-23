# The life of a capture, phone to server

The one page in travel order. Each stop names the proof that licenses it, the address that
owns it, how it fails, how it converges, and what pins it. Sections of `docs/INVARIANTS.md`
are cited by number. Read this before touching the upload worker, the outcome ledger, the
meal lifecycle endpoints or the corrections diff; `docs/VOICE_CAPTURE.md` stays mandatory
for the mic-hot path itself.

## 1. Before "Saved": the capture path

| Stop | Claim the app may show | Proof | Address |
|---|---|---|---|
| Intent | nothing yet ("Hold on") | the tap | `VoiceLogViewModel.startCapture` |
| Accepted, mic active | "Hold on" | the coordinator took the request | `VoiceCaptureCoordinator.toggle` |
| Confirmed listening | "Listening" | byte-flow verdict from the liveness kernel (`.started`) | `VoCalVoice` kernel; the medium haptic marks it |
| Sealing | "Saving" | the stop was accepted; the muxer is finalizing | `VoiceCAFMuxer` (repair fuse: a repair that killed the last process is never retried) |
| Saved | "Saved" | `LocalCommitReceipt`: the outbox row and the blob are durable (`.finalized`) | `CaptureOutbox.enqueue`; the settled double-thump haptic fires here and only here |

A deferred commit (`.deferred`) shows "Saving" and no haptic until the outbox converges
(INVARIANTS 2). The capture path reaches nothing below this line: delete every later stage and
a capture still saves (capture-path isolation, AGENTS.md).

## 2. Upload: level-triggered, off the capture path

- Address: `CaptureUploadWorker` (`apps/ios/VoCal/Services`), reaching the outbox only through
  `CaptureRelayDoor` on the coordinator. The planner decides (`RelayPlanner`), the worker
  performs, the outbox records: same storage, never the same authority.
- Trigger: a pass runs at start, when a capture commits (the commit observer hands over a
  receipt and returns), when the outbox changes on disk, when the scene becomes active, and at
  the planner's next wake. A pass derives its work from the outbox's durable relay state,
  never from the event that woke it (INVARIANTS 9).
- Ladder: lease with deadline; on a transient failure (transport, 408, 429, 5xx) requeue with
  30 s doubling backoff capped at 30 min; after twenty attempts, quarantine. A permanent
  refusal (413 over the 50 MB cap, 422) quarantines at once. A 401 pauses the queue until the
  session changes. Quarantine is visible in the outbox's operational summary, never silent.
- The voice sheet uploads eagerly through the same worker (`uploadNow`), so one bookkeeping
  covers both and a sheet closed mid-upload leaves a job the next pass finishes.
- Pinned by: self-test `upload_worker_converges` (a real capture, a stub transport failure,
  the clock moved past the backoff, the second pass uploads and leaves no queued job);
  `RelayPlanner` unit tests in `Tests/VoCalCaptureTests`.

## 3. Uploaded: the server's ground truth

`POST /captures` stores the blob first, then the row, and answers "uploaded" only after both
are durable. Idempotent by `client_capture_id`, so every replay returns the same row. The row
is immutable; a capture is never deleted except with the account (INVARIANTS 1).

## 4. Unfinished: a saved recording the person can always find

- The outbox answers "what was recorded"; `CaptureOutcomeLedger` (`Sources/VoCalCapture`)
  answers "what happened next": `logged` with the meal id, or `dismissed` with a reason. One
  JSON record per line, append-only, last record wins; a torn tail from a crash mid-append is
  skipped and closed before the next record; past 512 KB the file keeps its newest 2,000
  records (INVARIANTS 8).
- `CaptureOutcomeStore` lists, per local day, the committed captures with no outcome: Today's
  "Unfinished" section. Finish resumes the derived pipeline from the committed audio
  (`VoiceLogViewModel.resume`); Discard is a ledger mark, the audio stays. The voice-log model
  records every capture of a session as logged on the server's confirmation and an empty
  transcript as dismissed, so silence never nags.
- Pinned by: self-test `unfinished_capture_surfaces`; `CaptureOutcomeLedgerTests`.
- Known edge: a capture recorded while browsing a past day lists under the day it was
  recorded and resumes to that day (docs/restructure/04-findings.md).

## 5. Transcribed and parsed: derived, immutable, retryable

- `POST /transcribe` writes the `transcripts` artifact; `POST /parse` writes the `parses`
  artifact (docs/PARSER_CONTRACT.md). A failure at either stop is never a capture failure
  (INVARIANTS 14).
- Learned names (`meals/learning.py`): before resolution, `/parse` applies what this person
  renamed before, deterministically, and records each rename on the parse row with the name
  as heard. The map is derived from the append-only corrections rows (`name` teaches,
  `name_forget` unteaches, latest wins) through one owner-scoped query
  (`Database.select_owned_via`, a PostgREST inner embed through `meal_logs`).
- Every parse row carries the chain bookkeeping: `root_parse_id`, `origin_indices` (each
  item's index in the root parse, kept straight through refines and removals) and
  `learned_names`.
- `POST /parse/refine` answers a question, renames, or removes an item, and writes a new
  parse row that supersedes the previous one; the amount answer grammar is
  `RefineAmountAnswer` (`Sources/VoCalCore`) on the phone and `clarify._AMOUNT_ANSWER_RE` on
  the server, the same table tested on both sides.

## 6. Logged: the durable row and the teaching

- `POST /meals` re-resolves the confirmed items server-side (never client math), writes the
  `meal_logs` row, and diffs the confirmed items against the ROOT of the parse chain into
  append-only `corrections`: a rename or a removal made through refine lands as a row, grams
  diff server-vs-server against the latest parse so an unedited item never diffs.
- Confirming a learned name as applied teaches nothing new; reverting it to the name as heard
  appends `name_forget`; a third name re-teaches. Settings > Learned names lists the map
  (`GET /meals/learned-names`) with Forget (`POST /meals/learned-names/forget`, an appended
  row). Nothing is stored twice; nothing is deleted.
- Edits (`PUT /meals/{id}`) and voice appends (`POST /meals/{id}/append`) re-resolve and keep
  the row's provenance; the row is mutable, its corrections are not.

## 7. Deleted: a tombstone with a way back

- `DELETE /meals/{id}` sets `deleted_at`; the row never leaves. For `RECENTLY_DELETED_DAYS`
  (30, `meals/store.py`) the meal is listed by `GET /meals/deleted` with the instant its window
  closes and `POST /meals/{id}/restore` clears the tombstone: items, totals and corrections
  come back exactly as they were. One live copy is the rule: a restore that would collide with
  an outbox replay of the same client meal id is a 409; past the window, 410.
- Purge: `POST /admin/meals/purge-deleted` hard-deletes tombstones past the window (with their
  corrections, as the FK cascade would), audited before it touches user data, `?dry_run=true`
  first. The operator runs it; there is no scheduler. The app hides a tombstone the moment
  the window closes, so the purge changes nothing a person can see.
- Captures, transcripts and parses are never purged by this sweep.

## 8. What each rung is pinned by

| Rung | Test or rule |
|---|---|
| saved, deferred, repair fuse, quarantine | self-tests golden_path, process_death_recovery, caf_repair_on_recovery, quarantine_on_corruption, repair_fuse_quarantines |
| upload converges | self-test upload_worker_converges; RelayPlanner tests |
| unfinished | self-test unfinished_capture_surfaces; CaptureOutcomeLedgerTests |
| learned names, root diff | `tests/test_learned_names.py` |
| recently deleted, restore, purge | `tests/test_recently_deleted.py` |
| the claim words | TIDY-CLAIM-001 (`Tests/VoCalCoreTests/TidyTests.swift`) |
| the capture path's isolation | TIDY-CAPTURE-001 |
