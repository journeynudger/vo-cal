# TestFlight Runbook — Vo-Cal

The ordered, human-gated steps to take Vo-Cal from "works on Lorenzo's phone" to "an external
tester installs it from TestFlight." This is **only the steps a human must do** — account
plumbing, hosting, secrets, and the manual ASC actions. The code (privacy disclosures, account
deletion, disclaimers, rails, env split, publish skill) is built in Phase I tasks I1–I6; this
file is the checklist for the things an agent **cannot** and **must not** do for you.

Hard rules this runbook respects (`AGENTS.md`):
- **You** run `make db-migrate` — agents never run migrations or reset the DB.
- **You** approve any `git push`.
- Secrets are set by you; never printed.

Do the steps in order. Each one says **what to do** and **what success looks like**. Values
that require a real input from you are marked **TODO(lorenzo)**.

---

## Step 1 — Apple Developer team + register the bundle ID

**Do:**
1. Confirm the **Apple Developer Program** membership is active. Note the **Team ID** (10
   chars). TODO(lorenzo): record it — it's needed in Step 3.
2. In *Certificates, Identifiers & Profiles → Identifiers*, register an App ID for
   **`com.vocal.app`**.
3. Enable the **App Groups** capability on that App ID and create/assign the group
   **`group.com.vocal.shared`** (matches `apps/ios/SupportingFiles/VoCal.entitlements`).
4. If the registered bundle ID must differ from `com.vocal.app`, stop and run the I0 rename
   sweep first (`project.yml`, entitlements, App Group, the `com.vocal.app.selftest` URL type,
   `AGENTS.md` Identifiers block).

**Success:** App ID `com.vocal.app` exists with App Groups enabled and
`group.com.vocal.shared` assigned. Team ID recorded.

---

## Step 2 — App Store Connect app record + age rating

**Do:**
1. In **App Store Connect → Apps → +**, create a new app:
   - **Name:** "Vo-Cal" (TODO(lorenzo): have fallbacks ready if the name is taken).
   - **Primary language:** English (U.S.).
   - **Bundle ID:** `com.vocal.app` (the one from Step 1).
   - **SKU:** TODO(lorenzo) (any stable internal string, e.g. `vocal-ios`).
   - **Primary category:** Health & Fitness.
2. Complete the **age-rating questionnaire**. Answer **Medical/Treatment Information** =
   **"Infrequent/Mild"** (the rationale — rule-bounded, non-clinical nutrition targets — is in
   `docs/app-store/REVIEW_NOTES.md`). Expected result: **12+**.

**Success:** A Vo-Cal app record exists under your team, category Health & Fitness, with the
age rating set (expected 12+). The record can now receive a build.

---

## Step 3 — Signing: certs/profiles + set `DEVELOPMENT_TEAM`

**Do:** (full detail in `docs/app-store/SIGNING.md`)
1. Sign the archiving Mac into the team's Apple ID: **Xcode → Settings → Accounts**.
2. Set the team in `apps/ios/project.yml` under `settings.base` and regenerate:
   ```yaml
   DEVELOPMENT_TEAM: "ABCDE12345"   # TODO(lorenzo): real Team ID from Step 1
   ```
   ```bash
   make ios-generate
   ```
3. Set the matching `teamID` in the publish skill's `ExportOptions.plist` (created in I6) to
   the same Team ID. TODO(lorenzo).
4. Verify a Release archive signs (automatic signing creates the Distribution cert + App Store
   profile on first run):
   ```bash
   # from apps/ios
   xcodebuild archive -project VoCal.xcodeproj -scheme VoCal -configuration Release \
     -archivePath ../../.build/VoCal.xcarchive -allowProvisioningUpdates 2>&1 | xcbeautify
   ```

**Success:** `** ARCHIVE SUCCEEDED **`, and the embedded profile is an App Store profile for
`com.vocal.app` under your team (`get-task-allow = false`). Verification command in
`SIGNING.md`.

---

## Step 4 — Host privacy + support pages, put URLs in ASC

**Do:**
1. Deploy the two static pages `services/web/privacy.html` and `services/web/support.html` to a
   public host (any static host — same Fly app, GitHub Pages, Netlify; this is a single
   decision, TODO(lorenzo) pick the host).
2. Confirm both load over HTTPS and the cross-links work.
3. Put the URLs into App Store Connect:
   - **App Privacy → Privacy Policy URL:** `https://<host>/privacy.html`
   - **TestFlight → Test Information → Support / Marketing URL** (and the App Information
     support URL): `https://<host>/support.html`
4. TODO(lorenzo): update the `<host>` placeholder in `docs/app-store/APP_PRIVACY.md` once live.
5. TODO(lorenzo): confirm the contact addresses in the pages (`privacy@vo-cal.app`,
   `support@vo-cal.app`) are real, monitored inboxes — Beta App Review may email them.

**Success:** Both pages are live over HTTPS; the Privacy Policy URL is saved in the App Privacy
section; the support URL is in TestFlight Test Information.

---

## Step 5 — Hosted Supabase project + run migrations

**Do:**
1. Create a hosted **Supabase** project for production. Record the project URL, the
   **anon/publishable** key (safe to ship), and the **service-role** key (server-only secret —
   never shipped, never logged).
2. Point your `.env` (or a prod env file) at the hosted project, then run the migrations
   **yourself** (agents must not):
   ```bash
   make db-migrate
   ```
3. Create the capture-audio Storage bucket if migrations don't (the per-user `"{user_id}/"`
   prefix layout that account deletion relies on).

