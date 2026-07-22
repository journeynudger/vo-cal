#!/usr/bin/env bash
# Fresh-machine bootstrap for Vo-Cal local dev. IDEMPOTENT: safe to run twice.
#
# What it does (each step skips itself if already done):
#   1. Homebrew deps (Brewfile) + Python deps (uv sync in services/api).
#   2. .env from .env.example if missing (offline defaults; fill keys later).
#   3. LOCAL Supabase via docker: start, apply migrations, apply supabase/seed.sql
#      (seeded users + 3 weeks of meal history — see .agents/seed-users.json).
#      Dev-only speed tuning: fsync=off, synchronous_commit=off (env is disposable).
#   4. Generate the iOS project (XcodeGen) if Xcode tooling is present.
#
# LOCAL-ONLY GUARD: this script refuses to touch a database that isn't 127.0.0.1/localhost.
# It never runs against hosted Supabase (AGENTS.md MUST-NOT #1 — hosted migrations are
# user-run only). Docker not running => steps 3 is skipped with a clear message and the
# API still boots offline on FakeDatabase.

set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

say()  { printf '\033[1;36m[setup-dev]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup-dev]\033[0m %s\n' "$*"; }

[ -f "Makefile" ] && [ -d "services/api" ] || {
  echo "[setup-dev] ERROR: run from the vo-cal repo root (Makefile + services/api not found here)"; exit 1;
}

# -- 1. Dependencies ----------------------------------------------------------
say "brew bundle (Brewfile)…"
command -v brew >/dev/null || { echo "[setup-dev] ERROR: Homebrew required (https://brew.sh)"; exit 1; }
brew bundle --no-upgrade >/dev/null || brew bundle

say "python deps (uv sync)…"
(cd services/api && uv sync --quiet)

# -- 2. Env file --------------------------------------------------------------
if [ ! -f .env ]; then
  say "creating .env from .env.example (offline defaults — add real keys when needed)"
  cp .env.example .env
else
  say ".env exists — leaving it alone"
fi

# -- 3. Local Supabase: start + migrate + seed --------------------------------
if docker info >/dev/null 2>&1; then
  say "starting local Supabase (no-op if already running)…"
  supabase start >/dev/null 2>&1 || supabase start

  DB_URL="$(supabase status --output json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("DB_URL",""))' || true)"
  [ -z "$DB_URL" ] && DB_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"

  case "$DB_URL" in
    *127.0.0.1*|*localhost*) : ;;
    *) echo "[setup-dev] ERROR: refusing — DB_URL is not local ($DB_URL). This script never touches hosted Supabase."; exit 1 ;;
  esac

  say "applying migrations to LOCAL db…"
  # No output-swallowing, no `|| true`: a failed migration used to pass silently
  # and resurface later as a baffling seed failure against a drifted schema.
  if ! supabase db push --local --include-all; then
    say "db push failed — retrying with supabase migration up…"
    supabase migration up --local
  fi

  say "applying supabase/seed.sql (idempotent)…"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f supabase/seed.sql

  say "dev-only speed tuning (fsync off — this database is disposable)…"
  psql "$DB_URL" -q -c "ALTER SYSTEM SET fsync = off;" \
                 -c "ALTER SYSTEM SET synchronous_commit = off;" \
                 -c "SELECT pg_reload_conf();" >/dev/null || warn "speed tuning skipped (non-fatal)"

  say "seeded users: $(python3 -c 'import json; print(", ".join(u["email"] for u in json.load(open(".agents/seed-users.json"))["users"]))')"
else
  warn "docker is not running — skipped Supabase start/migrate/seed."
  warn "The API still runs offline (FakeDatabase; nothing persists). Start docker and re-run for a real db."
fi

# -- 4. iOS project (optional on headless boxes) -------------------------------
if command -v xcodegen >/dev/null && command -v xcodebuild >/dev/null; then
  say "generating VoCal.xcodeproj (XcodeGen)…"
  (cd apps/ios && xcodegen generate >/dev/null)
else
  warn "xcodegen/xcodebuild not found — skipped iOS project generation (fine for API-only work)."
fi

say "done. Next: scripts/ensure-dev-server.sh  → then curl \$(cat .agents/dev-ports.json | python3 -c 'import json,sys; print(\"http://127.0.0.1:%s/__dev/preflight\" % json.load(sys.stdin)[\"api\"])')"
