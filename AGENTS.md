# AGENTS.md

Vo-Cal is a voice-first calorie/macro tracker built on a safety-critical capture core. Trust is invariant, captures are sacred, and the one thing this build must prove is that **people will log meals by voice and trust the output**.

## Read these first

1. `.claude/memory/INDEX.md` — what's in memory, when to read each file.
2. `.claude/plans/MASTER-PLAN.md` — phase landscape, dependencies, beta gate, locked decisions.
3. The active sub-plan in `.claude/plans/` — find the first `[ ]` task (or read `> Next:`).
4. `docs/VOICE_CAPTURE.md` + `docs/INVARIANTS.md` — **mandatory before touching any voice code, every time.**
5. `docs/PARSER_CONTRACT.md` before parser/nutrition work; `docs/DESIGN.md` before UI work.

Then ask the user what we're working on (or continue the active sub-plan).

## Mission & Non-Negotiables

1. **Safety:** no data loss, no false durability claims, no silent corruption. Audio is ground truth.
2. **Voice-first capture:** the mic-hot path is protected before all secondary surfaces, bookkeeping, or convenience work. Capture must work offline.
3. **Liveness:** interrupted work converges (complete, retry, or quarantine), never wedges.
4. **Facts-first claims:** acknowledge accepted work, never claim stronger states than the facts justify. "Listening" requires byte-flow proof; "Saved" requires a local commit receipt; "Logged" requires a server row. The claim ladder: `accepted → mic_active → confirmed_listening → saved` + derived `transcribed → parsed → logged`.
5. **Raw capture immutability:** captures, transcripts, parses are append-only; corrections are new records referencing the parse — they are the training data and the audit trail.
6. **The LLM extracts; deterministic code calculates.** Macro math, conversions, thresholds, protocol targets are tested Python. The model never invents numbers.
7. **Tenant isolation and auditability:** all cloud state is account-scoped (RLS); admin access to user data is audit-logged.

## Provenance

The voice layer is ported from Serein (production-grade, dogfood-hardened — preserve its decisions; seams that were cut carry "why" comments). The scaffold mirrors Beacon (shipped to the App Store). Everything else is new and agent-authored: treat existing patterns here with the same scrutiny you'd give a PR from an unfamiliar contributor — evaluate on merit.

**Never edit, delete, or restructure anything inside `../beacon` or `../Serein`. Copy out only.**

## How to Think About This Code

### Existing code is not authority

When fixing bugs or adding features, do not treat existing patterns as carefully-made decisions that must be preserved. When complexity is accumulating — guards, special cases, tactical patches, retry loops — the foundation is the bug, not the edge cases.

### Stop the line on failure-class bugs

When a bug touches a system invariant — convergence, liveness, durability, trust — do not jump to a fix. Broaden scope: does the architecture permit this *class* of failure, or just this instance? A narrow patch to an architectural problem is new debt. Prove your fix addresses the class; do not overfit to the trigger.

### Deep couplings

Agents are greedy local optimizers: the cheapest move is to accumulate responsibility in the type that already has the state and the dependency. That produces god objects. **Same storage is fine. Same authority is not.** Stores answer "what is durably true?" Planners answer "what should happen next?" Executors perform effects. Do not fuse these roles. Guards do not fix wrong ownership — repeated generation checks, optionals, and callback gating are evidence the boundary is wrong.

### iOS notifications are observations, not commands

Route changes, configuration changes, scene transitions, lifecycle events: the default response is non-destructive. Destructive action — tearing down a session, finalizing a recording, resetting state — requires evidence beyond the notification: byte-flow loss, hardware change, or a timeout without recovery. (`.categoryChange` means the category changed, not that hardware failed. Serein paid five bugs for that lesson.)

### Capture-path isolation

Capture paths must not be coupled to, delayed by, or gated on any subsystem serving a different concern. The test: **if you delete the subsystem entirely, does capture still work? If yes, it must not be on the capture path.** This applies to app launch, singleton initialization, and any transitive dependency. Serein broke production three times learning this (recovery-scanner notifications killing live recordings; eager worker startup consuming the auth window; one wedged upload blocking all captures).

## How to Write Code

- **Failure paths are first-class:** suspension, force-quit, network loss, partial upload, provider errors, stale retries, permission loss.
- **Parse, don't repeatedly validate.** Boundary code unwraps optionals and classifies OS events; core logic consumes typed values.
- **Optionals belong at boundaries, not the center.** Core subsystem state is not a bag of maybe-values.
- **Require proofs, not booleans.** Stronger truth claims require the proof type or receipt (`LocalCommitReceipt`), never re-derived mutable flags.
- **Silent early returns are not invariant enforcement.** `guard ... else { return }` is fine for lossy telemetry; never on the durability/liveness/trust hot path.
- **Encode coherent state as a type.** Several values that must exist together become a typed context, not independent checks at every callsite.
- **"Why" comments** for non-obvious constraints: **requirement, failure mode, evidence** (date, error code, link). Never restate what the code does. Hard-won platform findings (undocumented API behavior) must be commented at the code site — code is the only artifact agents reliably read.
- Match surrounding style; SwiftUI views read tokens from `VoCalTheme` only — no inline hex.

## Verification Discipline

Agents are timeblind — follow the tier protocol strictly. Run the **narrowest tier that proves the change is correct given the blast radius**. Budgets get measured in A7/C6 and become a ratchet: if verification runs slower than budget, that's a failure to diagnose, not retry.

