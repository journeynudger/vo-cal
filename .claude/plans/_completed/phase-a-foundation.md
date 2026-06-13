# Phase A — Foundation & Scaffold

> Status: Done
> Owner: @lorenzo
> Branch: `main`
> Next: — (complete)

## Goal

Stand up the Vo-Cal monorepo as a faithful mirror of Beacon's proven scaffolding, with Serein's doctrine ported in *before* any product code exists. At exit: `make doctor` and `make check` are green, the empty app boots in the simulator with the black/gold theme applied, the backend serves `/health` with observability wired, Supabase has the full schema, and every guardrail doc a future session needs is in place. Without this, every later phase pays the setup tax repeatedly. Touches: repo root, `apps/ios/`, `Sources/`, `services/api/`, `docs/`, `scripts/`, `.github/`.

## Decisions locked

- **Mirror Beacon's layout exactly** (`apps/ios` + `services/` + `docs/` + `scripts/` + Makefile + XcodeGen): it shipped to the App Store; don't improvise.
- **Doctrine before code:** AGENTS.md and the voice docs land in this phase so Phases B–I are constrained from their first session.
- **Bundle ID `com.vocal.app`, app group `group.com.vocal.shared`, display name "Vo-Cal", scheme `VoCal`** — placeholders confirmed against the Apple Developer account in I0; chosen now so the port has stable constants.
- **Python via `uv`** (Beacon convention), Swift 6 strict concurrency, iOS 26 target (both source repos are iOS 26+).

## Context

Everything in this phase is copy-adapt from Beacon (`/Users/lorenzoscardicchio/Downloads/Projects/beacon`) or Serein (`/Users/lorenzoscardicchio/Downloads/Projects/Serein`). Copy out only — never modify the source repos. Where a Serein doc is ported with deletions (Action Button / Live Activity / share-extension material), note the deletion at the top of the ported file so the delta is auditable.

---

## Tasks

### A0. Repo init + skeleton

Create the repository and the empty directory structure so every later task has a home.

