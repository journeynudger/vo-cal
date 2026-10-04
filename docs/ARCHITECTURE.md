# Architecture

Authored fresh for Vo-Cal; rules inherited from Beacon (thin client, API conventions, observability) and Serein (capture-path isolation, storage/authority separation). Live stack table and phase status: `.claude/memory/architecture.md`. Behavioral guarantees: `docs/INVARIANTS.md`.

## The two structural rules

### Thin client (Beacon)

Business logic lives server-side. The iOS app renders state, captures input, and calls the API. **The sole exception is the local-first capture path**: voice capture commits locally without signal (decision #14), because "Saved" is a local truth. Everything else — parsing, nutrition math, protocol targets, check-in adjustments, aggregation — is authoritative on the server.

### Capture-path isolation (Serein)

Nothing non-audio may gate, delay, or sit on the mic-hot path: no UI work, no network state, no auth refresh, no telemetry, no enrichment. The test: **delete the subsystem entirely — does capture still work? If yes, it must not be on the capture path.** This applies to app launch, singleton initialization, and every transitive dependency the path touches. Serein broke production three separate times learning this; Vo-Cal inherits the lesson, not the bugs.

Corollary (same storage ≠ same authority): stores record facts, planners decide next work, workers perform effects. The upload queue, upload planner, and upload worker may share a database; they may not share responsibility.

## Data flow

```
speak
  └─ capture            filesystem session ledger (no SQLite on the hot path)
       └─ outbox commit          ← "Saved" (local durable receipt; requires no network, no auth)
            ├─ outcome ledger    what happened after "Saved" (logged / dismissed); Today lists the rest as Unfinished
            └─ upload            CaptureUploadWorker: level-triggered passes, RelayPlanner decides, the outbox records
                 └─ blob + captures row   ← "uploaded", claimed only after BOTH are durable
                      └─ transcripts artifact    (ElevenLabs Scribe; immutable)
                           └─ parses artifact    (Claude, PARSER_CONTRACT.md; immutable)
                                └─ user confirm   ← "logged": meal_logs row
                                     ├─ corrections (append-only, reference the parse)
                                     └─ /today aggregation (derived, recomputable)
```

Each arrow is a separate, retryable stage; failure at any stage never travels left. A transcription or parse failure is never a capture failure.

## API surface

Every endpoint the app or the operator calls, by domain (`services/api/src/api/<domain>/router.py`). Auth is a Supabase JWT on every route except `/health` and `/metrics`; `/__dev` mounts only with `DEV_ENDPOINTS=true` against a local database.

| Domain | Endpoint | Purpose |
|---|---|---|
| captures | `POST /captures`, `GET /captures/{id}` | Register an uploaded audio capture (blob + immutable row, idempotent by `client_capture_id`); read its status |
| transcribe | `POST /transcribe` | Transcribe a stored capture (ElevenLabs Scribe) into an immutable `transcripts` row |
| parser | `POST /parse`, `POST /parse/refine`, `POST /parse/photo` | Transcript or typed text → items, learned names, the person's foods, resolution, confidence, checks, recognition; apply answers/edits as a new parse; a photo as a capture read by the vision model |
| meals | `POST /meals`, `GET /meals?date=`, `GET /meals/{id}`, `PUT /meals/{id}`, `DELETE /meals/{id}`, `POST /meals/{id}/restore`, `GET /meals/deleted` | Confirm a parse into `meal_logs` (+ `corrections` diffed against the root parse), read and edit a day, tombstone and restore inside 30 days |
| meals | `PATCH /meals/{id}/name`, `POST /meals/{id}/append` | The person's name (makes a usual); add more by voice as a new capture chain joining the row |
| meals | `GET /meals/today`, `GET /meals/summary`, `POST /meals/water` | The dashboard (targets, consumed, remaining, protein band, meals); the week's capture-quality summary; a water entry (idempotent) |
| meals | `GET /meals/usuals`, `PATCH /meals/usuals/{id}/name`, `DELETE /meals/usuals/{id}`, `GET /meals/search?q=` | Usuals (the recognition candidates); search over what was logged, for typed logs |
| meals | `GET /meals/learned-names`, `POST /meals/learned-names/forget` | What the parser learned from renames; unteach one (an appended `name_forget` row) |
| foods | `GET /foods/personal`, `POST /foods/personal`, `POST /foods/personal/batch`, `DELETE /foods/personal/{id}` | The person's own foods: a label typed once, a batch saved as a recipe; priced by name before any database; retire is a mark |
| intake | `POST /intake`, `GET /intake/latest` | Append a versioned intake; read the newest |
| protocols | `POST /protocols/generate`, `GET /protocols/active`, `POST /protocols/{id}/revise` | Run the engine (PROTOCOL_LOGIC.md) and supersede; the active protocol with its age; apply the recalibration as v(n+1) |
| checkin | `POST /checkin/checkins`, `GET /checkin/checkins`, `GET /checkin/checkins/due`, `POST /checkin/recommend` | The weekly check-in, its history, whether one is due, the recalibration proposal |
| checkin | `GET /checkin/nudges/current` | Legacy situational nudge; no client calls it (findings ledger 46) |
| nudges | `POST /nudges/plan` | The deterministic nudge plan the app renders and schedules as local notifications |
| weekbudget | `GET /week/budget`, `PUT /week/plan` | The Monday-to-Sunday calorie budget with overages carried; replan the remaining days |
| account | `PATCH /account/profile`, `DELETE /account` | The device timezone; total account and data deletion (App Review requirement) |
| admin | `GET /admin/logs`, `GET /admin/logs/{id}`, `POST /admin/logs/{id}/review`, `GET /admin/aggregates`, `POST /admin/protocols/recompute`, `POST /admin/meals/purge-deleted` | The review surface behind the email allowlist; every read audit-logged; operator sweeps run with `?dry_run=true` first |
| system | `GET /health`, `GET /metrics`, `POST /metrics/client` | Liveness; Prometheus (token-gated at the edge); client metrics ingestion (no producer ships yet, findings ledger 1) |

## Immutability classes (per table)

| Class | Tables | Rule |
|---|---|---|
| Immutable after commit | `captures`, `transcripts`, `parses`, `corrections`, `checkins`, `admin_reviews`, protocol versions | Never updated; reprocessing writes new rows |
| Append-only | `corrections` (never patch a parse; `name_forget` rows unteach a learned rename), protocol re-versions (`supersedes` FK), tombstone deletes for `meal_logs` | History is preserved; deletes are tombstones, purged only by the audited admin sweep after 30 days |
| Mutable | `profiles`, `saved_meals`, caches (`usda_cache` — derived, rebuildable) | Normal CRUD; caches must be rebuildable from source |

RLS: owner-only on all user tables; `food_dictionary` / `usda_cache` read-all; `admin_*` service-role only. Audio lives in the private `capture-audio` bucket, signed URLs only.

## Observability

- **Request middleware** on every API route: timing + `X-Request-ID` stamped, JSON logs.
- **Prometheus `/metrics`** on the API (token-gated at the edge): request counters/latency, pipeline stage counters, provider error counters. No scrape stack is stood up for the beta (decision 27); `scripts/beta-metrics` reads SQL instead.
- **Client metrics ingestion** (`POST /metrics/client`): the beta-gate numbers come from here — log duration (mic-tap to confirm), activation funnel, correction rate. Never phone numbers or precise health values.
- **JSONL debug-events on device** (`debug-events.jsonl`, app-group container): best-effort runtime log and UI synchronization channel; `observability.jsonl` is the bounded, lossy, retrospective latency artifact. Both stay off the mic-hot path and are never a source of user-facing claims (see `docs/VOICE_CAPTURE.md`).
