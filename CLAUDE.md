# Vo-Cal — Claude Code Entry Point

Voice-first calorie/macro tracker. **Not an effortless tracker — the accurate tracker for people willing to do the work.** Photos guess; voice knows. Users speak every ingredient ("4oz 93/7 beef, 200g cooked jasmine rice"); Vo-Cal turns the spoken, fully-specified meal into an accurate log faster than typing. Maintained by Lorenzo Scardicchio.

This is a reuse-first build on two proven foundations:

- **Beacon** (`/Users/lorenzoscardicchio/Downloads/Projects/beacon`) — published iOS app. Source of the project scaffolding: XcodeGen + Swift 6 + SwiftUI app shape, protocol+mock service layer, FastAPI backend shape (router/schemas/store per domain), Supabase, Makefile, observability, CI, App Review guardrails.
- **Serein** (`/Users/lorenzoscardicchio/Downloads/Projects/Serein`) — source of the voice capture layer and its hard-won guardrails: claim ladder (`accepted → mic_active → confirmed_listening → saved`), capture-path isolation, filesystem session ledger, CAF repair, crash recovery, sim voice self-test harness.

**Never edit, delete, or restructure anything inside the Beacon or Serein repos. Copy out only.**

## Read these first

1. **`.claude/memory/INDEX.md`** — what's in memory, when to read each file.
2. **`.claude/plans/MASTER-PLAN.md`** — phase landscape (A–I), dependencies, beta gate, locked decisions.
3. **`.claude/plans/<active-sub-plan>.md`** — open the sub-plan for the work you're picking up; find the first `[ ]` task (or read `> Next:`).
4. **`.claude/plans/README.md`** — plan conventions (checkbox-in-same-commit rule, no hour estimates, amendments).
5. **`AGENTS.md`** — lands in Phase A (task A1). Once it exists it is the canonical engineering doctrine (ported from Serein + Beacon). Until then, `.claude/memory/architecture.md` + `decisions.md` carry the rules.
6. **`docs/VOICE_CAPTURE.md` / `docs/INVARIANTS.md`** — land in Phase A (task A2). Read before touching any voice code, every time.

Then ask the user what we're working on.

## Workflow rules (project-wide)

- **One commit per task. Tick the `[x]` in the sub-plan + backfill the SHA in the progress log in the same commit that ships the task.** The plan file's checkbox state is the cold-resume signal — `git log` alone isn't enough.
- **Branches**: `phase-<letter>-<slug>` (e.g. `phase-c-voice-port`). **Commits**: Conventional Commits with scope — `feat(ios):`, `feat(api):`, `feat(voice):`, `docs(plans):`, `chore(scaffold):`.
- **No human-hour estimates, no t-shirt sizes, no calendar dates** in plans or tasks. Status flags only.
- **TDD where the surface allows it**: failing test → minimum implementation → tick. Parser, protocol engine, and nutrition math are test-first; SwiftUI surfaces verify via the sim harness + UITestMode mocks.
- **Pre-commit gate** (defined in Phase A task A7): `scripts/check-api` for backend-only changes; `scripts/check` for SPM; `bin/ios-app-build` for app changes; `bin/ios-sim-voice-test` after any voice-path change.
- **MUST NOT** (carried from Beacon, require explicit user instruction): no `git commit` / `git push` without approval, no DB resets, no migrations run without the user, never log phone numbers or precise health data values to telemetry.
- **Out of scope — hard MUST NOT build** (P0 contract): photo logging, social features, payments/billing UI, branded/restaurant database, gamification, text-search food logging. If a task seems to need one of these, stop and ask.

## The one thing this build must prove

People will log meals by voice and **trust the output**. Every prioritization question resolves against that. The trust mechanics are Serein's claim ladder (never claim "Saved"/"Listening" without proof) extended with derived rungs: `saved → transcribed → parsed → logged`. Audio is ground truth; the meal log is a derived, user-confirmed record; corrections are append-only new records (they are the training data and the admin-audit trail).

## Design quick reference (full system in `docs/DESIGN.md`, Phase A)

Cal AI screenshot layout, black/gold palette: background `#FAF9F6`, cards `#F4F2EE` radius 24, text `#1A1A1A`/`#8A8A8E`, black pill CTAs `#111111`, gold accent `#C4A35A` for highlighted numerals/active states/confidence, semantic macro colors (protein red / carbs amber / fats blue), SF Pro with 40–64pt semibold numerals.

## What lives where

| Need | Path |
|------|------|
| Phase landscape + beta gate + locked decisions | `.claude/plans/MASTER-PLAN.md` |
| Active sub-plans | `.claude/plans/phase-*.md` |
| Shipped sub-plans (historical) | `.claude/plans/_completed/` |
| Sub-plan template (copy for new plans) | `.claude/plans/sub-plan-template.md` |
| Engineering doctrine (post-A1) | `AGENTS.md` (symlinked as `CLAUDE.md` → stays this file until A1 merges them) |
| Voice doctrine (post-A2) | `docs/VOICE_CAPTURE.md`, `docs/INVARIANTS.md` |
| Parser JSON contract + fixture corpus (post-A2) | `docs/PARSER_CONTRACT.md` |
| Protocol math + "why" templates (post-A2) | `docs/PROTOCOL_LOGIC.md` |
| Stack, data model, project-wide rules | `.claude/memory/architecture.md` |
| Thesis, P0 scope, phase status, open threads | `.claude/memory/product.md` |
| Frozen decisions (23, numbered) | `.claude/memory/decisions.md` |
| What's worked / failed (inherited evidence) | `.claude/memory/patterns-that-{worked,failed}.md` |
| Domain shorthand (claim ladder, FDC, corrections…) | `.claude/memory/glossary.md` |
| Who's who | `.claude/memory/people.md` |

---

*Created 2026-06-12. Plans authored from the approved reuse inventory (Beacon scaffold + Serein voice layer, FastAPI/Supabase single backend, foreground-only capture).*