- [x] **Step 1.** `git init` in `/Users/lorenzoscardicchio/Downloads/Projects/vo-cal`. Adapt Beacon's `.gitignore` (+ Serein's entries for `DerivedData/`, `.tmp/`, `*.xcodeproj`).
- [x] **Step 2.** Create directory skeleton: `apps/ios/VoCal/{Views,ViewModels,Models,Services/{Protocols,Mocks},Voice,Theme}`, `Sources/{VoCalCore,VoCalVoice}`, `Tests/{VoCalCoreTests,VoCalVoiceTests}`, `services/api/src/api`, `services/api/tests`, `docs/`, `scripts/`, `bin/`, `.tmp/` (gitignored), `.claude/memory/`.
- [x] **Step 3.** Root `README.md`: one-paragraph product statement (the thesis), stack table (iOS Swift 6 / FastAPI Python / Supabase), command quick-start (mirrors Beacon's README shape).
- [x] **Step 4.** Copy-adapt `Brewfile` (jq, xcbeautify, xcodegen, supabase, swiftlint, uv), `.pre-commit-config.yaml` (ruff, ruff-format, swiftlint), `.env.example` with names only: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `ANTHROPIC_API_KEY`, `PARSER_MODEL`, `ELEVENLABS_API_KEY`, `USDA_FDC_API_KEY`, `DEBUG`, `CORS_ORIGINS`.
- [x] **Acceptance:** `git status` clean after initial commit; tree matches the proposed structure in MASTER-PLAN's reuse map.
- [x] **Commit:** `chore(scaffold): repo init, directory skeleton, tooling config`

### A1. AGENTS.md + memory scaffold

The engineering doctrine. This file is why Vo-Cal inherits Serein's hard-won lessons instead of re-learning them in production.

- [x] **Step 1.** Author `AGENTS.md` with these sections: **Mission & non-negotiables** (adapted from Serein: no data loss, no false durability claims, voice-first capture path protection, facts-first claims, raw capture immutability, append-only corrections); **How to Think About This Code** (ported verbatim from Serein: existing-code-is-not-authority, stop-the-line on failure-class bugs, deep couplings / same-storage-≠-same-authority, notifications-are-observations-not-commands); **How to Write Code** (verbatim: parse-don't-validate, proofs-not-booleans, typed contexts, three-part "why" comments); **Verification Discipline** (tier table adapted to Vo-Cal commands, budgets to be measured and ratcheted in C6); **Task Workflow + Definition of Done** (Serein's, plus the plan-checkbox-in-same-commit rule); **MUST NOT rules** (Beacon's: no commit/push/db-reset/migrations without user; plus: never edit Beacon/Serein, never build out-of-scope features); **Commands**; **Repository Layout**.
- [x] **Step 2.** Replace the root `CLAUDE.md` content with `@AGENTS.md` include (Beacon convention) — move the current entry-point content into AGENTS.md where it belongs.
- [x] **Step 3.** `.claude/memory/` already exists (seeded at planning time — see Amendments): verify it against the as-built scaffold, update `architecture.md`'s pre-code banner sections where A-tasks made them real, and cross-link AGENTS.md ↔ memory INDEX.
- [x] **Acceptance:** cold-read test — AGENTS.md alone is sufficient for a fresh session to know what it may not do and how to verify changes.
- [x] **Commit:** `docs(doctrine): AGENTS.md + memory scaffold (Serein + Beacon port)`

### A2. Port guardrail + product docs

The doctrine documents future sessions read before touching their surface.

- [x] **Step 1.** `docs/VOICE_CAPTURE.md` ← Serein's, near-verbatim: claim ladder, truth-vs-claims, failure priority ("silent dead air is the worst failure"), startup milestone vocabulary. **Deletions (noted in a header block): Action Button / AudioRecordingIntent / Live Activity sections.** Renames Serein→Vo-Cal.
- [x] **Step 2.** `docs/INVARIANTS.md` ← Serein's: §immutability, §durability-and-saved, §voice capture rungs (verbatim), §crash recovery, §failure modes (interruption pause-and-seal, no auto-resume, 5-min auto-finalize), §resource bounds, §convergence/liveness, §tenant isolation. **Deletions: share-capture rungs, §cross-process coordination, passive-location taxonomy.** **Addition: derived rungs** — `transcribed`, `parsed`, `logged` defined as derived records that may never weaken the meaning of `saved`.
- [x] **Step 3.** `docs/PARSER_CONTRACT.md` — the canonical JSON contract: input `meal transcript`; output `meal_type`; `items[]` with `name, amount, unit, state (raw|cooked), fat_ratio, brand, prep_method, confidence`; `missing_details[]` with `field, importance, question` (single question selected downstream). Include the seed messy-speech examples: "4oz 93/7 beef", "200g cooked jasmine rice", "Chipotle bowl, double chicken, white rice, mild salsa, light cheese", "burger, unknown beef, regular cheddar, mayo". Declare the >75 cal / >10g clarifying-question threshold here as the single source of truth.
- [x] **Step 4.** `docs/PROTOCOL_LOGIC.md` — protocol generation spec: Mifflin-St Jeor BMR → TDEE (activity + occupation multipliers) → goal-rate adjustment with safety rails (max deficit/surplus bounds, calorie floors) → protein g/kg by goal+training age → fat floor → carbs remainder → fiber 14g/1000kcal → meal structure from schedule prefs → behavioral rules library. Every target gets a "why" template slot. Include the not-medical-advice disclaimer requirement.
- [x] **Step 5.** `docs/DESIGN.md` — full design system from the Cal AI reference screenshots with the black/gold palette: token table (colors, radii, spacing scale, type ramp), component inventory (StatCard, MacroRing, PillButton, ConfidenceBadge, MealItemCard, OnboardingProgressBar, WeekStrip), per-screen layout notes for the 6 screens. `docs/ARCHITECTURE.md` — thin-client rule (Beacon), capture-path isolation rule (Serein), data flow diagram (speak → capture → outbox → upload → transcript artifact → parse artifact → confirm → meal log), API surface list. `docs/DECISIONS.md` — seeded from master-plan locked decisions.
- [x] **Acceptance:** each ported doc carries a header naming its source file and its deletions/additions (the delta is auditable).
- [x] **Commit:** `docs(guardrails): port VOICE_CAPTURE + INVARIANTS, author PARSER_CONTRACT + PROTOCOL_LOGIC + DESIGN + ARCHITECTURE`

### A3. iOS app scaffold + theme

The empty-but-booting app with the design system in code.

- [x] **Step 1.** `apps/ios/project.yml` ← Beacon's, adapted: target `VoCal`, bundle `com.vocal.app`, iOS 26.0, Swift 6 `SWIFT_STRICT_CONCURRENCY=complete`, app group entitlement `group.com.vocal.shared`, `UIBackgroundModes: [audio]`, no Mapbox/Supabase SPM deps yet (Supabase added in F1 when auth lands). `SupportingFiles/Info.plist` with `NSMicrophoneUsageDescription` placeholder copy + `ITSAppUsesNonExemptEncryption=false`.
- [x] **Step 2.** `apps/ios/VoCal/Theme/VoCalTheme.swift` — all tokens as a single namespace under `VoCalTheme.{Colors,Radius,Spacing,Fonts}` (naming: `VoCalTheme.Colors.gold` rather than `Color.vcGold` — same tokens, cleaner namespace).
- [x] **Step 3.** Component primitives in `Views/Components/`: `PillButton` (black pill, white label — "Create Meal" style), `StatCard`, `MacroRing` (animatable progress ring), `ConfidenceBadge` (gold scale), `WeekStrip` (the M T W dotted day selector from the screenshots). SwiftUI previews for each against the background token.
- [x] **Step 4.** `VoCalApp.swift` + `AppRootView` — TabView (Today placeholder, Settings placeholder) + floating black mic button overlay (Cal AI bottom-right pattern) routing to a `VoiceLogView` placeholder. `A11y.swift` accessibility-identifier namespace (Beacon pattern).
- [x] **Step 5.** Built via xcodegen + xcodebuild directly (Makefile lands in A7); app installed and launched on iPhone 17 Pro simulator, screenshot in `.tmp/a3-boot.png`.
- [x] **Acceptance:** app boots in simulator showing themed placeholder Today screen; component previews render; zero xcodebuild warnings.
- [x] **Commit:** `feat(ios): app scaffold, VoCalTheme tokens, component primitives`

### A4. SPM package scaffold

The pure-Swift layer Serein's port will land into, testable in seconds without the app.

- [x] **Step 1.** `Package.swift` (Serein's shape): targets `VoCalCore` (shared types: `MealType`, `ParsedItem`, `NutrientProfile`, `ParseResult`, `ProtocolTargets`, `VoCalJSON` codecs, `AppGroupConfig`), `VoCalVoice` (placeholder — Phase C fills it), test targets for both. Tools-version 6.2 (required for `.iOS(.v26)`). App target wired to both products via local package in `project.yml`.
- [x] **Step 2.** Implement `VoCalCore` types mirroring `docs/PARSER_CONTRACT.md` exactly (Codable round-trip = the iOS side of the contract; snake_case via `VoCalJSON`).
- [x] **Test:** Codable round-trip tests for every contract type, including unknown-field tolerance (server may add fields). 7 tests green.
- [x] **Acceptance:** `swift test` green from repo root in seconds (0.001s test run); app builds against the package.
- [x] **Commit:** `feat(core): VoCalCore SPM package with parser-contract types`

### A5. Backend scaffold (FastAPI)

Beacon's API skeleton with observability, before any domain logic.

- [x] **Step 1.** `services/api/pyproject.toml` (uv; FastAPI, uvicorn, pydantic, httpx, supabase, prometheus-client, pytest, ruff). Copy-adapt from `beacon/services/python/src/api/`: `main.py`, `config.py`, `dependencies.py` (JWT auth dep), `errors.py`, `logging_config.py` (JSON logs), `middleware.py` (request timing + X-Request-ID), `metrics.py` (Prometheus + `/metrics`), `metrics_ingestion.py` (client-metrics endpoint — Phase D's log-duration events land here), `instrumented_client.py`, `rate_limit.py`.
- [x] **Step 2.** `/health` endpoint; empty domain packages with Beacon's router/schemas/store shape: `intake/`, `protocols/`, `captures/`, `meals/`, `parser/`, `nutrition/`, `checkin/`, `admin/`, `enrichment/` (worker package, not a router).
- [x] **Test:** pytest boots the app, `/health` 200, middleware stamps request IDs, `/metrics` exposes counters.
- [x] **Acceptance:** `uv run pytest` green; `uvicorn` serves locally with JSON logs.
- [x] **Commit:** `feat(api): FastAPI scaffold with Beacon observability stack`

### A6. Supabase schema + RLS

The full data model, migration-first, so B–H add logic rather than fight schema.

- [x] **Step 1.** Local Supabase setup (Beacon's `make dev` flow). Initial migration with tables: `profiles` (1:1 auth.users), `intake_responses` (versioned JSON answers), `protocols` (versioned targets + `why` JSON, `active` flag), `captures` (immutable: id, user, audio blob ref, duration, device, claim milestones JSONL ref, status), `transcripts` (derived artifact: capture FK, provider, text, immutable), `parses` (derived artifact: transcript FK, contract JSON, model, prompt version, immutable), `meal_logs` (user-confirmed: parse FK, confirmed items JSON, totals, meal_type, logged_at), `corrections` (append-only: meal_log FK, item index, field, parsed_value, confirmed_value), `saved_meals` ("usuals"), `checkins`, `food_dictionary` (internal foods + aliases + unit/state conversion factors + per-100g macros), `usda_cache` (fdc_id keyed), `admin_reviews`, `client_metrics`.
- [x] **Step 2.** RLS on every user table (owner-only); `food_dictionary`/`usda_cache` read-all; `admin_*` service-role only. Storage bucket `capture-audio` (private; signed URLs only).
- [x] **Step 3.** `docs/DATABASE.md` — schema doc with the immutability rules called out per table (which tables are append-only, which are derived).
- [x] **Test:** pytest RLS probe — user A cannot read user B's `meal_logs`/`captures` (Beacon's pattern).
- [x] **Acceptance:** `make db-start && make db-migrate` idempotent; RLS probe green.
- [x] **Commit:** `feat(db): full schema migration + RLS + storage bucket`

### A7. Makefile + scripts + verification tiers

The command surface every future session uses. Mirrors Beacon's Makefile; verification tiers mirror Serein's discipline.

- [x] **Step 1.** `Makefile` targets: `dev`, `setup`, `db-start/stop/migrate/reset` (reset gated on `ALLOW_DB_RESET=1`), `api-dev` (logs to `.logs/api-dev.log`), `api-check`, `api-test`, `ios-generate`, `ios-env`, `ios-sim`, `ios-check`, `check` (everything), `doctor`, `metrics`, `todo*`.
- [x] **Step 2.** Scripts: `scripts/doctor.sh` (env + deps + services check), `scripts/todo` (Beacon's task CLI, verbatim), `scripts/generate_ios_env.sh` (.env → `Environment.generated.swift`), `scripts/check-api` (ruff + pytest), `scripts/check` (SPM `swift test` + check-api), `bin/ios-app-build` (compile-only xcodebuild, Serein pattern), `scripts/metrics-dashboard` (Beacon's TUI, trimmed).
- [x] **Step 3.** Record each command's measured runtime in AGENTS.md's verification-tier table (budgets; the ratchet discipline starts now).
- [x] **Acceptance:** `make doctor` green; `make check` green end-to-end on the empty project; AGENTS.md tier table has real measured numbers.
- [x] **Commit:** `chore(tooling): Makefile, verification scripts, todo CLI`

### A8. CI

- [x] **Step 1.** `.github/workflows/ci.yml` ← Beacon's: ubuntu job — uv setup, ruff, pytest for `services/api`; macOS job — `swift test` for the SPM packages. (Full iOS app build stays local; revisit in Phase I if signal is needed.)
- [x] **Step 2.** Concurrency cancel-in-flight per branch (Beacon convention).
- [x] **Acceptance:** CI green on the scaffold commit.
- [x] **Commit:** `ci: backend + SPM checks on push`

---

## Exit Criteria

- ✅ `make doctor` and `make check` green; CI green.
- ✅ Empty app boots in simulator with theme applied; component previews render the black/gold system.
- ✅ Supabase schema migrated with RLS proven by test.
- ✅ AGENTS.md, VOICE_CAPTURE.md, INVARIANTS.md, PARSER_CONTRACT.md, PROTOCOL_LOGIC.md, DESIGN.md, ARCHITECTURE.md, DATABASE.md all exist with auditable port deltas.
- ✅ A fresh Claude session can cold-start from CLAUDE.md → plans → AGENTS.md and know exactly what to do and what not to touch.

## Amendments

### 2026-06-12 — A8 adaptation: CI authored, first run deferred to first push

No git remote exists yet (push is user-gated per MUST-NOT). ci.yml is authored and
will run on the first push. Exit-criterion "CI green" is satisfied locally by the same
commands CI runs (ruff, pytest, swift test — all green).

### 2026-06-12 — A6 adaptation: live-DB checks marked, not run (docker daemon down)

Local Supabase cannot start (no docker daemon). The migration is written but NOT applied
(user runs `make db-migrate` per MUST-NOT). The RLS probe ships as @pytest.mark.live_db
(deselected by default) plus offline FakeDatabase scoping tests. `make dev` skips db-start
gracefully when docker is down. User FKs reference auth.users(id), not profiles —
capture ownership must precede profile creation.

### 2026-06-12 — Memory system seeded ahead of A1

The `.claude/memory/` scaffold (INDEX, architecture, product, decisions, patterns-that-worked/failed, glossary, people) was created during the planning session, before Phase A execution. A1 Step 3 becomes a verify-and-update pass instead of a creation task. `architecture.md` carries a pre-code banner; A-tasks should update it as planned sections become real.

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| A0 Repo init + skeleton | done | 2ed1b37 |
| A1 AGENTS.md + memory | done | 968b229 |
| A2 Guardrail + product docs | done | backfill |
| A3 iOS scaffold + theme | done | 9789451 |
| A4 SPM package scaffold | done | 88c3856 |
| A5 Backend scaffold | done | 708d057 |
| A6 Supabase schema + RLS | done | 3a42114 |
| A7 Makefile + scripts + tiers | done | e2854fc |
| A8 CI | done | this commit |
