# Phase X — <Title>

> Status: Active | Blocked on Y | Queued | Done
> Owner: @lorenzo
> Branch: <branch-name> (omit when on `main`)
> Next: X0

## Goal

One paragraph stating what this phase achieves and why. Should make sense as a cold read — the reader hasn't seen this conversation. Include the wedge ("without this, X can't happen") and the surface ("touches `Sources/Y/`, `services/api/src/api/Z/`").

## Decisions locked

Upfront-committed scope decisions, dated. Prevents re-litigation mid-phase.

- **<decision label>:** <one-line rationale>

## Context

Optional. Cross-plan dependencies, blocked-on signals, scope boundaries. If a sub-plan depends on another sub-plan's task completing first, name it here with a link: `(blocked on [phase-Y-name#yN](./phase-y-name.md))`.

---

## Tasks

### X0. <Task title>

One-line preamble: what this task does and why it's its own task.

- [ ] **Step 1.** <Concrete action with file paths>
- [ ] **Step 2.** <...>
- [ ] **Test:** <failing test → minimum impl → tick> *(optional for non-code tasks)*
- [ ] **Acceptance:** <what proves this is done>
- [ ] **Commit:** `<conventional commit message>`

### X1. <Task title>

One-line preamble.

- [ ] **Step 1.** ...
- [ ] **Acceptance:** ...
- [ ] **Commit:** `<conventional commit message>`

---

## Exit Criteria

- ✅ <Outcome 1 — observable, not aspirational>
- ✅ <Outcome 2>

## Amendments

Scope changes during the phase, dated.

### YYYY-MM-DD — <one-line summary>

<Body explaining what changed and why. Cite the trigger.>

---

## Progress log

Mark each task inline above with `[ ]` / `[x]` / `[~]` / `[!]` as it ships. The table below mirrors that for at-a-glance scanning.

| Task | Status | SHA |
|---|---|---|
| X0 ... | not started | — |
