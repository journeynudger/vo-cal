# Code Signing — Vo-Cal

How Vo-Cal is signed for the two situations that matter in Phase I: **everyday
development** (compile, run on a device/simulator) and **App Store distribution**
(`xcodebuild archive` → upload to App Store Connect for TestFlight). The posture is
deliberately boring — automatic signing, Xcode-managed profiles, one team — so there is
nothing to rotate, share, or check into git.

> The `.xcodeproj` is generated from `apps/ios/project.yml` and is gitignored. All signing
> settings live in `project.yml` and flow into the project via `make ios-generate`. Never
> edit signing in Xcode's UI and expect it to stick — it will be overwritten on the next
> generate. Change `project.yml`, then regenerate.

---

## Posture

| Situation | Signing style | Profile | Cert |
|---|---|---|---|
| Dev (run on device/sim) | Automatic (`CODE_SIGN_STYLE: Automatic`) | Xcode-managed *Development* profile for `com.vocal.app` | Apple Development (per-Mac, Xcode-created) |
| Archive (TestFlight/App Store) | Automatic, via `-allowProvisioningUpdates` | Xcode-managed *App Store* distribution profile for `com.vocal.app` | Apple Distribution (account-wide, Xcode-created) |

Both rely on Xcode's "automatically manage signing." With `-allowProvisioningUpdates` on the
archive command, Xcode creates/refreshes the distribution profile and the Apple Distribution
certificate on demand — no manual `.mobileprovision` or `.p12` juggling. This mirrors Beacon's
shipped posture (its `ExportOptions.plist` uses `signingStyle: automatic`).

Why automatic and not manual: a single solo developer shipping to TestFlight gains nothing
from manual profile management and loses time to expiry/renewal churn. If the project later
grows to CI-on-a-fresh-runner archiving (no Xcode-saved credentials), revisit manual signing
with an App Store Connect API key — see *Future: CI signing* below.

---

## What the user must create in the Apple Developer account

These are account-level objects Xcode cannot fully conjure without a real, enrolled team. Do
these once in Phase I0 (see `TESTFLIGHT_RUNBOOK.md` steps 1 and 3). Items needing a
real value are marked TODO(lorenzo).

