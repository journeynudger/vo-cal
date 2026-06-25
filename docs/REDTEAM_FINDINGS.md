# Red-team findings ledger

Exhaustive adversarial red-team: **62 found, 54 confirmed** (3-lens verification), plus a completeness critic.
**26 fixed** with TDD tests (22 the first pass; +4 Batch B durability/dedup this pass);
the rest are tracked below with rationale.

Status: ✅ fixed (commit) · 📋 deferred (see *Deferred work* for grouped rationale).
SHA `pend-B` backfills in the next commit (AGENTS.md: a task's own SHA is backfilled by the next).

| # | Sev | Kind | Status | Finding |
|---|-----|------|--------|---------|
| 00 | critical | correctness | ✅ `eded03c` | Recalibration tree is goal-blind: a GAIN/MAINTAIN user gets their calories CUT, the opposite of their goal |
| 01 | critical | data-loss | ✅ `0ba80ef` | POST /meals stores client-supplied NaN/Infinity/negative macros, poisoning durable totals and /today |
| 02 | critical | spec-violation | 📋 | Confirm trusts client-supplied per-item macros — server never recomputes the numbers (Non-Negotiable #6 violated) |
| 03 | critical | correctness | ✅ `0fa5a8a` | Missing volume/count unit conversion silently substitutes one standard serving while reporting STATED_VOLUME confidence — large silent macro error |
| 04 | high | data-loss | 📋 | admin_reviews rows survive account deletion in the offline suite and in any service-role-bypass path — incomplete data wipe contradicts the router's "total wipe regardless of FK cascade" claim |
| 05 | high | liveness | ✅ `1e725ad` | Unknown-kid tokens force an unrate-limited JWKS refetch (auth-path amplification DoS) |
| 06 | high | test-gap | 📋 | Durability core (CaptureOutbox sqlite) has zero offline/unit test coverage; lease-CAS, quarantine, requeue, migration and applyServerRecord paths are unverifiable |
| 07 | high | data-loss | 📋 | applyQuarantine with leaseToken=nil has no lifecycle-state guard and can force an already-succeeded (uploaded/enriched) capture back to upload_failed |
| 08 | high | liveness | ✅ `pend-B` | Concurrent same client_capture_id retries hit the DB unique constraint and 500 instead of deduping (idempotency / liveness violation) |
| 09 | high | spec-violation | ✅ `eded03c` | Revise silently bumps GAIN/MAINTAIN users to cut-level protein (2.0 g/kg) they never asked for |
| 10 | high | liveness | 📋 | Cold-launch token race: first authed request fires with nil bearer -> 401, no wait/refresh/retry |
| 11 | high | trust | ✅ `0ba80ef` | NaN macros serialize to JSON null in /meals and /today responses; non-optional Swift Double fails to decode -> 'Logged' meal unreadable by client |
| 12 | high | durability | ✅ `pend-B` | Tombstone leaves (user_id, client_meal_id) occupied → outbox replay after delete 500s on live DB (and silently duplicates on FakeDatabase) |
| 13 | high | durability | ✅ `pend-B` | Water logging has no idempotency key — outbox/network replay double-counts water in /today |
| 14 | high | trust | 📋 | Out-of-range fat ratio clamps to nearest anchor but reports the requested ratio as resolved (trust/provenance violation) |
| 15 | high | correctness | ✅ `64b63a4` | POST /parse/refine bypasses ParsedItem.amount gt=0 validation via model_copy, producing negative/NaN grams and macros |
| 16 | high | spec-violation | 📋 | Unknown-ratio ground turkey fires no clarifying question and silently logs the 85/15 default |
| 17 | high | trust | ✅ `7cf46a6` | meal_confidence treats an UNRESOLVED ingredient as a harmless zero-calorie garnish, overstating trust on incomplete totals |
| 18 | high | correctness | 📋 | Obese-cut protocols silently overshoot the calorie budget: carbs clamp to 0 and macros don't reconcile to kcal |
| 19 | high | spec-violation | 📋 | Calorie target derived from IDEAL bodyweight while protein/fat derive from ACTUAL bodyweight — unbounded for high-BMI users |
| 20 | high | correctness | ✅ `eded03c` | Recalibration overwrites protein at fixed 2.0 g/kg, ignoring the user's goal-keyed protein basis |
| 21 | high | liveness | 📋 | Cold-start fast-tap: a crash-orphaned session steals the user's start gesture and resolves it as .finalized, so the first 'record' tap silently fails to start a recording |
| 22 | high | trust | ✅ `ba4d114` | Live capture maps .deferred commit to "Saved" — false durability claim with no LocalCommitReceipt |
| 23 | high | trust | 📋 | Live listening loop never observes coordinator liveness — UI keeps claiming "Listening" after interruption/route-loss/stall (silent dead air) |
| 24 | medium | test-gap | 📋 | App Review 5.1.1(v) deletion correctness rests entirely on a live FK cascade that the offline suite cannot and does not verify (test-gap) |
| 25 | medium | spec-violation | 📋 | Adding a new user-owned table will silently escape account deletion — the deletion table list is a hand-maintained literal with no schema-coverage guard |
| 26 | medium | trust | 📋 | GET /admin/logs returns per-user meal data filterable by user_id with no audit-log entry |
| 27 | medium | liveness | ✅ `e5f9324` | Zero clock-skew leeway rejects freshly-issued valid tokens (iat not-yet-valid) |
| 28 | medium | liveness | 📋 | Capture upload buffers the entire request body into memory before enforcing the 50MB cap (memory-exhaustion DoS) |
| 29 | medium | bug | ✅ `e5f9324` | GET /captures/{id} and DELETE /meals/{id} return 500 (uncaught ValueError) on a non-UUID path param |
| 30 | medium | correctness | 📋 | No cadence/eligibility gate: a 'monthly' recalibration with a calorie cut can fire minutes after intake |
| 31 | medium | test-gap | ✅ `pend-B` | FakeDatabase does not enforce unique_client_capture, so the offline suite silently passes while prod dedup is broken (test gap) |
| 32 | medium | spec-violation | ✅ `e5f9324` | PARSER_CONTRACT.md still mandates "at most ONE question per meal" while the engine ships multi-question (decision #29) — the single-source-of-truth doc contradicts the code |
| 33 | medium | trust | 📋 | Corrections diff is positional — item reorder/removal/insert pollutes append-only training data with false corrections |
| 34 | medium | correctness | ✅ `64b63a4` | _parse_amount_answer silently coerces unparseable/zero/negative answers to bogus quantities instead of rejecting |
| 35 | medium | trust | ✅ `64b63a4` | merge_answer fabricates amount=1.0 for any unparseable amount answer, raising displayed confidence on a non-answer |
| 36 | medium | spec-violation | ✅ `e5f9324` | Few-shot prompt teaches the invalid State enum value "ready", contradicting the tool schema and the Pydantic contract |
| 37 | medium | spec-violation | ✅ `eded03c` | Recalibration leaves stale carbs/fat so stored macros no longer reconcile to kcal |
| 38 | medium | correctness | ✅ `eded03c` | Recalibration clamps a non-cut user's allocation into the fat-loss band, silently cutting calories |
| 39 | medium | durability | 📋 | ProtocolsStore.supersede deactivates the old protocol then inserts the new one with no transaction — a failed insert leaves the user with zero active protocols |
| 40 | medium | trust | 📋 | why-layer claims carbs are 'whatever calories are left after protein and fat' when the budget was actually overshot |
| 41 | medium | test-gap | 📋 | No iOS unit-test target covers API decode contract — protein-band omission and date formats are unverified |
| 42 | medium | correctness | 📋 | transcribe reads a non-existent 'content_type' capture field; every blob is transcribed as audio/x-caf regardless of real upload format |
| 43 | medium | test-gap | 📋 | Kernel DST never generates an unowned/orphaned session co-existing with a fresh toggle request, so the orphan-steals-toggle class is unverified |
| 44 | low | durability | 📋 | Account-deletion cascade destroys parse-quality review verdicts (admin_reviews), conflating user-data erasure with audit/training-signal loss |
| 45 | low | durability | 📋 | 50MB cap enforced only after fully buffering the request body; no upstream Content-Length guard |
| 46 | low | correctness | ✅ `e5f9324` | client_capture_id charset permits '.' and '-' only sequences (e.g. '..', '.'), producing odd but non-escaping storage keys; the regex stops traversal but not dot-only ids |
| 47 | low | bug | ✅ `e5f9324` | delete_meal and get_capture raise 500 on a non-UUID path id instead of 404/422 |
| 48 | low | correctness | ✅ `e5f9324` | Day-view meal ordering sorts by raw stored ISO string, not by instant — wrong order across differing UTC offsets |
| 49 | low | correctness | 📋 | _RATIO_RE captures the trailing two digits, so a 3-digit lean like '100/0' parses lean as 0 (fattiest clamp) |
| 50 | low | trust | 📋 | Answered-but-invalid variant key silently falls back to default and is reported as variant_unspecified=True |
| 51 | low | correctness | ✅ `64b63a4` | merge_answer writes contract-invalid fat_ratio strings because model_copy skips validators |
| 52 | low | correctness | 📋 | protein_min < protein < protein_max invariant breaks at low bodyweight (band collapses on rounding) |
| 53 | low | spec-violation | 📋 | Protein optimal-band half-width is a module constant, not a tunable — violates the formula-pluggable mandate (decision #35) |

---

## Deferred work — grouped follow-ups (with rationale)

The remaining 28 deferred findings are real but were held back because each needs a DB
migration (which only the user applies), a product/policy decision, or a sizeable new test
harness — i.e. not a safe same-session code edit. Grouped by the change they need:

### A. Confirm-path macro authority — RT-02 (critical)
The confirm endpoint sums client-supplied per-item macros instead of recomputing them
(Non-Negotiable #6). The acute sub-case — NaN/Inf/negative poison — is **already closed** by
RT-01 (Macros now rejects them). Full re-resolution at confirm is deferred because
`ConfirmedItem` carries no `variant` field, so re-resolving would *regress* variant-resolved
foods (e.g. sharp→default cheddar). Correct fix needs a contract change: thread `variant`
through `ConfirmedItem`, or key confirm off the stored parse's item provenance and use the
parse row's server-computed macros for kept items. Medium effort, no migration.

### B. Durability fixes needing a migration — RT-08, RT-12, RT-13, RT-31 ✅ (RT-24 → §C)
**Done this pass (`pend-B`).** Migration `20260625000001_dedup_durability.sql` (user runs
`make db-migrate`) + idempotency code + a `FakeDatabase` uniqueness model + TDD tests:
- RT-31 ✅ `FakeDatabase` now mirrors the declared UNIQUE indexes (incl. partial WHERE clauses)
  and raises a typed `UniqueViolationError` — the same type `Database` maps Postgres 23505 onto —
  so dedup/idempotency findings reproduce offline instead of only on a live DB. This is the root;
  the other three are instances it now catches.
- RT-13 ✅ water gains a required `client_water_id` + partial unique index; `log_water` is
  idempotent (get-by-id → insert → catch), so a replay no longer double-counts.
- RT-12 ✅ the meal partial index now excludes soft-deleted rows
  (`WHERE client_meal_id IS NOT NULL AND deleted_at IS NULL`), so a re-log after delete inserts a
  fresh live row instead of colliding with the tombstone (live-DB 500); the router also catches
  the concurrent-replay race.
- RT-08 ✅ `upload_capture` catches the unique violation and returns the deduped row instead of 500.

**Still open: RT-24** (live-DB FK-cascade deletion test) is account-deletion verification — it
belongs with §C, not here. Tracked there.

### C. Account-deletion completeness/policy — RT-04, RT-44, RT-25, RT-26
Core user-data wipe works (App Review 5.1.1(v) is satisfied). Open: `admin_reviews` should be
**anonymized, not cascade-deleted** (per the I2 plan — keep the verdict as training/audit
signal, drop identity) which needs `ON DELETE SET NULL` + an anonymization step (migration +
code, a retention-vs-erasure policy call). RT-25 add a schema-coverage guard so a new
user-owned table can't silently escape the hand-maintained deletion list. RT-26 audit-log the
`/admin/logs` per-user reads.

### D. Protocol high-BMI policy — RT-18, RT-19, RT-40 (needs a PROTOCOL_LOGIC decision)
For a high-BMI cut, calories derive from *ideal* bodyweight while protein/fat derive from
*actual* — so protein+fat can exceed the kcal budget, carbs clamp to 0, macros don't reconcile,
and the why-layer then misstates carbs. The fix is a documented policy choice (raise the floor,
cap protein at the budget, or blend IBW/actual for the calorie basis) — a product decision, not
a silent code change. RT-40 (why-layer wording) rides along once the math policy is set.

### E. iOS capture-core robustness — RT-07, RT-21, RT-10, RT-23, RT-42
Safety-critical voice kernel. RT-07 (`applyQuarantine` can force a succeeded capture back to
failed) and RT-21 (cold-start fast-tap: a crash-orphan steals the start gesture) are real but
touch the kernel state machine and should land *with* DST coverage (see F) to prove no
regression. RT-10 (cold-launch token race → first authed request 401s) and RT-23 (listening
loop never observes coordinator liveness → "Listening" into dead air) are async-coordination
fixes; valuable, next in line. RT-42 (transcribe reads a non-existent `content_type` field, so
every blob is treated as `audio/x-caf`) — store/read the real content type.

### F. Test-harness additions — RT-06, RT-41, RT-43
Large new harnesses, not one-line tests: a `CaptureOutbox` sqlite unit suite (lease-CAS,
quarantine, requeue, migration), an iOS app unit-test target for the API decode contract, and a
kernel-DST generator that produces an unowned orphan co-existing with a fresh toggle (covers
RT-21). Worth doing as dedicated test-hardening.

### G. Nutrition resolver refinements — RT-14, RT-16, RT-49, RT-50
Dictionary family-resolution trust/provenance: an out-of-range fat ratio clamps but reports the
requested ratio (RT-14); unknown-ratio ground *turkey* fires no clarifying question (RT-16); the
ratio regex mis-parses a 3-digit lean like "100/0" (RT-49); an invalid variant key silently
falls back yet reports unspecified (RT-50). One focused `dictionary.py` batch.

### H. Telemetry / observability hardening — critic C1, C3, C4, C5, C8, RT-30, RT-39, RT-52, RT-53
- C1 `client_metrics.attributes` is free-form `dict[str,str]` persisted verbatim → a client can
  ship PII (weights, phone) into durable telemetry + the admin chain (MUST NOT #5). Add a key
  allowlist + value bounds.
- C3 access-log middleware decodes the JWT `sub` **without signature verification** and logs it →
  attacker-controlled `user_id` in the audit trail. Log only verified ids (or mark unverified).
- C4 `CLIENT_EVENTS.labels(name=...)` uses a client string as a Prometheus label →
  cardinality-explosion DoS. Allowlist known event names.
- C5 `rate_limit.py` is dead code (imported nowhere) and is process-local/multi-worker-broken →
  metrics-ingestion, capture-upload, and the JWKS path are all unthrottled. Wire a shared limiter
  (or a gateway-level limit) — an architectural addition.
- C8 `enrichment/worker.py` is an empty Phase-C5 stub → derived rungs only advance when the
  client drives them; a crashed client leaves captures un-enriched. Known roadmap item.
- RT-30 recalibration has no cadence gate (can fire minutes after intake) — add a min-days
  eligibility check. RT-39 `ProtocolsStore.supersede` is non-transactional. RT-52/53 protein-band
  rounding collapse at very low bodyweight + make the band half-width a tunable.
