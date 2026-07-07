# supabase/ — database schema, migrations, seed

- **Migrations** (`migrations/*.sql`): append-only, timestamped. Agents may WRITE migration
  files; **applying them is user-run only** (`make db-migrate` — AGENTS.md MUST-NOT #1) —
  EXCEPT the local docker stack, which `scripts/setup-dev.sh` migrates + seeds (guarded to
  refuse anything that isn't 127.0.0.1/localhost).
- **Seed** (`seed.sql`): idempotent (fixed UUIDs + ON CONFLICT DO NOTHING). Seeded users
  are listed in `.agents/seed-users.json` (dev@vo-cal.test has 3 weeks of meal history +
  the IP worked-example protocol; fresh@vo-cal.test is a clean slate). Password for both:
  `vocal-dev-password`.
- **RLS posture**: owner-only (`user_id = auth.uid()`) on every user table; child tables
  (transcripts, corrections) scope through their parent; `food_dictionary`/`usda_cache`
  read-all; admin tables service-role only. The API ALSO owner-scopes every query in code
  because it runs with the service-role key (RLS alone doesn't protect it).
- **Immutability classes** (ARCHITECTURE.md): captures/transcripts/parses/corrections/
  checkins/protocol-versions are never UPDATEd — new rows only. `meal_logs` deletes are
  tombstones (`deleted_at`).
- **Storage**: the `capture-audio` bucket is declared private in `config.toml`; per-user
  object RLS lives in `20260701000001_capture_audio_bucket_rls.sql`.
- When adding a UNIQUE index used for idempotency, mirror it in `FakeDatabase._UNIQUE_INDEXES`
  (services/api/src/api/db.py) or dedup regressions will pass offline and fail on Postgres.
