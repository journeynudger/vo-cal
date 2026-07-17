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
  `.claude/skills/publish/scripts/bump-version.sh`. **`project.yml` is the single
  authoritative build number.**
- **TestFlight has ONE delivery lane: the `.claude/skills/publish` skill** (`bump-version.sh`
  → `xcodebuild archive` → `-exportArchive destination=upload`). Decision 2026-07-16: Xcode
  Cloud delivery is RETIRED (disabled in App Store Connect) and the manual **Xcode GUI**
  (Product ▸ Archive ▸ Distribute), `altool`, and Transporter upload paths are FORBIDDEN for
  this app — they bypass `bump-version.sh` and ship a stale/duplicate build number. Root
  cause of the old collisions: two automated lanes + a GUI path all read the same mutable
  `project.yml` number and delivered to one train. An out-of-band GUI upload of build 14
  collided with Xcode Cloud and forced a skip to 15 (commit `25f0739`) — that is why there
  is now exactly one lane and one upload command.
- The bump commit **MUST land on `main` as part of shipping**: a build uploaded from a
  `project.yml` that never reached `main` leaves the next ship recomputing the same number →
  App Store Connect rejects the duplicate. `bump-version.sh` refuses to move backwards, but
  it compares only against `project.yml`, never App Store Connect — so a stale / reverted /
  branch-local `project.yml` is the one remaining way to collide. Keep it current on `main`.
  (`ci_scripts/ci_post_clone.sh` + `ci_scripts/Package.resolved` are kept only so Xcode Cloud
  could be re-enabled deliberately; they are inert while the ASC workflow is off. If you ever
  re-enable it, retire the local lane in the same change — never run both.)
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
