# 00. Ground truth

> Restructuring and hardening pass (protocol: Serein's `docs/RESTRUCTURING_PROMPT.md`,
> applied to Vo-Cal by Lorenzo's ask, 2026-09-23). Branch `restructure/capture-first`,
> starting tag `restructure-start` = `00e34d1` (main after TestFlight build 26).
> Restore: while the branch is unshared, `git checkout main && git branch -D
> restructure/capture-first`; once pushed, a range revert of the merge. Verified in a
> throwaway worktree, never against the working tree.

## The four questions

| Question | Answer | Consequence |
|---|---|---|
| Compile or type-check step? | Yes: Swift (`swift build`, `xcodebuild`); Python has ruff only, no type checker | Zero-warning ratchet applies to Swift; Python's "warnings" are ruff findings |
| A rendering surface a person looks at? | Yes: the iOS app (`apps/ios`) | Phase 5 applies in full |
| Ships to machines we do not control? | Yes: TestFlight (build 26 live), the API on Fly (`vo-cal.fly.dev`) | Contracts the shipped client reads are frozen (Phase 2.6) |
| Long-lived background work over durable state? | Yes on the phone: the capture outbox and upload worker (`apps/ios/VoCal/Voice/CaptureOutbox.swift`). On the server the enrichment worker is a stub; the pipeline is request-driven with client polling | Phase 3's level-triggered and poison-input items apply to the phone side |

## Stack table

| | Swift side | Python side |
|---|---|---|
| Language | Swift 6.2, iOS 26.0 deployment target, Xcode 26 (release only on this Mac) | Python 3.13 (`.venv`), FastAPI |
| Package manager | SwiftPM (`Package.swift`: VoCalCore, VoCalCapture, VoCalVoice + 3 test targets); XcodeGen (`apps/ios/project.yml`) generates the gitignored `VoCal.xcodeproj` | uv (`services/api/pyproject.toml`, `uv.lock`) |
| Test runner | Swift Testing via `swift test`; app runtime scenarios via `bin/ios-sim-voice-test` (self-test JSONL) | pytest (`services/api/tests`) |
| Type checker | the compiler | none |
| Formatter / linter | none configured (a `.pre-commit-config.yaml` names swiftlint, which is not installed and has no config: inert) | ruff (`ruff check`; `ruff format` only through the inert pre-commit config) |
| Zero warnings maps to | `bin/ios-app-build` greps `warning:` out of the xcodebuild log and fails on any; `swift test` builds warning-free today (not asserted) | `uv run ruff check .` clean |
| The fast loop | `swift test` (0.04 s warm, ~20 s after a source change) | `scripts/check-api` (ruff + pytest, 13.4 s, 736 passed, 5 deselected live tests) |
| Build everything | `scripts/check` (swift test + check-api) then `bin/ios-app-build` (7 s incremental, 60 s cold) | same |
| Run the real app | `make ios-sim` / `bin/ios-sim-voice-test` (pinned iPhone 17 Pro, UDID in the script); Debug builds use mock services unless `-LiveServices` | `scripts/ensure-dev-server.sh` (:8000, X-Test-User seam) or the live server for evals (`FORCE_OFFLINE=true DEV_ENDPOINTS=true DEBUG=true TEST_MODE=false uv run uvicorn api.main:app --port 8001`) |
| Entry points | `apps/ios/VoCal/VoCalApp.swift` (AppRootView); voice: `Voice/VoiceCaptureCoordinator.swift` | `services/api/src/api/main.py:create_app` |
| Tests live in | `Tests/` (SPM), the self-test runtime in `apps/ios/VoCal/Voice/VoiceSelfTestRuntime.swift` | `services/api/tests/` (offline, FakeDatabase) |

Repository topology: one monorepo. SPM libraries in `Sources/`, the app in `apps/ios/`,
the API in `services/api/`, Supabase migrations in `supabase/`, verification scripts in
`bin/` and `scripts/`, plans and memory in `.claude/`.

## Every check, run once (2026-09-23, warm Mac)

| Check | Command | Printed | Duration |
|---|---|---|---|
| API lint + tests | `scripts/check-api` | `All checks passed!` / `736 passed, 5 deselected` | 13.4 s |
| SPM tests | `swift test` | `Test run with 53 tests in 8 suites passed` | 0.04 s warm; ~20 s after a change |
| SPM + API | `scripts/check` | both of the above | ~30 s |
| Parser corpus | `scripts/parser-eval` | `corpus: 45 fixtures | extraction F1 1.000 | field acc 1.000 | Q P/R 0.67/1.00`, `canonical-four: PASS` | ~1 s |
| iOS compile, zero warnings | `bin/ios-app-build` | `✓ ios-app-build green (zero warnings)` | 7 s incremental, ~60 s cold |
| Voice runtime scenarios | `bin/ios-sim-voice-test` | `RESULT=PASS PASSED=9 FAILED=0` | 39.234 s wall clock (booted simulator, warm build) |
| Voice kernel simulation | `bin/voice-dst --smoke` | 200 seeds `PASSED`, `Test run with 1 test in 1 suite passed` | 8.2 s |
| Calorie corpus (live) | `scripts/calorie-eval` against a live :8001 | `CALORIE-EVAL: 72/72 passed | latency p50 3441ms p95 11426ms` | ~6 min, needs `.env` keys |
| Consistency (live) | `scripts/consistency-eval` | `CONSISTENCY-EVAL: 7/7 groups passed` | ~2 min, needs `.env` keys |
| Prod smoke | `scripts/smoke-prod https://vo-cal.fly.dev` | `/health green; authed steps skipped (no token)` | 0.3 s |
| Diagnostics | `scripts/doctor.sh` | warns: supabase CLI, swiftlint, docker absent; API on :8000 | 1 s |
| Admin CLI self-test | `scripts/review --selftest` | pure helpers pass on synthetic rows | 2 s |
| Beta metrics self-test | `scripts/beta-metrics --selftest` | six gate numbers on synthetic rows | 2 s |
| Task tracker | `scripts/todo status` | `0/0 done` (no `todo.json` exists) | dead tool, see findings |
| Metrics dashboard | `scripts/metrics-dashboard --once` | needs a running server; not measured | |
| CI | `.github/workflows/ci.yml` on push to main and PRs | API job 25 s, SPM job 35 s (run 35914262779) | |

## Audit for lying (0.3) and proofs each gate can fail (0.4)

Proofs ran in a throwaway `git worktree`, one break each, restored to a clean tree:

| Gate | Break | Result | Verdict |
|---|---|---|---|
| `swift test` | an added `#expect(1 == 2)` | `Test run with 54 tests in 9 suites failed` | honest |
| `scripts/check-api` | an added `assert 1 == 2` | `1 failed, 6 passed` | honest |
| `ruff check` | an unused import | `Found 1 error` | honest |
| `scripts/parser-eval` | canonical_beef expecting "ground pork" | **`PASS`, exit 0** before this pass | **liar**, fixed in `d734683`: the committed SCORES.md is now the baseline and any metric moving down fails; re-proved: `GATE FAIL: canonical-four names regressed: canonical_beef`, exit 1 |
| `bin/ios-app-build` | (read) fails on `error:` and on any `warning:` line | honest; no wall-clock budget (0.7) |
| `bin/ios-sim-voice-test` | (read) exits 1 on `failed_count > 0` or a 240 s timeout | prints "9/9" unconditionally on success even for a `--scenarios` subset; `passed_count` is not compared to the requested count. Fix owed (0.6). |
| CI SPM job | (read) `xcode-select -s Xcode_26.2.app \|\| xcode-select -s Xcode.app` | a missing 26.2 silently falls back to whatever `Xcode.app` is; the job never prints the toolchain. Fix owed in the CI commit. |
| `.pre-commit-config.yaml` | (read) | no hook is installed in `.git/hooks`, swiftlint is not on the machine: a gate that exists only on paper (F19). Replaced by `.githooks/pre-push` in Phase 3. |

Caches: SwiftPM `.build/`, `DerivedData/ios-sim` (delete only `Build`, `ModuleCache.noindex`,
`SourcePackages` inside it when module interfaces go stale), the API's `usda_cache` rows
(FakeDatabase in tests: fresh per test). No gate silently reuses a result cache.

## Flake quarantine (0.5)

`scripts/check-api` ran nine times in the session that preceded this pass (all green,
732 to 736 passed as tests were added); `swift test` six times (53 passed each);
`bin/ios-sim-voice-test` once here and in every prior voice task (9/9). Quarantine list:
empty. The live evals (calorie, consistency) depend on the estimator's first answer for a
novel food and are not part of any gate that blocks a merge; their variance is recorded in
`.claude/plans/voice-consistency-2026-09-23.md`.

## Performance baseline (0.9)

| Measure | Value | How |
|---|---|---|
| API test suite | 13.4 s for 736 tests | `time scripts/check-api` |
| Parse latency, live | p50 3.4 s, p95 11.4 s over 72 utterances | `scripts/calorie-eval` |
| iOS compile | 7 s incremental, ~60 s cold | `time bin/ios-app-build` |
| Release app bundle | 7.1 MB (`VoCal.app` inside `.build/VoCal.xcarchive`, build 26) | `du -sh` |
| App cold start, memory high water mark | not measured | no harness on the simulator; unverified |

## Ladder rungs that do not apply here

- Rung 5 (boot the app and exercise the critical path in a stack with no compile step):
  Swift compiles; the voice runtime scenarios (rung 6) are the real-environment check.
- Rung 8 (seeded deterministic simulation): exists already, `bin/voice-dst`, over the voice
  kernel in `Sources/VoCalVoice`; not built anew.
