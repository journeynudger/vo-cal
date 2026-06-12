# Patterns That Worked

Inherited from Beacon (shipped), Serein (dogfood-hardened), doccure/valerin (workflow). Validated elsewhere — treat as defaults here, and add Vo-Cal-earned entries as phases land.

## Workflow

- **Master plan + 1–2 active sub-plans; checkbox ticked in the shipping commit.** The plan file is the cold-resume signal; `git log` alone isn't enough. (valerin/doccure)
- **One commit per task, Conventional Commits with scope.** Cheap reverts, readable log. (all three)
- **TDD on engines** (parser, nutrition math, protocol rules, recommendation table): failing test → minimum impl → tick. UI verifies via harnesses instead.
- **No human-hour estimates or t-shirt sizes in plans.** AI execution time correlates with neither. (doccure)

## Voice / iOS (Serein)

- **Claim ladder with proof types.** "Saved" requires a `LocalCommitReceipt`; "Listening" requires byte-flow evidence. Compile-time honesty beats discipline.
- **Filesystem-only session ledger; outbox touched once at finalization.** In-progress state never in SQLite — crash recovery operates on storage observations only.
- **Sim self-test harness as the regression net.** 9 scripted scenarios catch mic-path regressions before any human notices; run after any voice-path change.
- **JSONL milestone trace (`debug-events.jsonl`) as the runtime truth channel.** Startup milestones make "why was capture slow" answerable retroactively.
- **Three-part "why" comments: requirement, failure mode, evidence** (date/error/link). The only artifact future agents reliably read is the code site.
- **Batch compile fixes.** Read the full error output, fix everything, rebuild once. One-at-a-time fixing cascades 3–5 sequential builds.
- **Compile check ≠ behavior check.** `bin/ios-app-build` for compile feedback; sim-test once at end of task. Never boot a simulator to learn whether code compiles.
- **Verify platform behavior on device when safety-critical.** Apple docs describe intent, not reality (CLLocationUpdate cadence, ActivityKit background rejection). If unverifiable, note the assumption in a why-comment.

## App architecture (Beacon)

- **Services behind protocols with mock implementations, swapped by `-UITestMode`.** Every screen state reachable with zero network; UI tests don't flake on backends.
- **XcodeGen `project.yml` as source of truth, `.xcodeproj` gitignored.** No project-file merge conflicts, reproducible generation.
- **Observability from day one:** request-timing middleware, instrumented DB client, client-metrics ingestion. Vo-Cal's beta gate (<30s logs, correction rate) is measured by this, not estimated.
- **Domain packages with router/schemas/store.** Boring, predictable, easy for any session to navigate.

## AI pipelines (doccure + this plan)

- **Corpus regression net with committed SCORES.** A fixture corpus of real messy inputs, scored on every change; regressions don't merge.
- **Recorded provider responses in tests; live calls behind a marker.** CI never depends on ElevenLabs/FDC/Anthropic uptime.
- **Tool-forced structured output + Pydantic post-validation + one retry with the error appended.** Schema enforcement at the API layer, not hope in the prompt.
- **Hard rules in the prompt; determinism in the code.** Never let the model invent numbers; few-shot from the same corpus that scores it.
- **Prompt versioning stamped on every artifact row.** When quality moves, you can attribute it.
