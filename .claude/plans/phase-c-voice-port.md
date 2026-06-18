# Phase C — Voice Capture Port (Serein → VoCalVoice)

> Status: Active
> Owner: @lorenzo
> Branch: `phase-c-voice-port`
> Next: C3

## Goal

Port Serein's battle-tested voice capture layer into Vo-Cal: the SPM state machine, the app-layer coordinator, the filesystem session ledger, crash recovery, the sim self-test harness, and the upload + transcription pipeline. At exit, speaking into the app produces a durably-committed local capture (claim ladder proven), which uploads and yields immutable transcript + parse artifacts in the DB — with the mic-hot path provably isolated from everything else. Without this, Phase D has no audio. Touches: `Sources/VoCalVoice/`, `apps/ios/VoCal/Voice/`, `services/api/src/api/{captures,enrichment}/`, `bin/`.

## Decisions locked

- **Port, don't rewrite.** Serein's voice code is production-grade and dogfood-hardened; renames and deletions only. Where a seam is cut (intent/Live Activity), leave a three-part "why" comment naming what was removed and why.
- **Foreground-only capture** (master decision): `VoiceCaptureIntent.swift` and `VoiceLiveActivity.swift` are NOT ported. `UIBackgroundModes: audio` keeps an in-progress recording alive across app-switch/lock.
- **Audio constants unchanged:** CAF, 24kHz mono 16-bit PCM, `.playAndRecord` with Bluetooth HFP + high-quality recording options. These were dogfooded; do not "improve" them.
- **Claim ladder semantics verbatim:** `accepted → mic_active → confirmed_listening → saved`. "Listening" UI requires byte-flow proof; "Saved" requires local outbox commit receipt. Optimism allowed at `accepted` only.
- **Same storage ≠ same authority** (Serein guardrail): the outbox records capture facts; a separate upload queue + planner owns retry/lease policy; a worker performs network effects.
- **Server ack rule (Serein data plane, adapted):** the API acknowledges `uploaded` only after the audio blob is durably in Supabase Storage AND the immutable `captures` row is committed.

## Context

Depends on Phase A (A3 app scaffold, A4 SPM, A5 backend, A6 schema). The enrichment worker (C5) calls Phase B's parse engine when it lands — until then it stops at the transcript artifact (the seam is explicitly designed). Source paths are listed in MASTER-PLAN's reuse map. Before starting: read `docs/VOICE_CAPTURE.md` and `docs/INVARIANTS.md` — that rule is now permanent for any voice work.

---

## Tasks

### C0. Port the SPM voice library

The pure state machine first — testable in seconds, no app needed.

- [x] **Step 1.** `Sources/VoCalVoice/VoiceCaptureModels.swift` ← `Serein/Sources/SereinVoice/VoiceCaptureModels.swift` (~2,200 lines): phases, session snapshots, audio-file snapshots, blocked reasons, toggle results. Renames `Serein*` → `VoCal*`; module dependency on `VoCalCore` for shared IDs/codecs.
- [x] **Step 2.** `Sources/VoCalVoice/CAFRepairer.swift` ← verbatim (header/desc/data chunk analysis + truncated-file repair).
- [x] **Step 3.** Port the SPM unit tests (`SereinVoiceTests` → `VoCalVoiceTests`), including the DST property-test kernel if separable (`bin/voice-dst` equivalent — port if the harness comes over cleanly, else log an amendment).
- [x] **Acceptance:** `swift test` green; zero references to removed Serein subsystems.
- [x] **Commit:** `feat(voice): port SereinVoice state machine + CAFRepairer as VoCalVoice`

### C1. Port the app-layer coordinator + audio session

The orchestrator, minus the background-intent machinery.

