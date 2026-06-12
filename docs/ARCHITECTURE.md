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
            └─ upload            queue / planner / worker — separate authority from the outbox
                 └─ blob + captures row   ← "uploaded", claimed only after BOTH are durable
                      └─ transcripts artifact    (ElevenLabs Scribe; immutable)
                           └─ parses artifact    (Claude, PARSER_CONTRACT.md; immutable)
                                └─ user confirm   ← "logged": meal_logs row
                                     ├─ corrections (append-only, reference the parse)
                                     └─ /today aggregation (derived, recomputable)
```

Each arrow is a separate, retryable stage; failure at any stage never travels left. A transcription or parse failure is never a capture failure.

## API surface

| Endpoint | Purpose |
|---|---|
| `POST /captures` | Register an uploaded capture (blob + immutable row) |
| `GET /captures/{id}/result` | Poll pipeline state: transcript / parse readiness (decision #15: polling, not WebSockets) |
| `POST /parse` | Parse a transcript into the contract JSON |
| `POST /parse/refine` | Apply a clarifying-question answer; new parse artifact |
| `POST /meals` | Confirm a parse into a `meal_logs` row (+ `corrections`) |
| `GET /meals?date=` | Day's meal logs |
| `GET /today` | Aggregated targets-vs-logged for the dashboard |
| `POST /intake` | Submit/append intake answers (versioned) |
| `POST /protocols/generate` | Run the protocol engine (PROTOCOL_LOGIC.md) |
| `POST /protocols/{id}/revise` | Check-in driven v(n+1); immutable, `supersedes` FK |
| `POST /checkins` | Submit a weekly check-in |
| `GET /checkins/due` | Is a check-in due? |
| `/admin/*` | Internal review panel; Supabase auth + server-side email allowlist; all reads audit-logged |
| `POST /metrics/client` | Client metrics ingestion (log-duration events, funnel) |
| `DELETE /account` | Account + data deletion (App Review requirement) |

## Immutability classes (per table)

| Class | Tables | Rule |
|---|---|---|
| Immutable after commit | `captures`, `transcripts`, `parses`, `corrections`, `checkins`, `admin_reviews`, protocol versions | Never updated; reprocessing writes new rows |
| Append-only | `corrections` (never patch a parse), protocol re-versions (`supersedes` FK), tombstone deletes for `meal_logs` | History is preserved; deletes are tombstones |
| Mutable | `profiles`, `saved_meals`, caches (`usda_cache` — derived, rebuildable) | Normal CRUD; caches must be rebuildable from source |

RLS: owner-only on all user tables; `food_dictionary` / `usda_cache` read-all; `admin_*` service-role only. Audio lives in the private `capture-audio` bucket, signed URLs only.

## Observability

- **Request middleware** on every API route: timing + `X-Request-ID` stamped, JSON logs.
- **Prometheus `/metrics`** on the API: request counters/latency, pipeline stage counters (uploaded, transcribed, parsed, logged), provider error counters.
- **Client metrics ingestion** (`POST /metrics/client`): the beta-gate numbers come from here — log duration (mic-tap to confirm), activation funnel, correction rate. Never phone numbers or precise health values.
- **JSONL debug-events on device** (`debug-events.jsonl`, app-group container): best-effort runtime log and UI synchronization channel; `observability.jsonl` is the bounded, lossy, retrospective latency artifact. Both stay off the mic-hot path and are never a source of user-facing claims (see `docs/VOICE_CAPTURE.md`).
