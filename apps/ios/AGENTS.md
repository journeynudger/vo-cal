# apps/ios — the SwiftUI client

**READ FIRST for any voice work: `docs/VOICE_CAPTURE.md` + `docs/INVARIANTS.md` (mandatory).**

- The `.xcodeproj` is GENERATED from `project.yml` (XcodeGen) and gitignored — edit
  `project.yml`, then `make ios-generate`. Never hand-edit the project.
- Build check: `bin/ios-app-build` (compile, zero warnings, no simulator). Voice runtime:
  `bin/ios-sim-voice-test` (9 scenarios on the pinned iPhone 17 Pro sim) — required after
  touching the coordinator/outbox/kernel; never use it as a compile check.
- Config per build-config: `VOCAL_API_BASE_URL` (Debug → `http://localhost:8000`,
  Release → prod Fly URL) surfaces through Info.plist into `APIClient`.
- Versioning: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, bumped by
  `.claude/skills/publish/scripts/bump-version.sh`. **TestFlight builds come from Xcode
  Cloud on pushes to `main`** (`ci_scripts/ci_post_clone.sh` regenerates the project and
  copies the committed `ci_scripts/Package.resolved` into place — refresh that file when
  package requirements change). Local `xcodebuild -exportArchive` uploads also work but
  share the same build-number sequence — never reuse a number.
- Decode rule (paid for twice): a Swift response field must be Optional or custom-decoded
  unless the server ALWAYS emits it; server dates carry microseconds (`VoCalJSON` handles).
- UI reads `VoCalTheme` tokens only — no inline hex. Claim-ladder honesty: "Listening"
  needs byte-flow, "Saved" a commit receipt, "Logged" a server row (MUST-NOT #6).
- Sim/UITest paths run on mocks (`RuntimeMode.usesMockServices`): the mock meal service
  plays canned scenarios so every UI state is reachable with no mic/network.
- Simulator logs → unified pipeline log: `scripts/ios-log-stream.sh` (tags `[ios]` into
  `.logs/server.log`). Headless boxes without a booted sim get server tags only.
- IntakeDraft: sex deliberately has NO default (field bug 2026-07 — a silent "female"
  preselection miscomputed male protocols). Don't re-add one.
