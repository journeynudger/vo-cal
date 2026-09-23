# 02. The map

## The critical path

**The mic button to a durable local receipt, then that receipt to a row on the server.**
Everything else in this system is secondary by definition: the dashboard, nudges, check-ins,
protocols, the admin panel, nutrition pricing. A failure on this path is unacceptable; a
failure anywhere else is a bug.

## The path, stop by stop (reading order for a newcomer)

1. **The button.** `apps/ios/VoCal/VoCalApp.swift` (`AppRootView.micButton`) opens the voice
   log; `apps/ios/VoCal/ViewModels/VoiceLogViewModel.swift::startCapture` is the one seam a
   surface calls. `AppRuntimeCoordinator.swift` records which lane the process entered
   (foreground scene, self-test) so a cold start knows what it owes. Debug builds run the
   mock services unless `-LiveServices` is passed (`Services/RuntimeMode.swift`).
2. **Hot mic.** `apps/ios/VoCal/Voice/VoiceCaptureCoordinator.swift::toggle` owns the
   recording session: the audio session, the recorder in `VoiceCaptureSupport.swift`
   writing CAF bytes into a staging bundle in the app group, the claim ladder of
   `docs/VOICE_CAPTURE.md` (`accepted`, `mic_active`, `confirmed_listening`), interruptions,
   stalls, and the recovery scan that seals whatever a crash left behind. The filesystem
   session ledger (`VoiceSessionStore`: atomic tmp then rename, fsync on file and directory)
   is the crash-recovery source of truth. Nothing here may reference the API client, auth or
   a dashboard model (`TIDY-CAPTURE-001`).
3. **Durable bytes.** `VoiceCaptureCoordinator.sealCurrentAudioFile` then
   `commitFinalArtifact` hand the sealed audio to `Voice/CaptureOutbox.swift::enqueue`
   (SQLite in the app group, schema `vocal.capture.v1`), whose return value is the
   `LocalCommitReceipt`: the one fact that makes "Saved" true (INVARIANTS §2). The outbox is
   touched exactly once per capture, at finalization.
4. **Upload.** The planner in `Sources/VoCalCapture/RelayQueueModels.swift` (`RelayJobRecord`,
   `UploadLease`, `RemoteSyncState`, `RelayFailureClass`) decides what is due; the outbox
   worker leases a job and `Services/Protocols/MealCaptureService.swift` calls
   `APIClient.uploadCapture` (`POST /captures`, multipart). Same storage as the outbox, never
   the same authority (ARCHITECTURE.md).
5. **The server row.** `services/api/src/api/captures/router.py::upload_capture` writes the
   blob to Supabase Storage first and the `captures` row second; `uploaded` is claimed only
   after both are durable, and a duplicate `client_capture_id` returns the existing row.
6. **Derived rungs.** `transcribe/` (ElevenLabs Scribe) writes an immutable `transcripts`
   row; `parser/router.py::parse` writes an immutable `parses` row (identity resolved once,
   `nutrition/resolver.py`); `meals/router.py::log_meal` writes the `meal_logs` row that
   licenses "Logged", diffing confirmed against parsed into append-only `corrections`. Each
   arrow is a separate, retryable stage; failure never travels left (INVARIANTS §14).

## Everything else, mechanically (deliberately incomplete)

Largest files: `CaptureOutbox.swift` 2675 lines, `VoiceCaptureCoordinator.swift` 2481,
`VoiceCaptureModels.swift` 2154, `VoiceSelfTestRuntime.swift` 1318, `VoiceCaptureSupport.swift`
929, `TodayView.swift` 816, `meals/router.py` 816, `VoiceLogViewModel.swift` 732,
`certainty.py` 682. The voice files are ported near-verbatim from Serein and dogfood-hardened;
their size is a concern to state in one phrase each (they do), not a reason to split.

Decisions spelled in more than one place (F4), in the order they will be given one address:

