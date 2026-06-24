---
name: publish
description: Archive the VoCal iOS app and upload it to App Store Connect for TestFlight. Use when the user wants to ship a TestFlight build, cut a release build, bump the build number and upload, or push VoCal to beta testers. Triggers — publish, release, TestFlight, ship a build, upload to App Store Connect, cut a beta build.
disable-model-invocation: true
---

# Publish VoCal to TestFlight

Archive the VoCal iOS app (Release config) and upload it to App Store Connect so it
processes for TestFlight distribution. This is the Phase I6 runbook.

**Pipeline:** bump build number → regenerate Xcode project → regenerate prod env →
`xcodebuild archive` → `xcodebuild -exportArchive` (export + upload) → wait for
App Store Connect processing → (with user approval) commit the version bump.

VoCal facts this skill is wired to (from `apps/ios/project.yml`):

| Thing | Value |
|---|---|
| Scheme | `VoCal` |
| Archive configuration | `Release` |
| Project file | `apps/ios/VoCal.xcodeproj` (generated from `project.yml`; gitignored) |
| Bundle ID | `com.vocal.app` |
| App group | `group.com.vocal.shared` |
| Marketing version | `0.1.0` (managed in `project.yml`) |
| Build number | `CURRENT_PROJECT_VERSION` in `project.yml` (bumped by this skill) |

> Source of truth: `apps/ios/project.yml`. The `.xcodeproj` is regenerated from it
> via `make ios-generate` — never hand-edit the `.xcodeproj`.

---

## Prerequisites (human-gated — confirm before running)

These cannot be agent-provisioned. The first archive/upload will fail loudly if any
are missing. Confirm each with the user (Phase I0 establishes most of them):

1. **Apple Developer Team ID** — 10-char team identifier (e.g. `ABCDE12345`).
   - Fill it into `.claude/skills/publish/ExportOptions.plist` (`teamID`, currently
     `TODO(lorenzo)`), and set `DEVELOPMENT_TEAM` for the archive (see Phase 3).
   - `project.yml` intentionally leaves `DEVELOPMENT_TEAM` unset (comment at line ~16);
     pass it on the `xcodebuild` command line instead so the repo stays account-agnostic.
2. **Bundle ID registered** — `com.vocal.app` exists in the developer account with the
   **App Groups** capability (the app uses `group.com.vocal.shared`).
3. **App Store Connect app record** — an app named "Vo-Cal" exists for `com.vocal.app`,
   so uploaded builds have somewhere to land.
4. **Distribution signing assets** — an **Apple Distribution** certificate in the login
   keychain + an **App Store** provisioning profile for `com.vocal.app`. Automatic
   signing with `-allowProvisioningUpdates` can create/refresh these if the account has
   permission; otherwise install them manually (or via Xcode → Settings → Accounts).
5. **An upload credential** — pick ONE:
   - **App Store Connect API key** (recommended, non-interactive): `.p8` key file +
     **Key ID** + **Issuer ID**. Used by `xcodebuild`/`altool`/`notarytool` for upload.
   - **App-specific password**: an `@apple.com`/Apple-ID app-specific password
     (appleid.apple.com → Sign-In & Security) for `altool`/Transporter username auth.
   - **Signed-in Xcode account**: `xcodebuild -exportArchive` with `destination=upload`
     uses Xcode's saved Apple ID. Simplest interactively; the API key is better for CI.
6. **Toolchain** — Xcode 26 + command-line tools; `xcodegen`; `xcbeautify` (present at
   `/opt/homebrew/bin/xcbeautify` — if absent, drop the `| xcbeautify` pipe).
7. **Production env wired** — `.env` at repo root carries the **prod** Supabase + API
   URLs. Release builds must point at prod, never `localhost` (Phase I5). Phase 2b below
   regenerates `Environment.generated.swift` from `.env` before archiving.

**Never print secret values** (API keys, app-specific passwords, `.p8` contents). Pass
them via environment variables or file paths; echo only that they are *set*.

---

## Current state

```
!grep -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' apps/ios/project.yml
```

---

## Phase 1: Version strategy

