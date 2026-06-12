# Phase I — TestFlight Readiness & Publish

> Status: Queued (blocked on E + F + G + H)
> Owner: @lorenzo
> Branch: `phase-i-testflight`
> Next: I0

## Goal

Everything between "it works on Lorenzo's phone" and "a beta tester installs it from TestFlight": Apple account plumbing, privacy disclosures, App-Review-proof account deletion and health posture, icon/launch polish, the design QA pass against the reference screenshots, the ported publish skill, and the actual upload. Exit = build processed in TestFlight, installable by external testers, with beta-gate instrumentation verified live from a TestFlight build. Touches: `apps/ios/` config + assets, `docs/app-store/`, `.claude/skills/publish/`, `services/web/` (minimal privacy/support pages), backend deploy.

## Decisions locked

- **External-tester track** (concierge users aren't App Store Connect team members), which means **Beta App Review** — so privacy policy URL, beta description, and review-proof flows are required, not optional.
- **Minimal static privacy + support pages** (Beacon's `services/web` privacy/support pages, trimmed and re-themed) — required by Beta App Review; not a marketing site (no scope creep).
- **Backend deploys to Fly.io** (Beacon's deployment shape + CI deploy job, gated on `AUTO_DEPLOY_ENABLED`); Supabase hosted project for prod. TestFlight builds point at prod URLs via the generated-env scheme — never at localhost.
- **Health posture:** age rating questionnaire Medical/Treatment = "Infrequent/Mild"; "not medical advice" disclaimer in onboarding AND protocol screen; protocol engine rails (F3) are the substantive answer to extreme-diet concerns. No HealthKit (no entitlement, simpler privacy form).
- **No push notifications, no analytics SDKs.** Privacy form stays small: data collected = phone number (auth), health & fitness inputs (intake, weight, meals), audio (voice recordings), usage data (first-party metrics). All linked to identity, none used for tracking; no third-party ad/tracking SDKs exist in the binary.

## Context

Runs last. Drafting privacy copy earlier is fine, but the phase executes when E–H are done. Apple setup specifics (team ID, final bundle ID) get confirmed in I0 — everything since A3 has used `com.vocal.app`; if the registered ID differs, I0 includes the rename sweep.

---

## Tasks

### I0. Apple account + App Store Connect setup

- [ ] **Step 1.** Confirm Apple Developer team; register bundle ID `com.vocal.app` (capabilities: App Groups) — if a different ID is required, sweep `project.yml`/entitlements/app-group string and update AGENTS.md constants.
- [ ] **Step 2.** App Store Connect app record: name "Vo-Cal" (fallbacks ready if taken), primary category Health & Fitness, age rating questionnaire (Medical/Treatment Infrequent/Mild → expected 12+).
- [ ] **Step 3.** Signing: automatic signing with the team for dev; App Store distribution profile for archive. Document certificate/profile state in `docs/app-store/SIGNING.md`.
- [ ] **Acceptance:** `xcodebuild archive` signs successfully against the registered identifiers.
- [ ] **Commit:** `chore(release): Apple identifiers, ASC app record, signing notes`

### I1. Privacy disclosures

- [ ] **Step 1.** `Info.plist` final copy: `NSMicrophoneUsageDescription` ("Vo-Cal records your voice only while you log a meal, to turn what you say into your food log.") — the only sensitive-permission string in the app; verify `ITSAppUsesNonExemptEncryption=false` present (standard HTTPS exemption).
- [ ] **Step 2.** `PrivacyInfo.xcprivacy`: collected data types (Health & Fitness, Audio Data, Phone Number, Usage Data; linked-to-user = true, tracking = false), required-reason API declarations (UserDefaults, file timestamps — audit actual usage with a grep pass).
- [ ] **Step 3.** `docs/app-store/APP_PRIVACY.md` — the App Privacy form answers, kept in lockstep with the xcprivacy file and the actual code (Beacon's discipline: the three must match).
- [ ] **Step 4.** Privacy policy + support pages: trim Beacon's `services/web` to two static pages + contact; deploy; URLs into the ASC record. Policy covers: what's recorded (voice during logging only), where it lives (Supabase/storage, audio retained as ground truth), admin review access during beta (disclosed!), deletion rights.
- [ ] **Acceptance:** xcprivacy validates in Xcode; policy URL live; form answers, xcprivacy, and code agree.
- [ ] **Commit:** `feat(release): privacy disclosures (xcprivacy, policy pages, ASC form)`

### I2. Account deletion + data rights

App Review 5.1.1(v): account creation ⇒ in-app account deletion. Beacon shipped this; same bar here.

- [ ] **Step 1.** Settings screen: real version — profile basics, view protocol, sign out, **Delete account** (confirmation flow → `DELETE /account`).
- [ ] **Step 2.** Backend: `DELETE /account` — deletes auth user; cascades profiles/intake/protocols/meal_logs/corrections/checkins/metrics; tombstones + GC job for capture audio blobs (storage delete verified); admin_reviews rows anonymized (audit trail survives without identity).
- [ ] **Test:** pytest: post-deletion, zero rows readable for the user; blobs gone after GC; re-signup with same phone gets a clean slate.
- [ ] **Acceptance:** delete in-app → all user data verifiably gone; flow screenshot-ready for review notes.
- [ ] **Commit:** `feat(account): in-app account deletion with full data cascade`

### I3. Health posture + content review

- [ ] **Step 1.** Disclaimer copy ("Vo-Cal provides nutrition information for educational purposes and is not medical advice…") placed in intake step ① footer and protocol screen footer (F5 slot).
- [ ] **Step 2.** Copy sweep of intake/protocol/check-in for eating-disorder sensitivity: rate language stays within rail bounds, no "burn", no punitive framing; verify the F3 rails make extreme targets unreachable through any input combination (test exists from F3 — re-run and reference).
- [ ] **Acceptance:** sweep documented in `docs/app-store/REVIEW_NOTES.md` with the reviewer-facing explanation of voice logging + admin beta review.
- [ ] **Commit:** `docs(release): health disclaimers + review notes`

### I4. App identity + hardening pass

- [ ] **Step 1.** App icon (black/gold, mic motif) full asset set + launch screen (vcBackground + wordmark); display name "Vo-Cal"; version `0.1.0`, build auto-increment via publish skill.
- [ ] **Step 2.** Accessibility pass on the core flow: VoiceOver labels for mic button/states/result cards (a voice-first app that fails VoiceOver users is embarrassing), Dynamic Type sanity at XL on the 6 screens, 44pt touch targets.
- [ ] **Step 3.** Device matrix smoke: smallest supported iPhone + largest, light mode only (P0 declares no dark mode — lock `UIUserInterfaceStyle Light` in Info.plist rather than ship a broken dark variant).
- [ ] **Acceptance:** zero clipped layouts on the matrix; VoiceOver completes a full log; icon/launch render correctly.
- [ ] **Commit:** `feat(ios): app icon, launch screen, accessibility hardening`

### I5. Backend production deploy

- [ ] **Step 1.** Fly.io app for `services/api` (+ worker process group for enrichment); hosted Supabase project; migrations applied (user runs `make db-migrate` — MUST NOT rule); secrets set (Anthropic, ElevenLabs, USDA, Supabase service role); CORS locked to prod origins.
- [ ] **Step 2.** CI deploy job (Beacon's, gated `AUTO_DEPLOY_ENABLED`); `/metrics` scrape confirmed; smoke script `scripts/smoke-prod` (health, auth'd parse round-trip, signed storage write).
- [ ] **Step 3.** iOS release config points at prod via `scripts/generate_ios_env.sh` scheme split (Debug→local, Release→prod).
- [ ] **Acceptance:** TestFlight-config build on a real device completes a full voice log against prod; smoke script green.
- [ ] **Commit:** `feat(release): production backend deploy + env split`

### I6. Publish skill + first TestFlight build

- [ ] **Step 1.** Port Beacon's `.claude/skills/publish/` (SKILL.md, ExportOptions.plist, bump-version.sh) adapted to the VoCal scheme: bump → archive → export → upload to App Store Connect → wait for processing.
- [ ] **Step 2.** Run it: build 0.1.0 (1) uploaded, processing complete, internal tester (Lorenzo) installs from TestFlight and completes a real meal log against prod.
- [ ] **Step 3.** External tester group "Concierge Beta"; beta description + "What to Test" template (first build: complete onboarding, log 3 meals by voice, note any state that felt like a lie); submit for Beta App Review.
- [ ] **Acceptance:** Beta App Review approved; external invite link live.
- [ ] **Commit:** `chore(release): publish skill + TestFlight 0.1.0 (1)`

### I7. Final QA + beta ops

- [ ] **Step 1.** Full regression from the TestFlight build: `bin/ios-sim-voice-test` 9/9, `scripts/parser-eval` no SCORES regression, `make check` green, manual run of all six screens against `docs/DESIGN.md` and the reference screenshots (use the design audit/polish skills for the sweep).
- [ ] **Step 2.** Verify beta-gate instrumentation live from TestFlight: a TestFlight-build log produces `client_metrics` rows in prod; `scripts/beta-metrics` reads them; admin panel shows the log.
- [ ] **Step 3.** `docs/BETA_OPS.md` — concierge runbook: onboarding script for the 5–10 testers, weekly cadence (run beta-metrics, admin review session, dictionary gap triage), feedback channel, willingness-to-pay conversation guide ($15–25/mo users, $50–100/mo coach).
- [ ] **Acceptance:** a stranger-proof path exists: invite link → onboarded tester → logged meal → visible in admin panel and metrics, all without Lorenzo touching a server.
- [ ] **Commit:** `docs(release): final QA record + concierge beta runbook`

---

## Exit Criteria

- ✅ Build processed in TestFlight; Beta App Review approved; external invite link live.
- ✅ Privacy disclosures (xcprivacy ↔ ASC form ↔ code ↔ policy pages) all agree; account deletion verifiably complete.
- ✅ TestFlight build completes real voice logs against prod; all beta-gate metrics flow from it.
- ✅ Full regression green (voice self-test, parser corpus, make check, design sweep).
- ✅ Concierge beta runbook ready — the 30-day clock can start.

## Amendments

*(none yet)*

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| I0 Apple + ASC setup | not started | — |
| I1 Privacy disclosures | not started | — |
| I2 Account deletion | not started | — |
| I3 Health posture | not started | — |
| I4 Identity + hardening | not started | — |
| I5 Prod deploy | not started | — |
| I6 Publish + first build | not started | — |
| I7 Final QA + beta ops | not started | — |