1. **Apple Developer Program membership** — paid, enrolled. Note the **Team ID** (10-char,
   e.g. Beacon's was `Z3XZ94WPLT`). TODO(lorenzo): record the Vo-Cal Team ID.
2. **App ID / Bundle ID** `com.vocal.app` registered in *Certificates, Identifiers & Profiles
   → Identifiers*, with the **App Groups** capability enabled and the group
   `group.com.vocal.shared` created and assigned. (The app and any future extension share the
   capture outbox via this group; the entitlement is already declared in
   `apps/ios/SupportingFiles/VoCal.entitlements`.)
3. **Apple Distribution certificate** — created automatically by Xcode the first time you
   archive with automatic signing, or manually in the portal. Lives in the login keychain on
   the archiving Mac. There is nothing to commit.
4. **Profiles** — none to create by hand. Automatic signing manages both the Development and
   App Store profiles for `com.vocal.app` once the App ID and capability exist.

> If the registered bundle ID ends up differing from `com.vocal.app`, that is an I0 rename
> sweep across `project.yml`, the entitlements file, the App Group string, the `Info.plist`
> URL type (`com.vocal.app.selftest`), and `AGENTS.md`'s Identifiers block — not a
> signing-only change.

---

## How `DEVELOPMENT_TEAM` gets set

`DEVELOPMENT_TEAM` is **intentionally unset** in `apps/ios/project.yml` today — there is a
comment marking the seam:

```yaml
# apps/ios/project.yml → settings.base
# DEVELOPMENT_TEAM intentionally unset until Phase I0 confirms the Apple account.
```

In I0, after the Team ID is known, add it under `settings.base` (project-wide, so every
target and config inherits it) and regenerate:

```yaml
settings:
  base:
    SWIFT_VERSION: "6.2"
    # ...
    DEVELOPMENT_TEAM: "ABCDE12345"   # TODO(lorenzo): real 10-char Apple Team ID
```

```bash
make ios-generate   # writes the team into the regenerated VoCal.xcodeproj
```

`CODE_SIGN_STYLE: Automatic` is already present on the `VoCal` target, so once the team is set
Xcode has everything it needs to resolve both the Development and Distribution profiles.

> Keep the Team ID in `project.yml` (it is not a secret — it appears in every shipped binary's
> embedded profile). Runtime config (the `VOCAL_API_BASE_URL` / `VOCAL_SUPABASE_*` keys) also
> lives in `project.yml` as per-config build settings, surfaced into Info.plist by
> `make ios-generate` — not in `.env` and not in a generated Swift file.

The publish skill's `ExportOptions.plist` also carries a `teamID` value — it must match the
`DEVELOPMENT_TEAM` set here. See `TESTFLIGHT_RUNBOOK.md` step 3.

---

## Verifying `xcodebuild archive` signs

Acceptance for I0: a Release archive signs successfully against the registered identifiers.
After `DEVELOPMENT_TEAM` is set and `make ios-generate` has run, with the Mac signed into the
Apple ID for the team in Xcode (Settings → Accounts):

```bash
# from apps/ios
xcodebuild archive \
  -project VoCal.xcodeproj \
  -scheme VoCal \
  -configuration Release \
  -archivePath ../../.build/VoCal.xcarchive \
  -allowProvisioningUpdates 2>&1 | xcbeautify
```

Notes:
- `.build/` is gitignored — safe for the archive artifact.
- If `xcbeautify` is not installed, drop the pipe.
- The `VoCal` scheme's `archive` action is already pinned to the `Release` config in
  `project.yml`, which is what TestFlight builds against (Debug/UITest use the mock path).

**Success looks like:**
- `** ARCHIVE SUCCEEDED **`.
- A `.build/VoCal.xcarchive` exists.
- The archive's embedded profile is an **App Store** profile for `com.vocal.app` under the
  expected team. Confirm:

```bash
# Shows the embedded provisioning profile from the produced archive.
security cms -D -i \
  ".build/VoCal.xcarchive/Products/Applications/VoCal.app/embedded.mobileprovision" \
  | plutil -p - | grep -E 'Name|TeamIdentifier|application-identifier|get-task-allow'
```

You want: a distribution profile (`get-task-allow = false`), the `application-identifier`
ending in `com.vocal.app`, and your Team ID in `TeamIdentifier`. `get-task-allow = false` is
the signal it is a distribution (not development) signing — required for App Store upload.

**Common failures and what they mean:**
- *"No profiles for 'com.vocal.app' were found"* — the App ID isn't registered yet, or
  `DEVELOPMENT_TEAM` is wrong/unset. Do I0 step 1, set the team, regenerate.
- *"Provisioning profile doesn't include the App Groups entitlement"* — the App Groups
  capability wasn't added to the App ID, or `group.com.vocal.shared` wasn't created. Add it in
  the portal; automatic signing will regenerate the profile on the next archive.
- *Cert/keychain prompts* — the Mac isn't signed into the team's Apple ID in Xcode, or the
  Distribution cert isn't in the login keychain. Sign in (Xcode → Settings → Accounts →
  Download Manual Profiles is not needed for automatic).

---

## Future: CI signing (out of scope for I0)

If archiving moves to CI (a runner with no Xcode-saved Apple ID), automatic signing with
`-allowProvisioningUpdates` won't have credentials to authenticate. The migration at that
point: create an **App Store Connect API key** (Issuer ID + Key ID + `.p8`), store it as CI
secrets, and pass it to `xcodebuild -authenticationKeyPath/-authenticationKeyID/
-authenticationKeyIssuerID`, plus import a Distribution cert + profile into a temporary
keychain (or use `match`/`fastlane`). Not needed while Lorenzo archives locally from his Mac.