Show the current marketing version and build number from the context above. A TestFlight
upload needs a `(marketing, build)` pair strictly greater than anything already uploaded
for this train — usually that means **build number +1**.

Use **AskUserQuestion**:
- **Question**: "How should we bump the version?"
- **Header**: "Version"
- **Options**:
  1. **"Build number only"** — Increment build by 1, keep marketing version
     (e.g. `0.1.0 (1)` → `0.1.0 (2)`). Default for an iteration on the same release.
  2. **"Set marketing version + build"** — Specify a new marketing version and build
     (e.g. `0.2.0 (1)`). For a new release train.

If "Set marketing version + build", follow up for the exact `X.Y.Z` and build `N`.

## Phase 2: Bump the build number

The first-ever TestFlight build keeps the committed `0.1.0 (1)`; in that case **skip the
bump** and go straight to Phase 2b. Otherwise run the bump script:

```bash
# Build-only bump (build +1, keep marketing version):
.claude/skills/publish/scripts/bump-version.sh

# Explicit values:
.claude/skills/publish/scripts/bump-version.sh --marketing-version X.Y.Z --build-number N
```

The script edits `apps/ios/project.yml` (source of truth) and runs `make ios-generate`
to regenerate `VoCal.xcodeproj`. It refuses to move either value backwards.

Show the change:

```bash
git diff apps/ios/project.yml
```

Confirm with **AskUserQuestion** ("Version change correct? Ready to archive?" →
"Yes, archive" / "No, redo"). On "No, redo": `git checkout apps/ios/project.yml`,
re-run `make ios-generate`, return to Phase 1.

## Phase 2b: Point the build at production

Release builds must talk to the prod backend, not `localhost`. The API base is a
per-config build setting in `apps/ios/project.yml` (surfaced into Info.plist as
`VOCAL_API_BASE_URL`, read by `APIClient`): `Debug` → local, `Release` → prod. Set the
`Release` value to the deployed Fly URL, then regenerate the project:

```bash
# In apps/ios/project.yml, under settings.configs.Release:
#   VOCAL_API_BASE_URL: https://<your-fly-app>.fly.dev   # replace the TODO(lorenzo) placeholder
make ios-generate
```

Sanity-check the Release config is NOT pointing at localhost before archiving:

```bash
xcodebuild -project apps/ios/VoCal.xcodeproj -target VoCal \
  -showBuildSettings -configuration Release 2>/dev/null | grep VOCAL_API_BASE_URL
```

If this prints `127.0.0.1`/`localhost` or the `TODO-lorenzo` placeholder, stop — set the
prod URL in `project.yml` (Phase I5) and re-run before continuing.

## Phase 3: Archive (Release)

Build the signed Release archive. `.build/` is gitignored — safe for artifacts.

```bash
cd apps/ios && xcodebuild archive \
  -project VoCal.xcodeproj \
  -scheme VoCal \
  -configuration Release \
  -archivePath ../../.build/VoCal.xcarchive \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=TODO_LORENZO_TEAM_ID \
  -allowProvisioningUpdates 2>&1 | xcbeautify
```

**Placeholders / notes:**
- `DEVELOPMENT_TEAM=TODO_LORENZO_TEAM_ID` → the real 10-char Team ID. `project.yml` leaves
  this unset on purpose; supplying it on the command line keeps the team out of the repo.
- `-destination 'generic/platform=iOS'` forces a device (not simulator) archive.
- Drop `| xcbeautify` if it is not installed.
- On failure, read the full output and diagnose: missing/expired distribution cert,
  no App Store profile for `com.vocal.app`, Team ID mismatch, or the App Groups
  capability not enabled on the App ID. Fix, then re-archive once.

## Phase 4: Export + upload to App Store Connect

### Primary path — `xcodebuild -exportArchive` (export + upload in one step)

```bash
xcodebuild -exportArchive \
  -archivePath .build/VoCal.xcarchive \
  -exportPath .build/export \
  -exportOptionsPlist .claude/skills/publish/ExportOptions.plist \
  -allowProvisioningUpdates 2>&1 | xcbeautify
```

`ExportOptions.plist` has `destination=upload` + `method=app-store-connect`, so this
exports the `.ipa` **and** uploads it. It uses Xcode's signed-in Apple ID for auth.