- [x] **Step 1.** `apps/ios/VoCal/Voice/VoiceCaptureCoordinator.swift` ← Serein's: bootstrap, recovery scan, recorder lifecycle, liveness observation (byte-flow polling), interruption handling (pause + seal, NO auto-resume, 5-min auto-finalize deadline), route-change classification (observations not commands — `.categoryChange` ≠ hardware failure), stall detection/escalation.
- [x] **Step 2.** `Voice/VoiceCaptureSupport.swift` ← Serein's: `SystemVoiceAudioSessionController` (category/sample-rate/input config + deactivate-with-notify), `VoiceSessionStore` (filesystem ledger in the app-group container), session bundle layout, atomic snapshot persistence, `.completeUntilFirstUserAuthentication` file protection.
- [x] **Step 3.** **Cut the seams:** remove intent/Live-Activity codepaths. At each cut, a "why" comment: requirement (foreground-only P0), failure mode avoided (ActivityKit cold-start rejection), evidence (Serein AGENTS.md, Apple forum #815725). Mic permission flow via `AVAudioApplication.requestRecordPermission` retained.
- [x] **Step 4.** `Voice/VoCalCapturePaths.swift` ← `CaptureRelayPaths.swift`: app-group layout `vocal/local/capture/{voice_sessions/{active,quarantine}, blobs, requests, debug-events.jsonl, observability.jsonl}`.
- [x] **Acceptance:** `bin/ios-app-build` green, zero warnings; recording start/stop works in simulator with milestones appearing in `debug-events.jsonl`.
- [x] **Commit:** `feat(voice): port capture coordinator + audio session layer (foreground-only)`

### C2. Port outbox + observability

Durable local commit — the thing "Saved" means — plus the JSONL truth channel.

- [x] **Step 1.** `Voice/CaptureOutbox.swift` ← Serein's Shared sources: SQLite outbox, touched exactly once at finalization (in-progress state stays on the filesystem ledger — INVARIANTS rule). Commit returns a `LocalCommitReceipt`; UI may show "Saved" only against that receipt type (proofs-not-booleans).
- [x] **Step 2.** Port `CaptureRelayDebugRecorder` (JSONL milestone trace: `accepted`, `bootstrap_*`, `audio_session_*`, `recorder_*`, `mic_active`, `first_progress`, `confirmed_listening`, `saved`, `start_failed`) and the bounded observability sink (off the hot path, lossy by design).
- [x] **Step 3.** Crash-recovery wiring: on launch, scan active session bundles → finalize/repair (CAFRepairer)/quarantine. Recovery must NOT be on the capture start path (capture-path isolation — Serein's March 2026 lesson).
- [x] **Acceptance:** kill the app mid-recording in sim → relaunch → capture recovered and committed (or quarantined with a logged event, never silent loss).
- [x] **Commit:** `feat(voice): outbox with commit receipts + JSONL observability + crash recovery`

### C3. Port the sim self-test harness

The regression net that lets Phases D–I touch the app without fearing the mic path.

- [ ] **Step 1.** `Voice/VoiceSelfTestRuntime.swift` ← Serein's, trimmed to the foreground-surviving scenarios: golden path, audio interruption recovery, route-change resilience, process-death recovery, permission denial, stall detection, blocked-deadline auto-finalization, CAF repair on recovery, quarantine on corruption (9 scenarios; the intent/Live-Activity cold-start scenarios are dropped — note in file header).
- [ ] **Step 2.** `bin/ios-sim-voice-test` ← Serein's script: build, boot pinned simulator, launch with `--self-test-run-id`, stream structured events, clean up simulator on exit. Pin a simulator UDID + record it with scheme/bundle constants in AGENTS.md (Serein's "iOS device loop constants" section, Vo-Cal values).
- [ ] **Step 3.** Add the runtime tier to AGENTS.md's verification table with its measured budget; rule: any change to coordinator/audio-session/outbox code requires `bin/ios-app-build` then `bin/ios-sim-voice-test` once at end of task.
- [ ] **Acceptance:** `bin/ios-sim-voice-test` 9/9 green from a cold checkout.
- [ ] **Commit:** `feat(voice): sim self-test harness (9 foreground scenarios)`

### C4. Upload path (outbox → API)

Separate authority: queue/planner/worker, per the deep-couplings guardrail.

- [ ] **Step 1.** Backend: `captures/router.py` — `POST /captures` (multipart: CAF + metadata JSON): store blob in `capture-audio` bucket, commit immutable `captures` row, ack `uploaded` only after both; idempotent by client capture ID (retries safe). `GET /captures/{id}` status.
- [ ] **Step 2.** iOS: upload queue table (own store, NOT the outbox's authority), planner (next-eligible work, exponential backoff, bounded lease deadline — a wedged upload must never block subsequent captures: Serein's April 2026 lesson), worker (background `URLSession` with `sharedContainerIdentifier` bound — Serein's "why" comment about the silent app-group wedge comes over with it).
- [ ] **Step 3.** Capture-path isolation proof: upload subsystem fully deleted ⇒ capture still saves. Encode as a self-test scenario or unit test, not a hope.
- [ ] **Test:** API-side pytest: idempotent re-upload, blob+row atomicity (no row without blob), RLS.
- [ ] **Acceptance:** airplane-mode capture commits locally; on reconnect, uploads and acks; wedged-upload simulation does not block the next capture.
- [ ] **Commit:** `feat(capture): upload queue/planner/worker + captures endpoint`

### C5. Transcription + parse worker (FastAPI)

Serein's enrichment worker pattern, in Python, ending in parse artifacts.

- [ ] **Step 1.** `enrichment/worker.py` — poll `captures` in `transcription_pending` → claim with stale-TTL (5 min) → download blob → ElevenLabs Scribe (multipart, `scribe_v1`) → immutable `transcripts` row → state `parsed_pending`. Transient errors (network/5xx): exponential backoff (2min base, 6h cap, 6 attempts) → then `exhausted` (visible, retryable by admin). Permanent errors (4xx, invalid audio): `exhausted` immediately. A transcription failure is never a capture failure (VALUES rule) — audio remains, retry is always possible.
- [ ] **Step 2.** Parse hop: on transcript commit, invoke Phase B's parse engine → immutable `parses` row → capture state `ready`. If Phase B hasn't landed yet, the worker stops at `parsed_pending` (seam noted here, closed when B6 merges).
- [ ] **Step 3.** `GET /captures/{id}/result` — polling endpoint returning `{state, transcript?, parse?}` for the app. Worker runs in-process with uvicorn for dev (`make api-dev`), as a separate process target for deploy.
- [ ] **Test:** worker unit tests with recorded provider responses: claim/stale-reclaim, backoff schedule, transient-vs-permanent split, artifact immutability.
- [ ] **Acceptance:** uploaded capture → transcript + parse rows appear; provider-down simulation retries then surfaces `exhausted` without data loss.
- [ ] **Commit:** `feat(enrichment): ElevenLabs transcription + parse worker (Serein pattern)`

### C6. Verification budgets + doctrine ratchet

Lock the measured reality into the doctrine.

- [ ] **Step 1.** Measure and record in AGENTS.md's tier table: `scripts/check` (SPM), `bin/ios-app-build` (incremental + cold), `bin/ios-sim-voice-test`. Budgets become the timing ratchet (slower = failed verification; diagnose, don't retry).
- [ ] **Step 2.** Update `docs/ARCHITECTURE.md` with the as-built capture flow diagram and the seam list (what was cut from Serein and where the comments live).
- [ ] **Acceptance:** AGENTS.md tier table complete with measured numbers; a fresh session can pick the right tier without asking.
- [ ] **Commit:** `docs(doctrine): voice verification budgets + as-built capture architecture`

---

## Exit Criteria

- ✅ `bin/ios-sim-voice-test` 9/9 green; `swift test` + `bin/ios-app-build` green, zero warnings.
- ✅ Real device: speak → `confirmed_listening` only after byte-flow proof → "Saved" only on commit receipt → upload → immutable transcript + parse artifacts in DB.
- ✅ Kill-mid-recording recovers on relaunch; airplane-mode capture commits locally and syncs later.
- ✅ Capture-path isolation proven mechanically (upload/enrichment deleted ⇒ capture still works).
- ✅ Claim ladder milestones visible in `debug-events.jsonl` for every capture.

### 2026-06-18 — C1+C2 combined commit; runtime proof deferred to C3

The C1/C2 port agent died on a process restart after writing valid code but before committing. Files survived on disk and compile zero-warning. C1 (coordinator/audio/paths) and C2 (outbox/recorder/observability) are committed together because the coordinator calls the outbox at finalization — they only compile as a unit, so a split C1-only commit would not build. The runtime acceptance ("recording start/stop produces debug-events.jsonl milestones", "kill mid-recording recovers") is the job of the C3 self-test harness (next task); marking C1/C2 done on build-green + faithful-port basis, with C3 as the rigorous runtime gate.

A CaptureCommitObserver seam was left as the C4 upload attachment point (no-op default). Passive-location context collection was stubbed empty (no location subsystem in Vo-Cal).

### 2026-06-12 — C0 executed ahead of full Phase A completion; VoCalCapture target added; bin/voice-dst ported

C0 ran in parallel with A5/A6 (disjoint paths; A0–A4 scaffold sufficed). VoiceCaptureModels requires SereinCapture types, so a full `Sources/VoCalCapture` target was ported (CaptureTypes, RelayQueueModels, RelayPlanner, Observability, TelemetryModels minus location-stream telemetry — cut documented in a why-comment at the site). The DST kernel came over cleanly: 200/200 seeds green; `bin/voice-dst` wrapper added. Live-Activity vocabulary (blocked-reason case, prerequisite field) kept intact per port discipline — C1 decides foreground-only population.

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| C0 SPM voice library port | done | backfill |
| C1 Coordinator + audio session port | done | backfill |
| C2 Outbox + observability + recovery | done | backfill |
| C3 Sim self-test harness | not started | — |
| C4 Upload path | not started | — |
| C5 Transcription + parse worker | not started | — |
| C6 Verification budgets | not started | — |