**Success:** `make db-migrate` reports the schema applied with no pending migrations against the
hosted project; the capture-audio bucket exists.

> TODO(lorenzo): the iOS project currently ships a Supabase URL + anon key in
> `apps/ios/project.yml` (`VOCAL_SUPABASE_URL` / `VOCAL_SUPABASE_ANON_KEY`). Confirm whether
> that points at the **production** project or a dev one; the Release build must use the prod
> values (Step 7).

---

## Step 6 — `fly launch` + secrets + deploy the API

**Do:** (mirrors Beacon's Fly shape: Dockerfile build, `/health` check, `:8080`)
1. From `services/api`, `fly launch` (or `fly apps create`) to create the app. TODO(lorenzo):
   choose the app name + primary region. Use the existing `services/api/Dockerfile`; the I5
   `fly.toml` (created in that task) sets `internal_port = 8080`, `force_https`, a `/health`
   check, and the worker process group for enrichment.
2. Set production secrets (values are TODO(lorenzo); **do not** paste them anywhere logged):
   ```bash
   fly secrets set \
     ANTHROPIC_API_KEY=... \
     ELEVENLABS_API_KEY=... \
     USDA_FDC_API_KEY=... \
     SUPABASE_URL=... \
     SUPABASE_ANON_KEY=... \
     SUPABASE_SERVICE_ROLE_KEY=...
   ```
3. Lock **CORS** to the production origins (the privacy/support host and any admin origin) —
   `cors_origins` in `services/api/src/api/config.py` defaults to `http://localhost:3000` for
   dev; production must not ship that.
4. Deploy: `fly deploy`.
5. Run the prod smoke script (`scripts/smoke-prod`, created in I5): health, an authenticated
   parse round-trip, and a signed Storage write.

**Success:** `fly deploy` succeeds; `https://<api-host>/health` returns OK; `/metrics` is
scrapeable; `scripts/smoke-prod` is green. Record the API base URL for Step 7.

---

## Step 7 — Point the Release build at production

**Do:**
1. Set the Release API base to the deployed Fly URL. The split is a per-config build setting
   in `apps/ios/project.yml` (`settings.configs.Release.VOCAL_API_BASE_URL`, surfaced into
   Info.plist as `VOCAL_API_BASE_URL`, read by `APIClient`): `Debug` → `http://localhost:8000`,
   `Release` → prod. Replace the `https://TODO-lorenzo-vocal-api.fly.dev` placeholder with the
   real host from Step 6, then `make ios-generate`. Verify:
   ```bash
   xcodebuild -project apps/ios/VoCal.xcodeproj -target VoCal \
     -showBuildSettings -configuration Release 2>/dev/null | grep VOCAL_API_BASE_URL
   ```
   (`VOCAL_SUPABASE_URL` / `VOCAL_SUPABASE_ANON_KEY` are shared in `settings.base` and already
   point at the hosted project — confirm they match the prod Supabase from Step 5.)
2. Build the **VoCal-Live** scheme (or a Release build) on a real device and complete a full
   voice log against prod end-to-end.

**Success:** A Release-config build on a physical device completes a real voice log against the
production API + Supabase (a `meal_logs` row appears for the test account).

---

## Step 8 — Run the publish skill (archive → upload → process)

**Do:** (the ported publish skill lands in I6 at `.claude/skills/publish/`)
1. Run the publish skill. It bumps the version (build 0.1.0 (1) for the first build), archives
   the Release config, exports with `ExportOptions.plist`, and uploads to App Store Connect.
2. In App Store Connect, wait for the build to finish **processing** (~5–15 min).
3. Provide **export compliance**: select "None of the algorithms mentioned above" — Vo-Cal
   uses only standard HTTPS (`ITSAppUsesNonExemptEncryption = false` is already in
   `Info.plist`).
4. Install via TestFlight as the internal tester (Lorenzo) and complete a real meal log against
   prod.

**Success:** Build 0.1.0 (1) shows **Ready to Submit** / processed in TestFlight; the internal
tester installs it and logs a meal against prod.

---

## Step 9 — Submit for Beta App Review (external testers)

**Do:**
1. Create the external tester group **"Concierge Beta"**.
2. Fill **Test Information**: the **Beta App Description**, the **"What to Test"** template, the
   support URL (Step 4), and the **App Review notes** — paste from
   `docs/app-store/REVIEW_NOTES.md` (voice scope, not-medical-advice, the F3 rails, the disclosed
   admin beta review, account-deletion location, and the anonymous demo-account note).
3. Attach build 0.1.0 (1) to the group and **submit for Beta App Review**.

**Success:** Beta App Review is **approved**; the external (public or email) invite link is
live; a stranger can install via the link, onboard, and log a meal — all without you touching a
server.

---

## Quick reference — what's human-gated vs. automated

| Human-gated (this runbook) | Automated / agent-built (I1–I6) |
|---|---|
| Apple team, App ID, App Groups | `PrivacyInfo.xcprivacy`, disclaimers, account-deletion code |
| ASC app record + age rating | The deletion endpoint + tests, the F3 rails + tests |
| Distribution cert/profile, `DEVELOPMENT_TEAM` | `project.yml` signing style, env split scripts |
| Hosting the privacy/support pages | The page content (`services/web/*.html`) |
| `make db-migrate` on hosted Supabase | Migrations themselves |
| `fly launch`, `fly secrets set`, `fly deploy` | `Dockerfile`, `fly.toml`, smoke script |
| Export-compliance answer, submit for review | The publish skill (`.claude/skills/publish/`) |