To authenticate with an **App Store Connect API key** instead of the signed-in account
(required for CI / non-interactive), add these flags (paths/IDs are inputs, never echo
the `.p8` contents):

```bash
  -authenticationKeyPath "$ASC_API_KEY_PATH" \   # path to AuthKey_<KEYID>.p8
  -authenticationKeyID "$ASC_API_KEY_ID" \       # Key ID
  -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"
```

Confirm the export's `teamID` matches the archive's `DEVELOPMENT_TEAM`, and that
`ExportOptions.plist`'s `teamID` is no longer `TODO(lorenzo)`.

### Alternative upload paths (if you want export-then-upload separated)

Export a signed `.ipa` first — set `ExportOptions.plist` `destination` to `export`
(instead of `upload`), re-run the export command above, then upload the produced `.ipa`
from `.build/export/` with **one** of:

**`xcrun altool`** — app-specific password (username auth):
```bash
xcrun altool --upload-app -f .build/export/VoCal.ipa -t ios \
  -u "$APPLE_ID_EMAIL" -p "@env:ASC_APP_SPECIFIC_PASSWORD"
```
`@env:ASC_APP_SPECIFIC_PASSWORD` reads the secret from the env var — never inline it.

**`xcrun altool`** — App Store Connect API key:
```bash
xcrun altool --upload-app -f .build/export/VoCal.ipa -t ios \
  --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID"
# Requires AuthKey_<KEYID>.p8 in ~/.appstoreconnect/private_keys/ (or ./private_keys/).
```

**`xcrun notarytool` is for notarization, not TestFlight uploads** — do not use it to
ship to App Store Connect; use `altool`, `-exportArchive` with `destination=upload`, or
**Transporter.app** (drag the `.ipa` in, sign in with the Apple ID or API key) as a GUI
fallback.

On failure, diagnose: auth (wrong/expired API key or app-specific password), a duplicate
build number already on App Store Connect (bump again — Phase 1), `ITSAppUsesNonExemptEncryption`
missing from `Info.plist` (Phase I1 sets it `false`), or network/timeout.

## Phase 5: Wait for processing + post-upload steps

Use **AskUserQuestion** to track the manual App Store Connect side:
- **Question**: "Build uploaded. Status in App Store Connect → TestFlight?"
- **Header**: "Processing"
- **Options**:
  1. **"Processed & ready"** — Build finished processing; visible under TestFlight.
  2. **"Still processing"** — Wait a few minutes and re-check (typically 5–15 min).
  3. **"Failed processing"** — App Store Connect flagged an issue.
  4. **"Need the manual steps"** — Print the checklist below.

Manual checklist (for "Need the manual steps"):
1. App Store Connect → **Vo-Cal** → **TestFlight** → **iOS builds**; wait for the build to
   leave "Processing".
2. **Export compliance**: answer the encryption question. The app uses only standard
   HTTPS (`ITSAppUsesNonExemptEncryption=false`), so select "None of the algorithms…" /
   the no-non-exempt-encryption answer.
3. **Internal testing** (Phase I6 Step 2): add the build to the internal tester group so
   Lorenzo can install it and run a real meal log against prod.
4. **External testing** (Phase I6 Step 3): create/assign the **"Concierge Beta"** group,
   fill the beta description + "What to Test" notes, and **submit for Beta App Review**
   (external testers require it). Have the privacy policy URL and review notes
   (`docs/app-store/REVIEW_NOTES.md`) ready.

"Still processing" → wait and re-ask. "Failed processing" → diagnose from any error text.

## Phase 6: Record the version bump

Once the build is processed, the version bump should be recorded. **Do not `git commit`
or `git push` without explicit user approval** (repo AGENTS.md MUST-NOT rules; there is
no remote configured). When the user approves, the Phase I6 commit is:

```bash
git add apps/ios/project.yml
git commit -m "chore(release): publish skill + TestFlight 0.1.0 (1)"
# git push only if a remote exists AND the user explicitly approves.
```

(For a later build-bump iteration, use a message like
`chore(release): bump VoCal to vX.Y.Z (build N) for TestFlight`.)