| # | Decision | Addresses today | Plan |
|---|---|---|---|
| 1 | "Reads as confirmed" confidence bar (0.93) | `MealItemCard.swift:13`, `VoiceLogResultView.swift:35` (and 0.94 in the mock fixtures) | one constant in `VoCalCore` (Phase 4) |
| 2 | The claim copy: "Saved", "Saving…", "Listening", "Logged" | eight literals in `VoiceLogView.swift`, one in `VoCalButton` previews | `VoiceLogState` (pure) becomes the one address; a row bans the literals elsewhere (Phase 4) |
| 3 | The refine amount answer grammar "<amount> <unit>" | built by hand in `MealItemEditSheet.save`, parsed by `clarify._AMOUNT_ANSWER_RE` | a `RefineAnswer.amount(_:unit:)` factory in `VoCalCore` with a test mirroring the server's regex; the grammar named in `PARSER_CONTRACT.md` (Phase 4) |
| 4 | Grams per ounce (28.3495) | `resolver.py`, `tests/calorie_eval.py` | the harness imports the resolver's constant (Phase 4, trivial) |
| 5 | "9/9" in the voice test summary | `bin/ios-sim-voice-test` prints a literal count | print the observed count and compare to the requested scenarios (Phase 3.4) |
| 6 | What day is "today" for a user | `datetime.now(` at 12 sites in the API, `_user_tz` and `_parse_day` helpers in `meals/router.py` | backlog: an injectable clock; not this pass |
| 7 | Units vocabulary | Swift `FoodUnit`, Python `Unit` + `_UNIT_SYNONYMS` + `_UNIT_ALIASES` | contract-mirrored by design (PARSER_CONTRACT.md) and round-trip tested; left |
| 8 | Error copy "Check your connection and try again." | four files | backlog: `PipelineFailure.humanDescription` already exists in VoCalCore; migrate the views |

## Obvious dead code (2.5), with the census

| Candidate | Census | Verdict |
|---|---|---|
| `scripts/todo` + `make todo/todo-next/todo-status` | `todo.json` was never tracked (`git log --all -- todo.json` is empty); referenced only by the Makefile and a completed Phase A plan | delete (Phase 6 commit) |
| `.pre-commit-config.yaml`, `scripts/run_swiftlint.sh`, swiftlint in `Brewfile` and `doctor.sh` | no hook installed, swiftlint absent, no `.swiftlint.yml`; nothing invokes the wrapper | delete with the push-hook commit |
| `apps/ios/ci_scripts/` (Xcode Cloud) | kept by decision (apps/ios/AGENTS.md: inert while the ASC workflow is off) | leave, note |
| `_MiddlewareFactory` import (`main.py:14`) | used as a string forward reference in two `cast(...)` calls; vulture cannot see it | not dead |
| `RuntimeMode.startsOnSettingsTab`, `showsWeekBudgetOnLaunch` | census pending in Phase 6 (`debugSettingsDestination` is used by `SettingsView`) | verify by removal |

## Frozen (2.6)

Read-only for this pass unless the owner names them: authentication (`auth.py`,
`dependencies.py`, `Services/Auth/*`), account deletion (`account/router.py`), the Supabase
schema (migrations are user-run; the Deploy workflow applies them), every response shape the
shipped iOS build 26 decodes (additive fields only), the parser contract, the App Store
metadata and the publish lane, the Deploy workflow's secrets, dependency versions and
lockfiles (`uv.lock`, `Package.resolved`), the pinned simulator and Xcode.

Outside this repository and depending on what might move: the shipped app (build 26), the
admin CLIs (`scripts/review`, `scripts/beta-metrics`) reading Supabase rows through the pure
functions in `admin/store.py`, the Fly app (`services/api/fly.toml`), GitHub Actions.

## Work order and estimate

| Phase | Work | Hours |
|---|---|---|
| 3 | Stability audit on the capture path and the outbox, the ladder document, CI rewrite, push hook, wiring rows | 3 |
| 4 | Decisions 1 to 4 above given one address each | 1.5 |
| Lifecycle | Recently deleted with Restore (server + Settings); corrections diffed against the root parse; learned corrections applied at parse time and listed in Settings | 4 |
| 5 | Surfaces: Serein's card menus and a haptic on the committed receipt where they fit; the two new Settings lists | 2 |
| 6 | Delete with a census: dead scripts and config, unused debug hooks | 1 |
| 7 | `docs/CAPTURE_LIFECYCLE.md`, AGENTS routing table, findings and questions ledgers, handoff | 1.5 |