| Tier | Command | Proves | Blind to | Budget (measured) |
|------|---------|--------|----------|--------|
| API edit loop | `scripts/check-api` | ruff + pytest for `services/api` | All Swift | ~0.5s |
| SPM edit loop | `scripts/check` | SPM libs compile + unit tests, plus check-api | **The iOS app** | swift test ~0.5s incremental pre-port; re-ratchet in C6 |
| iOS compile | `bin/ios-app-build` | App compiles, zero warnings (no simulator) | Runtime behavior | ~7s incremental, ~60s cold |
| Voice runtime | `bin/ios-sim-voice-test` | 9 voice scenarios on the pinned simulator | Real device, real mic | ~45s |
| Parser corpus | `scripts/parser-eval` | No SCORES regression | Everything non-parser | TBD (B7) |

Rules of thumb:

- Changed SPM library **interfaces** → `scripts/check` then `bin/ios-app-build` immediately (the app consumes those interfaces).
- Changed voice coordinator / audio session / outbox → `bin/ios-app-build`, then `bin/ios-sim-voice-test` once at end of task.
- Changed parser/nutrition → `scripts/check-api` + `scripts/parser-eval`; a SCORES regression does not merge.
- **Batch compile fixes:** read the full error output, fix everything, rebuild once.
- **Never run the sim voice test to check compilation** — that's what `ios-app-build` is for.
- Don't guess file paths — search first. Use `python3`, never bare `python`. Don't re-read large files repeatedly — extract to `.tmp/`.

## Task Workflow

1. Open the active sub-plan; work the first `[ ]` task.
2. If touching voice: read `docs/VOICE_CAPTURE.md` + `docs/INVARIANTS.md` first.
3. Determine whether the problem is tactical or architectural before proposing a fix.
4. Verify per the tier table. If verification fails on code you didn't change, report before fixing.
5. **One commit per task. Tick the `[x]` in the sub-plan and backfill the SHA in the progress log in the same commit** (previous task's SHA may be backfilled in the next commit). Conventional Commits with scope: `feat(ios):`, `feat(api):`, `feat(voice):`, `docs(plans):`.
6. Branches: `phase-<letter>-<slug>`. Phase A lands on `main`.

### Definition of Done

Scope satisfied · canonical docs updated · required verification tier green · sub-plan checkbox ticked in the shipping commit · commit exists (push when a remote exists and the user approves).

## MUST NOT Rules

CRITICAL — these require explicit user instruction:

1. **MUST NOT run DB migrations or reset the database** — the user runs `make db-migrate` / `ALLOW_DB_RESET=1 make db-reset`.
2. **MUST NOT `git push`** without explicit approval (commits per task are part of the approved plan workflow).
3. **MUST NOT edit anything in `../beacon` or `../Serein`.**
4. **MUST NOT build out-of-scope features:** photo logging, social, payments/billing UI, branded/restaurant DB, gamification, text-search food logging. If a task seems to need one, stop and ask.
5. **MUST NOT log phone numbers or precise health values** (weights, intake answers) to telemetry; metrics carry durations, counts, and confidence only.
6. **MUST NOT claim UI states above proof** — no "Listening" without byte-flow, no "Saved" without a receipt, no "Logged" without the server row.

## Commands

```bash
make setup / make dev          # deps / local env
make api-dev                   # API on :8000 (logs to .logs/api-dev.log)
scripts/check-api              # ruff + pytest (API edit loop)
scripts/check                  # SPM tests + check-api
bin/ios-app-build              # iOS compile check, no simulator
bin/ios-sim-voice-test         # voice runtime scenarios (end of voice tasks)
scripts/parser-eval            # parser corpus SCORES
make ios-generate && make ios-sim   # XcodeGen + run simulator
make doctor                    # environment diagnostics
scripts/beta-metrics           # the six beta-gate numbers (post-E3)
```

## Repository Layout

Monorepo: SPM libraries (`Sources/VoCalCore`, `Sources/VoCalVoice`, `Tests/`), iOS app (`apps/ios/`), FastAPI + worker (`services/api/`), admin panel (`services/admin-web/`, Phase H), Supabase migrations (`supabase/`), canonical docs (`docs/`), verification scripts (`scripts/`, `bin/`), plans + memory (`.claude/`). Scratch in `.tmp/` (gitignored).

## Identifiers (confirm against Apple account in Phase I0)

- Bundle ID `com.vocal.app` · App group `group.com.vocal.shared` · Scheme `VoCal` · Display name "Vo-Cal"
- Xcode project generated from `apps/ios/project.yml` (the `.xcodeproj` is gitignored — edit `project.yml`, run `make ios-generate`)
- Pinned simulator for voice tests: **iPhone 17 Pro**, UDID `B3428495-B3FC-42EA-8BCD-F743732FA1B7`, iOS 26. `bin/ios-sim-voice-test` builds/boots/installs there, launches the self-test (`--self-test-run-id` arg; `vocal://self-test/...` URL for manual runs), asserts 9/9, and shuts the sim down on exit (`IOS_SIM_KEEP_BOOTED=1` to keep it). Self-test entry self-gates on the launch arg — no-op on normal launches, off the capture path.

## Design quick reference

Cal AI reference layout, black/gold palette: bg `#FAF9F6`, cards `#F4F2EE` r24, ink `#1A1A1A`, muted `#8A8A8E`, CTA `#111111` pills, gold `#C4A35A` (highlight numerals, active states, confidence). Macro semantics: protein red / carbs amber / fats blue. SF Pro; 40–64pt semibold numerals. Light mode only in P0. Full system: `docs/DESIGN.md`.
