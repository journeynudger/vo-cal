# Vo-Cal Behavioral Invariants

> **Port provenance**
> Source: `/Users/lorenzoscardicchio/Downloads/Projects/Serein/docs/INVARIANTS.md`, ported near-verbatim with Serein → Vo-Cal renames.
> **Deletions:** share-capture rungs in §3; §5 Cross-Process Coordination in its entirety (no share extension or second process in P0); the cross-process inbox bullet in §4 and the "extension killed mid-write" bullet in §6; passive-stream/location material in §1, §7, and §10 (only the capture-taxonomy core survives in §10); share-payload and inbox rows in §8; location references trimmed from §11; share-extension credential bullets in §13.
> **Adaptations:** §2 durability vocabulary extended with Vo-Cal's derived terms; §13 rewritten for Supabase JWT auth.
> **Additions:** §14 Derived Rungs.
> Original section numbers are preserved so the delta stays auditable; §5 is an explicit tombstone.

These invariants hold regardless of storage backend, transport, architecture, or runtime implementation. They define what Vo-Cal promises to the user and to itself.

These are behavioral and trust properties, not implementation details. Do not add platform-specific mechanisms (iOS APIs, SQLite schemas, framework names) here. If the invariant would not make sense on a hypothetical Android or desktop port, it belongs in a code comment or an implementation doc, not in this file. Implementation-specific "why" context belongs at the code site where the invariant is enforced.

---

## 1. Immutability

- Raw captures are append-only and immutable after commit. In-place edits are forbidden.
- Binary objects (audio) are immutable after commit. Content must match its content-address; mismatches are corruption.
- Derived outputs (transcripts, parses, etc.) are immutable after commit. Reprocessing produces new records, never mutations to existing ones.
- To correct a capture: create a new record referencing the original. The original remains intact.
- To enrich: write a new derived record referencing the capture.
- To delete: write a tombstone. The original artifacts remain until explicit garbage collection.

## 2. Durability and "Saved"

- "Saved" means the capture record is durably committed in the system's primary store. Nothing less.
- "Saved" does NOT mean uploaded, transcribed, parsed, logged, backed up, or enriched.
- The UI must not display "Saved" until the durable commit has succeeded.
- The UI must not display durability claims that exceed the current state. "Saving..." is permitted during intermediate states; "Saved" is not.
- Durability claims must be derived from durable facts (committed artifacts), never from ephemeral runtime state.
- Any local index or cache is derived and must be rebuildable from committed artifacts. If local state and committed artifacts diverge, committed artifacts win.

## 3. Capture Durability Rungs

### Voice captures

| Rung | State | "Saved" legal? |
|------|-------|----------------|
| 0 | Intent declared, resources requested | No |
| 1 | Resources allocated, staging ready | No |
| 2 | Recording in progress, audio bytes growing | No |
| 3 | Stop issued, recorder winding down | No |
| 4 | Sealing: validating audio, committing artifacts | No |
| 5 | Capture record durably committed | **Yes** |

- At most one voice recording may be active at any time.
- Starting voice capture must not wait on network state, UI readiness, enrichment, or best-effort context collection.
- Request acknowledgement, confirmed listening, and saved are distinct claims. Confirmed-listening claims require observed audio progress; saved claims require durable commit.
- Audio interruptions pause the current session and seal in-progress audio. The system must not auto-resume recording. The user may resume the same session via the existing toggle surface. If the user does not resume within 5 minutes of the blocker clearing, the system auto-finalizes the partial capture.
- Recording operates entirely in local staging. Cloud/network unavailability must not block recording.

### Text captures

| Rung | State | "Saved" legal? |
|------|-------|----------------|
| 0 | Capture record durably committed (single step, inline content) | **Yes** |

## 4. Crash Recovery

- Every capture in progress must either complete, retry, or be quarantined after a crash. Nothing may silently vanish.
- Crash recovery operates entirely on storage observations, never on in-memory session state. Session state is lost on crash by definition.
- If a crash occurs during recording and salvageable audio exists in staging, the system must attempt to seal and commit that audio on relaunch.
- If a crash occurs between committing the binary object and committing the capture record, the system must re-emit the record commit on relaunch.
- If staging exists but contains no recoverable audio, it is quarantined and the event is logged. The capture is lost, but this is surfaced, never silent.

## 5. (Deleted in port) Cross-Process Coordination

Serein's §5 governed share-extension staging across processes. Vo-Cal P0 has no share extension and no second process writing captures; this section is intentionally absent, not forgotten. Re-port it if a share/widget surface ever lands.

## 6. Failure Modes

