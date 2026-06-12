# Plans

Master plan + sub-plans live here. Same system as valerin-platform and doccure-ai.

## Layout

- `MASTER-PLAN.md` — top-level roadmap: phases A–I, dependencies, beta gate, locked decisions, amendments log.
- `phase-<letter>-<slug>.md` — one sub-plan per phase. At most 1–2 **Active** at a time; the rest stay **Queued** until their dependencies clear.
- `_completed/` — finished sub-plans, kept for the historical record. Move a sub-plan here in the same commit that ticks its last task.
- `sub-plan-template.md` — copy when generating a new sub-plan.

## Conventions

- Lead with **Status / Owner / Branch / Next** metadata so a session can pick up cold.
- Task lists use `- [ ]` / `- [x]` / `- [~]` (in progress) / `- [!]` (blocked) checkboxes.
- **One commit per task.** Tick the `[x]` and backfill the SHA in the progress log **in the same commit that ships the task**. If a task ships in multiple commits (CI failure, scope growth), list the final SHA. If you find an unticked shipped task, backfill with `docs(plans): backfill checkbox state for <slug>`.
- Every task ends with an **Acceptance** bullet (observable proof, not aspiration) and a **Commit** line (conventional message).
- **No timeline dates in plan files** — status flags only (`Active`, `Blocked on X`, `Queued`, `Done`). Dates appear only in Amendments/Decisions entries (as record of when a decision was made).
- **No human-hour estimates, no t-shirt sizes.** AI execution time bears no relationship to either.
- Scope changes during a phase go in that sub-plan's **Amendments** section, dated. Cross-phase scope changes go in the master plan's Amendments log.
- Branches: `phase-<letter>-<slug>`. Commits: Conventional Commits with scope (`feat(api):`, `feat(ios):`, `feat(voice):`, `docs(plans):`).
