# Vo-Cal — Runbook (operate it, ship it, use it)

Plain-English answers to: where does this live, is it isolated, how do I run it, how
do I give it its own repo, how do I set up the database like Beacon, and how do I get
it onto my phone via TestFlight.

---

## 1. Where it lives + isolation (the "no contamination" answer)

- **Path:** `/Users/lorenzoscardicchio/Downloads/Projects/vo-cal`
- **It is its own git repo.** `git init` ran here on day one. `Projects/` itself is *not* a
  git repo, so vo-cal is **not nested inside** any other repo — it is a sibling of
  `beacon/` and `Serein/`, not a child.
- **Zero coupling to Beacon/Serein.** The Serein voice layer and Beacon scaffold were
  **copied and renamed** into vo-cal, not referenced. No `Package.swift`, `project.yml`,
  `pyproject.toml`, Swift, or Python file points at `../beacon` or `../Serein`. The only
  mentions are comments documenting where a pattern came from. Deleting beacon/Serein
  tomorrow would not affect vo-cal at all.
- **Conclusion:** it is already its own environment. The two things it still needs to be
  a "real" standalone project are a **GitHub remote** (§3) and, optionally, a tidier
  home than `Downloads/` (§3, optional).

### Layout
```
vo-cal/
  AGENTS.md / CLAUDE.md        # engineering doctrine (read-first for any agent)
  RUNBOOK.md                   # this file
  Package.swift                # SPM: VoCalCore, VoCalCapture, VoCalVoice
  Sources/ Tests/              # the Swift packages + their tests
  apps/ios/                    # the iOS app (XcodeGen: project.yml → VoCal.xcodeproj)
  services/api/                # FastAPI backend (uv) — parser, protocol, today, nudging, admin
  supabase/migrations/         # the database schema (same shape as Beacon's Supabase)
  scripts/ bin/                # check / parser-eval / beta-metrics / review / ios builds
  docs/                        # PRODUCT_BRIEF, PARSER_CONTRACT, PROTOCOL_LOGIC, DESIGN, …
  .claude/plans/ .claude/memory/  # the master plan + frozen decisions
```

---

## 2. Run it locally (works today)

```bash
make setup            # brew bundle + uv sync (one time)
make doctor           # environment check

# Backend (FastAPI) — runs offline against an in-memory fake DB if no Supabase env
make api-dev          # serves on :8000  (try GET /health)
scripts/check-api     # ruff + ~260 tests, fully offline

# iOS app on the simulator
make ios-sim          # XcodeGen + build + boot iPhone 17 Pro + install + launch
bin/ios-app-build     # compile-only, zero-warning gate
bin/ios-sim-voice-test # the 9 voice scenarios (golden path, interruption, recovery, …)

# SPM + parser quality
swift test            # 19 tests
scripts/parser-eval   # the binding corpus score (canonical-four must stay 100%)
```

Today the simulator shows the themed shell + the working voice-capture plumbing (record/
stop, crash recovery, 9/9 self-test). The full meal-logging *screens* (voice-log UI,
Today, onboarding, Progress) are the **next build** (Phase D/E/F, now unblocked by the
native decision). The clickable spec for those screens is the hosted prototype.

---

## 3. Give it its own GitHub repo (recommended)

It's local-only right now. To put it under version control online (and unlock CI +
TestFlight automation), from inside `vo-cal/`:

```bash
# one-time, needs the gh CLI authed to your account/org
gh repo create vo-cal --private --source=. --remote=origin --push
# or, if you made the empty repo in the GitHub UI first:
git remote add origin git@github.com:<you-or-org>/vo-cal.git
git push -u origin main
```

That's it — 22 commits of clean history push up, CI (`.github/workflows/ci.yml`) runs on
the first push. **I won't push for you** (commits/pushes are gated on your say-so).

**Optional — move it out of `Downloads/`:** purely cosmetic; isolation doesn't depend on
it. If you want a tidier home: `mv ~/Downloads/Projects/vo-cal ~/Projects/vo-cal` then
reopen there. Nothing inside uses an absolute path, so it just works.

---

## 4. Database — same setup as Beacon (Supabase)

Vo-Cal already mirrors Beacon's DB approach: **Supabase (Postgres + RLS)**, schema in
`supabase/migrations/`, applied with the Supabase CLI. The full schema is written but
**not yet applied anywhere** (no project created yet). To stand it up:

```bash
# local dev (needs Docker running)
supabase start                      # boots local Postgres + Studio; prints URL + keys
make db-migrate                     # applies supabase/migrations/* (initial + water_logs)
#  → then create the private storage bucket "capture-audio" in Studio (Storage tab)

# production (a hosted Supabase project, like Beacon's)
supabase login
supabase link --project-ref <your-project-ref>
supabase db push                    # applies the migrations to the hosted DB
#  → create the "capture-audio" bucket (private) + enable Sign in with Apple in Auth
```

Then put the credentials in `.env` (copy `.env.example`): `SUPABASE_URL`,
`SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`. The backend auto-detects them; with no
env it falls back to the in-memory fake (so tests/CI stay offline).

> Migrations are **yours to run** (`make db-migrate` / `supabase db push`) — an agent
> never applies them (MUST-NOT rule). Two migration files today:
> `20260612000001_initial.sql` (15 tables + RLS) and `20260618000001_water_logs.sql`.

Auth note: the app uses **Sign in with Apple** (decision #26) — enable the Apple provider
in Supabase Auth, no SMS provider needed.

---

## 5. Get it to TestFlight (the simple path)

Once the native screens are built and the backend is deployed, the path is:

1. **Apple Developer Program** — enrol ($99/yr) if you haven't.
2. **Identifiers** — register the App ID `com.vocal.app` with the *App Groups* capability
   (`group.com.vocal.shared`). Set your team in `apps/ios/project.yml` (`DEVELOPMENT_TEAM`)
   and `make ios-generate`.
3. **App Store Connect** — create the app record (name "Vo-Cal", category Health & Fitness).
4. **Archive + upload** — either Xcode (Product ▸ Archive ▸ Distribute ▸ App Store Connect),
   or the publish skill I'll port from Beacon in Phase I (`bump-version` → archive → export
   → upload, one command).
5. **TestFlight** — add yourself as an internal tester; install the TestFlight app on your
   iPhone and you're running it. External testers (Francesco's list) need **Beta App Review**,
   which requires the privacy-policy URL + in-app account deletion (Phase I builds those).

**What's gated on you (provisioning):** the Apple account, the Supabase project + keys,
the Anthropic/USDA API keys, and running the migrations. Everything else I build.

---

## 6. How to start using it yourself

- **Right now:** `make ios-sim` — themed shell + voice plumbing on the simulator; and the
  hosted prototype link for the full intended UX (onboarding → protocol → voice log →
  per-ingredient checks → dashboard → Progress).
- **Next (after Phase D/E/F):** I build the real native screens on top of the finished
  backend; you deploy the backend (Fly.io, Beacon-style) + plug the keys + run migrations;
  then TestFlight on your phone for real voice meal logging with your own protocol.

---

## 7. What's built vs. what's next

- **Done & tested:** the whole backend (parser engine + per-ingredient checks, protocol
  engine, today/micros, nudging, captures, admin), the Serein voice layer (9/9 on sim),
  the SPM contract, the schema, the prototype. ~260 API + 19 SPM tests, all green.
- **Next (native, now unblocked):** Phase D (voice-log screen), E1/E2 (Today UI),
  F0–F2/F4–F6 (onboarding + protocol + lingo UI), G1 (check-in UI), C5 (on-device
  transcription), then Phase I (provisioning) → TestFlight.