- **Phone call or audio interruption**: pause the current session, seal whatever audio exists, and wait for explicit user resume after the blocker clears. Do not auto-resume. If the user never resumes within 5 minutes of blocker clear, auto-finalize the partial capture on the next wake/scan.
- **Audio stall (recorder stops producing bytes)**: detect within bounded time, escalate to stop if stall persists, seal whatever exists.
- **Acknowledged start without timely liveness proof**: surface explicit failure. The system must not silently imply healthy capture while the user may be speaking into dead air.
- **Crash during recording**: salvage and, if needed, repair the single in-progress CAF on relaunch.
- **Crash during sealing**: re-emit remaining commit steps on relaunch.
- **Crash during starting (no audio produced)**: quarantine staging, log the event.
- **Corrupt audio**: quarantine. Truncated audio may attempt narrow repair; if repair fails, quarantine.
- **Empty audio**: quarantine immediately.
- **Storage unavailable at commit time**: retry until commit succeeds or process is killed. "Saved" remains false.
- **Disk critically low**: refuse new captures with a user-visible notice.

## 7. Immutable vs. Derived

**Immutable (sacred, never modified after commit):**
- Raw capture records (manifest/metadata)
- Raw binary objects (audio)

**Derived (recomputable from immutable sources):**
- Transcripts, parses, nutrition resolutions
- Meal logs and Today projections
- Any local index or cache

A transcription failure is never a capture failure. Enrichments can always be retried or recomputed.

## 8. Resource Bounds

Every resource that can grow without bound must have a hard limit and a specified behavior when reached.

| Resource | Bound | Behavior when reached |
|----------|-------|-----------------------|
| Recording file size | Bounded by disk space | Auto-stop when disk critically low |
| Stale staging TTL | 24 hours | Clean incomplete staging |
| Lifecycle phase deadlines (starting, stopping, sealing) | Bounded per phase | Escalate or quarantine; never wait indefinitely |

When a bound prevents progress, the system must fail closed with an explanation and remediation.

## 9. Convergence and Liveness

- The system is level-triggered: it determines required work from current state, not event history. This is what makes crash recovery automatic.
- All pending work must converge to complete, retry, or quarantine within bounded time. Nothing may wedge.
- Any in-flight upload must have a bounded deadline. If the deadline expires without server acknowledgement, the system must reclaim the work and make it eligible for retry. No single upload may hold the pipeline indefinitely.
- After faults stop occurring, every in-progress capture must converge to committed or quarantined.
- After faults stop occurring, all orphan staging must converge to cleaned.
- Duplicate or stale completion signals must be idempotent.
- At most one concurrent execution attempt is permitted per logical operation.

## 10. Capture Taxonomy

- **Captures** are user-initiated, discrete, sacred records — the append-only log of user-authored content.
- The system never writes to the capture log itself. Captures always originate from the user.

## 11. Context and Enrichment

- Environmental context at capture time is best-effort. Missing context must not block capture commit.
- Enrichments run asynchronously after capture commit. They must not block the capture pipeline.
- Enrichments must not be written back into the raw capture record. They are separate derived records.
- Starting a new capture must never block on enrichment of a previous capture.

## 12. Tenant Isolation

- All data is account-scoped. Every query, cache path, and deduplication mechanism must be tenant-isolated.
- Cross-account data access must fail mechanically, not by convention.
- Tenant context must be set at transaction start and discarded at transaction end. It must never leak across pooled connections.
- Consumer reads must be auditable.

## 13. Auth Planes

- The API plane authenticates with Supabase JWTs (phone OTP). Browser/admin auth is a separate concern from native app auth.
- The capture hot path requires no credential at all. "Saved" is a local commit and must never wait on auth state.
- Capture upload must not depend on refreshing short-lived tokens on the capture path. Token refresh is the upload worker's concern, off the hot path; an expired token defers upload, it never threatens "Saved".
- Service consumers (admin, worker) use separate credentials (service role), never user JWTs.

## 14. Derived Rungs

- `transcripts`, `parses`, and `meal_logs` are derived records layered above `saved`. They extend the claim ladder (`transcribed → parsed → logged`); they may never weaken what `saved` means.
- Each derived claim requires its own durable committed artifact. No derived claim may be projected from runtime state or optimistic flags.
- Corrections are append-only new records referencing the parse they correct. A correction never mutates the parse, the transcript, or the capture. Corrections are simultaneously training data and the admin-audit trail.
- A transcription or parse failure is never a capture failure. The audio remains ground truth; derived work retries or is recomputed without ever touching the capture.
- Reparsing or retranscribing produces new derived records referencing the same immutable source. Old derived records are superseded, not edited.
