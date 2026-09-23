# 01. The ratchet tables and the bug-pinning convention

## Where the rules live

- Swift and the app: `Tests/VoCalCoreTests/TidyTests.swift`, run by `swift test`, so by
  `scripts/check`, the push hook and CI. Scans tracked `.swift` files under each rule's
  roots (`git ls-files`), skipping comment lines.
- Python: `services/api/tests/test_tidy.py`, run by `scripts/check-api`. Scans tracked
  `.py` files, skipping comments and docstrings.

Both hold the same contract: rows are data (`id`, `description` phrased as the fix, `roots`,
`pattern`, `max`, and for a nonzero ceiling the exact `expectedPaths`); one enforcer runs
every row and fails with the id, the description, `observed=N max=M` and the first fifty
violations as `path:line: source line`; a meta-test checks ids are unique and well formed,
roots exist, patterns compile, and nonzero ceilings carry their path set.

## The three kinds, and the rule about rules

Every row states its kind in the comment above it:

- **Incident:** date, environment, the symptom as the user saw it, the mechanism.
- **Supersession:** names the replacement in the description, phrased as the fix.
- **Boundary:** cites the layer contract it enforces (a doc section).

A rule that is none of the three is a guess and does not go in. Ceilings never rise:
to land code that violates a rule, fix the code or shrink the rule. No inline suppression
exists. Raising a ceiling or adding an exception needs the owner's word in the conversation,
a written argument, and the condition under which it goes away.

## Installed rows

| Id | Kind | What it holds |
|---|---|---|
| TIDY-SPM-{UIKIT,SWIFTUI,AVFOUNDATION,SUPABASE}-001 | boundary | `Sources/` imports no UI or platform framework; the libraries run in `scripts/check` without the iOS SDK |
| TIDY-CONC-001 | supersession | no `DispatchQueue` in app or library code |
| TIDY-CONC-002 | supersession | no `Task.detached` |
| TIDY-CONC-003 | supersession | `@unchecked Sendable` stays at its two named bridges |
| TIDY-CAPTURE-001 | boundary | the capture path never references the API client, auth, Supabase or a dashboard model |
| TIDY-INK-001 | boundary | no raw hex or `Color(red:)` outside `VoCalTheme.swift` |
| TIDY-WORDS-001 | incident | no em dash in a Swift string literal |
| TIDY-XCG-001 | boundary | generated projects and build products stay untracked |
| TIDY-PY-WORDS-001 | incident | no em dash in a user-facing Python string |
| TIDY-PY-PRINT-001 | supersession | `logging`, never `print` |
| TIDY-PY-SLEEP-001 | supersession | `asyncio.sleep`, never `time.sleep` |
| TIDY-PY-NOQA-001 | supersession | ruff suppressions stay at their nine named files |
| TIDY-PY-EXCEPT-001 | boundary | broad catches stay at the seven named seams |

Rows for the verification wiring (`TIDY-CI-*`, `TIDY-HOOK-*`) arrive with the CI commit.

## Backlog (a ratchet with more than about twenty violations is a cleanup project first)

| Candidate | Count on 2026-09-23 | Note |
|---|---|---|
| `try?` on the capture path | 28 in `apps/ios/VoCal/Voice` | each is a swallowed error on the path that must not fail silently; review one by one |
| `sleep(` in app code | 46 | mostly `Task.sleep` for timeouts and mock latency; separate the mock from the runtime before ratcheting |
| `datetime.now(` in the API | 12 | an injectable clock would make day boundaries testable without patching |
| Claim words as literals | 8 (`"Saved"`, `"Listening"`, `"Logged"` in `VoiceLogView.swift`) | Phase 4: one address in the pure layer (`VoiceLogState`), then a row banning them elsewhere |

## Bug-pinning tests

A regression test lives beside the code it protects (`Tests/...` for Swift,
`services/api/tests/` for Python). Its name is a plain sentence stating the promise
(`test_identity_never_depends_on_the_amount`, "Every rule is well formed"). The comment
directly above carries the incident: date, how it was reported, the mechanism, the build or
run it came from. The test asserts the invariant the bug broke, never the line that changed,
so it holds after a refactor. A bug-fix commit that adds only product code and tests is
incomplete: it also adds the row that bans the shape, or says in one sentence why no row can.
