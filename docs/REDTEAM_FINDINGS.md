# Red-team findings ledger

Generated from the exhaustive adversarial red-team (62 found, 54 confirmed via 3-lens verification). 
Status: ☐ open · ▶ in progress · ✅ fixed (commit) · 📋 deferred (rationale).

| # | Sev | Kind | Status | Finding | Location |
|---|-----|------|--------|---------|----------|
| 00 | critical | correctness | ☐ | Recalibration tree is goal-blind: a GAIN/MAINTAIN user gets their calories CUT, the opposite of their goal | `services/api/src/api/checkin/recommend.py` |
| 01 | critical | data-loss | ☐ | POST /meals stores client-supplied NaN/Infinity/negative macros, poisoning durable totals and /today | `services/api/src/api/nutrition/schemas.py` |
| 02 | critical | spec-violation | ☐ | Confirm trusts client-supplied per-item macros — server never recomputes the numbers (Non-Negotiable #6 violated) | `services/api/src/api/meals/router.py` |
| 03 | critical | correctness | ☐ | Missing volume/count unit conversion silently substitutes one standard serving while reporting STATED_VOLUME confidence — large silent macro error | `services/api/src/api/nutrition/resolver.py` |
| 04 | high | data-loss | ☐ | admin_reviews rows survive account deletion in the offline suite and in any service-role-bypass path — incomplete data wipe contradicts the router's "total wipe regardless of FK cascade" claim | `services/api/src/api/account/router.py` |
| 05 | high | liveness | ☐ | Unknown-kid tokens force an unrate-limited JWKS refetch (auth-path amplification DoS) | `services/api/src/api/auth.py` |
| 06 | high | test-gap | ☐ | Durability core (CaptureOutbox sqlite) has zero offline/unit test coverage; lease-CAS, quarantine, requeue, migration and applyServerRecord paths are unverifiable | `apps/ios/VoCal/Voice/CaptureOutbox.swift` |
| 07 | high | data-loss | ☐ | applyQuarantine with leaseToken=nil has no lifecycle-state guard and can force an already-succeeded (uploaded/enriched) capture back to upload_failed | `apps/ios/VoCal/Voice/CaptureOutbox.swift` |
| 08 | high | liveness | ☐ | Concurrent same client_capture_id retries hit the DB unique constraint and 500 instead of deduping (idempotency / liveness violation) | `services/api/src/api/captures/router.py` |
| 09 | high | spec-violation | ☐ | Revise silently bumps GAIN/MAINTAIN users to cut-level protein (2.0 g/kg) they never asked for | `services/api/src/api/checkin/recommend.py` |
| 10 | high | liveness | ☐ | Cold-launch token race: first authed request fires with nil bearer -> 401, no wait/refresh/retry | `apps/ios/VoCal/VoCalApp.swift` |
| 11 | high | trust | ☐ | NaN macros serialize to JSON null in /meals and /today responses; non-optional Swift Double fails to decode -> 'Logged' meal unreadable by client | `services/api/src/api/meals/router.py` |
| 12 | high | durability | ☐ | Tombstone leaves (user_id, client_meal_id) occupied → outbox replay after delete 500s on live DB (and silently duplicates on FakeDatabase) | `services/api/src/api/meals/store.py` |
| 13 | high | durability | ☐ | Water logging has no idempotency key — outbox/network replay double-counts water in /today | `services/api/src/api/meals/schemas.py` |
| 14 | high | trust | ☐ | Out-of-range fat ratio clamps to nearest anchor but reports the requested ratio as resolved (trust/provenance violation) | `services/api/src/api/nutrition/dictionary.py` |
| 15 | high | correctness | ☐ | POST /parse/refine bypasses ParsedItem.amount gt=0 validation via model_copy, producing negative/NaN grams and macros | `services/api/src/api/parser/clarify.py` |
| 16 | high | spec-violation | ☐ | Unknown-ratio ground turkey fires no clarifying question and silently logs the 85/15 default | `services/api/src/api/nutrition/dictionary.py` |
| 17 | high | trust | ☐ | meal_confidence treats an UNRESOLVED ingredient as a harmless zero-calorie garnish, overstating trust on incomplete totals | `services/api/src/api/parser/confidence.py` |
| 18 | high | correctness | ☐ | Obese-cut protocols silently overshoot the calorie budget: carbs clamp to 0 and macros don't reconcile to kcal | `services/api/src/api/protocols/engine.py` |
| 19 | high | spec-violation | ☐ | Calorie target derived from IDEAL bodyweight while protein/fat derive from ACTUAL bodyweight — unbounded for high-BMI users | `services/api/src/api/protocols/engine.py` |
| 20 | high | correctness | ☐ | Recalibration overwrites protein at fixed 2.0 g/kg, ignoring the user's goal-keyed protein basis | `services/api/src/api/protocols/router.py` |
| 21 | high | liveness | ☐ | Cold-start fast-tap: a crash-orphaned session steals the user's start gesture and resolves it as .finalized, so the first 'record' tap silently fails to start a recording | `Sources/VoCalVoice/VoiceCaptureModels.swift` |
| 22 | high | trust | ☐ | Live capture maps .deferred commit to "Saved" — false durability claim with no LocalCommitReceipt | `apps/ios/VoCal/ViewModels/VoiceLogViewModel.swift` |
| 23 | high | trust | ☐ | Live listening loop never observes coordinator liveness — UI keeps claiming "Listening" after interruption/route-loss/stall (silent dead air) | `apps/ios/VoCal/ViewModels/VoiceLogViewModel.swift` |
| 24 | medium | test-gap | ☐ | App Review 5.1.1(v) deletion correctness rests entirely on a live FK cascade that the offline suite cannot and does not verify (test-gap) | `services/api/tests/test_account_api.py` |
| 25 | medium | spec-violation | ☐ | Adding a new user-owned table will silently escape account deletion — the deletion table list is a hand-maintained literal with no schema-coverage guard | `services/api/src/api/account/router.py` |
| 26 | medium | trust | ☐ | GET /admin/logs returns per-user meal data filterable by user_id with no audit-log entry | `services/api/src/api/admin/router.py` |
| 27 | medium | liveness | ☐ | Zero clock-skew leeway rejects freshly-issued valid tokens (iat not-yet-valid) | `services/api/src/api/auth.py` |
| 28 | medium | liveness | ☐ | Capture upload buffers the entire request body into memory before enforcing the 50MB cap (memory-exhaustion DoS) | `services/api/src/api/captures/router.py` |
| 29 | medium | bug | ☐ | GET /captures/{id} and DELETE /meals/{id} return 500 (uncaught ValueError) on a non-UUID path param | `services/api/src/api/captures/router.py` |
| 30 | medium | correctness | ☐ | No cadence/eligibility gate: a 'monthly' recalibration with a calorie cut can fire minutes after intake | `services/api/src/api/checkin/router.py` |
| 31 | medium | test-gap | ☐ | FakeDatabase does not enforce unique_client_capture, so the offline suite silently passes while prod dedup is broken (test gap) | `services/api/src/api/db.py` |
| 32 | medium | spec-violation | ☐ | PARSER_CONTRACT.md still mandates "at most ONE question per meal" while the engine ships multi-question (decision #29) — the single-source-of-truth doc contradicts the code | `docs/PARSER_CONTRACT.md` |
| 33 | medium | trust | ☐ | Corrections diff is positional — item reorder/removal/insert pollutes append-only training data with false corrections | `services/api/src/api/meals/router.py` |
| 34 | medium | correctness | ☐ | _parse_amount_answer silently coerces unparseable/zero/negative answers to bogus quantities instead of rejecting | `services/api/src/api/parser/clarify.py` |
| 35 | medium | trust | ☐ | merge_answer fabricates amount=1.0 for any unparseable amount answer, raising displayed confidence on a non-answer | `services/api/src/api/parser/clarify.py` |
| 36 | medium | spec-violation | ☐ | Few-shot prompt teaches the invalid State enum value "ready", contradicting the tool schema and the Pydantic contract | `services/api/src/api/parser/prompts.py` |
| 37 | medium | spec-violation | ☐ | Recalibration leaves stale carbs/fat so stored macros no longer reconcile to kcal | `services/api/src/api/protocols/router.py` |
| 38 | medium | correctness | ☐ | Recalibration clamps a non-cut user's allocation into the fat-loss band, silently cutting calories | `services/api/src/api/checkin/recommend.py` |
| 39 | medium | durability | ☐ | ProtocolsStore.supersede deactivates the old protocol then inserts the new one with no transaction — a failed insert leaves the user with zero active protocols | `services/api/src/api/protocols/store.py` |
| 40 | medium | trust | ☐ | why-layer claims carbs are 'whatever calories are left after protein and fat' when the budget was actually overshot | `services/api/src/api/protocols/why.py` |
| 41 | medium | test-gap | ☐ | No iOS unit-test target covers API decode contract — protein-band omission and date formats are unverified | `apps/ios/VoCal/Services/TodayModels.swift` |
| 42 | medium | correctness | ☐ | transcribe reads a non-existent 'content_type' capture field; every blob is transcribed as audio/x-caf regardless of real upload format | `services/api/src/api/transcribe/router.py` |
| 43 | medium | test-gap | ☐ | Kernel DST never generates an unowned/orphaned session co-existing with a fresh toggle request, so the orphan-steals-toggle class is unverified | `Tests/VoCalVoiceTests/VoiceKernelDSTTests.swift` |
| 44 | low | durability | ☐ | Account-deletion cascade destroys parse-quality review verdicts (admin_reviews), conflating user-data erasure with audit/training-signal loss | `supabase/migrations/20260612000001_initial.sql` |
| 45 | low | durability | ☐ | 50MB cap enforced only after fully buffering the request body; no upstream Content-Length guard | `services/api/src/api/captures/router.py` |
| 46 | low | correctness | ☐ | client_capture_id charset permits '.' and '-' only sequences (e.g. '..', '.'), producing odd but non-escaping storage keys; the regex stops traversal but not dot-only ids | `services/api/src/api/captures/router.py` |
| 47 | low | bug | ☐ | delete_meal and get_capture raise 500 on a non-UUID path id instead of 404/422 | `services/api/src/api/meals/router.py` |
| 48 | low | correctness | ☐ | Day-view meal ordering sorts by raw stored ISO string, not by instant — wrong order across differing UTC offsets | `services/api/src/api/meals/store.py` |
| 49 | low | correctness | ☐ | _RATIO_RE captures the trailing two digits, so a 3-digit lean like '100/0' parses lean as 0 (fattiest clamp) | `services/api/src/api/nutrition/dictionary.py` |
| 50 | low | trust | ☐ | Answered-but-invalid variant key silently falls back to default and is reported as variant_unspecified=True | `services/api/src/api/nutrition/dictionary.py` |
| 51 | low | correctness | ☐ | merge_answer writes contract-invalid fat_ratio strings because model_copy skips validators | `services/api/src/api/parser/clarify.py` |
| 52 | low | correctness | ☐ | protein_min < protein < protein_max invariant breaks at low bodyweight (band collapses on rounding) | `services/api/src/api/protocols/engine.py` |
| 53 | low | spec-violation | ☐ | Protein optimal-band half-width is a module constant, not a tunable — violates the formula-pluggable mandate (decision #35) | `services/api/src/api/protocols/engine.py` |
