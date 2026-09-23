# Restructure and harden: capture first (2026-09-23)

> Status: Active
> Owner: @lorenzo
> Branch: restructure/capture-first (tag `restructure-start` = 00e34d1)
> Protocol: Serein's `docs/RESTRUCTURING_PROMPT.md`, applied to Vo-Cal. Phase documents live in
> `docs/restructure/` (00 ground, 01 complaints + ratchets, 02 map, 03 ladder, ledgers).
> Next: R7

## Goal

Leave Vo-Cal working and provably harder to break: every gate honest and running on every push,
a ratchet table that cannot quietly rot, the capture path protected against the failure classes
Serein paid for (poison input, unbounded reads, silent non-convergence), the lifecycle of a
capture written down and finished (recently deleted, corrections that teach), and Lorenzo's
asks landed (Home glyph, Serein's gestures where they fit, the Fly bill explained).

## Tasks

- [x] R0. Phase 0 ground truth (`cfa63bc`); parser-eval made a true ratchet (`d734683`)
- [x] R1. Phase 1 ratchet tables + em-dash slice (`d356080`); em-dash sweeps cherry-picked (`ff7b3c9`, `d2ff9a8`)
- [x] R2. Phase 2 map (`3bdf526`); Home glyph port (`1f49b08`); mock honors sheet edits (`98a02e5`)
- [x] R3. Repair fuse: a CAF repair that killed the last process is never retried; the bundle is quarantined with the bytes kept (self-test scenario)
- [x] R4. Bounds: upload refuses a blob over the server cap before reading it; debug-events.jsonl rotates like observability.jsonl
- [x] R5. Ladder document; CI rewrite (app compile, voice scenarios, parser corpus, tidy, toolchain printed); `.githooks/pre-push`; wiring rows TIDY-CI/HOOK; dead pre-commit config removed
- [x] R6. Crash evidence: MetricKit diagnostics written to a bounded ring in the app group
- [ ] R7. Upload worker: level-triggered passes over the outbox relay jobs (launch, scene active, commit, network back), coordinated with the inline upload, permanent failures quarantined (self-test scenario)
- [ ] R8. Unfinished recordings: captures with no logged meal surface on Today and resume the derived pipeline
- [ ] R9. Lifecycle: corrections diffed against the root parse; learned name corrections applied at parse time and listed in Settings with Forget
- [ ] R10. Lifecycle: Recently deleted meals with Restore (server + Settings), purge documented
- [ ] R11. One address per decision: confidence bar, claim copy, refine amount grammar, grams per ounce
- [ ] R12. Surfaces: Serein's card menus and the committed-receipt haptic where they fit
- [ ] R13. Delete with a census: `scripts/todo`, swiftlint wrapper + pre-commit config, anything the census proves unreachable
- [ ] R14. `docs/CAPTURE_LIFECYCLE.md`, AGENTS routing table, findings + questions ledgers, handoff
- [ ] R15. Ship: full ladder green, merge to main, push, Deploy, TestFlight build 27

## Progress log

| Task | Status | SHA |
|---|---|---|
| R0 | done | cfa63bc, d734683 |
| R1 | done | d356080 |
| R2 | done | 3bdf526, 1f49b08, 98a02e5 |
| R3 + R4 | done | 4748d03 |
| R5 | done | 3dcc987 |
| R6 | done | — |
