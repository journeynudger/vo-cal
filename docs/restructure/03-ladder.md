# 03. The verification ladder

Cheapest first. Each rung: the command, what it proves, what it is blind to, how long it
takes on a warm Mac (2026-09-23). The routing table below maps a change to the narrowest
rung that proves it; never route by directory alone.

| # | Rung | Command | Proves | Blind to | Duration |
|---|---|---|---|---|---|
| 1 | API logic | `scripts/check-api` | ruff clean; 744 offline tests including the Python ratchet table | anything Swift; live providers (the suite runs on FakeDatabase and recorded fixtures) | 14 s |
| 2 | Library logic | `swift test` | 59 tests in 10 suites: parser contract round-trips, the voice kernel DST sweep, the relay planner, CAF repair, the Swift ratchet table and the CI/hook wiring | the app target (nothing in `apps/ios` compiles here) | 0.2 s warm, ~20 s after a source change |
| 3 | The ratchet tables | inside 1 and 2 | banned shapes stay banned, ceilings only fall, the ladder stays wired | anything a regex cannot see | included |
| 4 | Parser corpus | `scripts/parser-eval` | 45 fixtures: extraction, fields, questions, the canonical four; fails on any regression from the committed SCORES.md | pricing (the dictionary-only resolver), live models | 1 s |
| 5 | App compile | `bin/ios-app-build` | every app target compiles with zero warnings; SPM interface changes reach their consumers; prints and budgets its own wall clock | runtime behavior | 7 s incremental, ~60 s cold |
| 6 | Voice runtime scenarios | `bin/ios-sim-voice-test` | eleven named scenarios on the pinned simulator with isolated storage roots and structured pass/fail events: golden path, interruption, route change, process death, permission denial, blocked deadline, stall, CAF repair, corrupt-bundle quarantine, repair fuse, upload worker convergence | a real device and a real microphone; the network | 31 s with the simulator booted, ~2 min cold |
| 7 | Voice kernel simulation | `bin/voice-dst --smoke` | 200 seeds of randomized events with injected faults over the pure kernel; named invariants after every step; replayable by seed | the executor around the kernel, the platform | 8 s |
| 8 | Live pricing evals | `scripts/calorie-eval`, `scripts/consistency-eval` | 72 utterances inside honest calorie bands; 7 phrasing groups within 15% of each other and inside their band, including the edit-sheet step | needs `.env` keys and a live :8001 server; not a merge gate | 6 min, 2 min |
| 9 | Artifact inspection | `scripts/review <meal_id>`, `curl :8000/__dev/db/summary` | what the product actually wrote: transcript, parse JSON, confirmed items, corrections, signed audio | everything else | seconds |
| 10 | Prod smoke | `scripts/smoke-prod https://vo-cal.fly.dev` | the deployed `/health`; with a token, an authed parse and a water write | anything not on those routes | 0.3 s |

Rungs judged unnecessary: a boot-and-click smoke of the whole app (rung 5 of the protocol),
because Swift compiles and rung 6 exercises the critical path in the real environment; the
app has no unit test target and none is added, because the surfaces read state that the
library and the server already test.

## Routing

| Scope of change | Run |
|---|---|
| `services/api` logic, schemas, seed, prompts | 1, then 4; 8 when the resolver, estimator, dictionary or prompts changed |
| `Sources/` (library interfaces) | 2, then 5 |
| `apps/ios` outside `Voice/` | 5 |
| `apps/ios/VoCal/Voice/`, the coordinator, outbox, kernel, self-test | 5, then 6 (and 7 for the kernel) |
| `bin/`, `scripts/`, `.github/`, `.githooks/` | 2 (the wiring rows) plus the script itself |
| A response shape the shipped app decodes | 1 and 2 (the Swift mirror's round-trip tests), then 5 |
| Before a push | the hook runs 1 and 2; run 5 yourself when `apps/ios` changed |
| Before a TestFlight build | 1, 2, 4, 5, 6, 7; 8 if pricing changed; 10 after the deploy |

## Where the gate lives when nobody is working

`.github/workflows/ci.yml` runs rungs 1, 2, 4, 5, 6 and 7 on every push to main and every
pull request, nightly, and on request, with the toolchain printed and no silent fallback.
`.githooks/pre-push` runs rungs 1 and 2 before a push leaves the Mac. The Swift ratchet
table asserts both files still invoke those rungs (`TIDY-CI-001`, `TIDY-HOOK-001`) and that
no pre-commit config pretends to be a gate (`TIDY-HOOK-002`). Branch protection on `main`
requires the three CI jobs; administrators can still push directly, which is why the hook
exists.

## Caches

SwiftPM `.build/`; `DerivedData/ios-sim` (delete only `Build`, `ModuleCache.noindex` and
`SourcePackages` inside it when module interfaces go stale, never the folder); the API's
`usda_cache` rows (in-memory and fresh per test on FakeDatabase). Nothing on the ladder
reuses a result cache between runs.
