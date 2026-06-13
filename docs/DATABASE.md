# Database — Supabase Schema & RLS

> Source: authored for Vo-Cal (Phase A6). Migration: `supabase/migrations/20260612000001_initial.sql`.
> Doc shape adapted from Beacon's `docs/DATABASE.md`.

## The migration rule

**Claude MUST NOT run migrations or reset the database** (AGENTS.md MUST NOT #1).
Agents write migration SQL; **the user runs `make db-migrate`** (and
`ALLOW_DB_RESET=1 make db-reset` for destructive resets). Migrations are plain
SQL files in `supabase/migrations/`, ordered by timestamp prefix, and must be
idempotent-safe to re-apply via `supabase db reset`.

```bash
make db-start     # local Supabase (Docker)        — user runs (Phase A7 Makefile)
make db-migrate   # apply pending migrations       — USER ONLY
ALLOW_DB_RESET=1 make db-reset   # drop + reapply  — USER ONLY, gated
```

## Immutability classes

Every table carries one of four classes. These are load-bearing: raw captures
and their derived artifacts are the audit trail and the parser's training data
(AGENTS.md non-negotiable #5) — weakening them is a stop-the-line bug.

| Class | Meaning | Enforcement |
|---|---|---|
| **immutable** | Rows never change after insert | No client UPDATE/DELETE policy + `REVOKE UPDATE, DELETE` from `anon`/`authenticated` |
| **append-only** | New rows supersede; old rows never rewritten | Same as immutable; supersession via `supersedes`/`version` columns |
| **mutable** | Owner may edit in place | Owner-scoped UPDATE policies |
| **derived cache** | Rebuildable reference data | Service-role writes only; authenticated read |

## Tables

| Table | Class | Owner scope | Notes |
|---|---|---|---|
| `profiles` | mutable | `id = auth.uid()` | 1:1 extension of `auth.users` (phone, tz) |
| `intake_responses` | append-only | `user_id` | Versioned intake answers; re-intake appends |
| `protocols` | append-only* | `user_id` | New version inserts with `supersedes`; *only the `active` flag mutates (partial unique index: one active per user) |
| `captures` | append-only | `user_id` | Raw capture record; audio is ground truth. `status` transitions are **service-role only** (workflow state, not content). `(user_id, client_capture_id)` unique → idempotent upload retries |
| `transcripts` | immutable | via parent capture | Derived artifact; re-transcription appends. Service-role written |
| `parses` | immutable | via parent capture | Parser-contract payload + `model` + `prompt_version`; re-parse appends with `supersedes`. Service-role written |
| `meal_logs` | mutable | `user_id` | User-confirmed truth; edits allowed, **soft delete only** (`deleted_at`) so corrections survive. `(user_id, client_meal_id)` partial unique → idempotent outbox replays |
| `corrections` | append-only | via parent meal_log | parsed→confirmed deltas; the training data and audit trail. Client may INSERT, never UPDATE/DELETE |
| `saved_meals` | mutable | `user_id` | "Usuals" — full owner CRUD |
| `checkins` | mutable | `user_id` | `accepted` is set after the recommendation is shown |
| `food_dictionary` | derived cache | shared read | Canonical foods, aliases (GIN-indexed), per-100g macros, unit/state conversions |
| `usda_cache` | derived cache | shared read | USDA FDC lookups keyed by `query_key` (unique) |
| `admin_reviews` | mutable | **none — service-role only** | Phase H review verdicts |
| `admin_audit_log` | append-only | **none — service-role only** | Every admin access to user data is logged here (AGENTS.md #7) |
| `client_metrics` | append-only | `user_id` | Telemetry events from `POST /metrics/client`. Durations/counts/confidence only — never phone numbers or health values (AGENTS.md MUST NOT #5) |

**FK root:** user-owned tables reference `auth.users(id) ON DELETE CASCADE`
directly (not `profiles`) so a voice-first capture can be owned before the
profile row exists. `profiles` is an extension, not the identity root.

## RLS posture

RLS is **enabled on all 15 tables**.

- **Owner-only policies** on every user table: `user_id = (SELECT auth.uid())`
  (`profiles` keys on `id`). SELECT/INSERT everywhere; UPDATE only where the
  class is mutable; DELETE only on `saved_meals`.
- **Child artifacts** (`transcripts`, `parses`, `corrections`) are scoped
  through their parent's owner with `EXISTS` subqueries against
  `captures`/`meal_logs`. `transcripts`/`parses` have no INSERT policy — the
  enrichment worker writes them with the service role.
- **Reference caches** (`food_dictionary`, `usda_cache`): `SELECT TO
  authenticated USING (true)`; no write policies.
- **Admin tables**: RLS enabled with **no policies** — reachable only by the
  service role (BYPASSRLS). The admin panel (Phase H) goes through the API,
  which writes `admin_audit_log` for every access.
- **Append-only enforcement** is doubled at the grant layer:
  `REVOKE UPDATE, DELETE … FROM anon, authenticated` on `captures`,
  `transcripts`, `parses`, `corrections` (plus `intake_responses`,
  `client_metrics`). REVOKE was chosen over a raise-exception trigger because
  the worker must still transition `captures.status` with the service role; a
  trigger would block that too, while REVOKE survives an
  accidentally-permissive policy added later.
- **API role discipline** (Beacon's rule): user-facing queries run with the
  user's JWT so RLS is enforced; the service role is reserved for the
  enrichment worker and admin surface, never for reads that should respect
  visibility.

## Storage

Private bucket **`capture-audio`** holds raw capture audio. Bucket creation is
a Supabase **config step**, not a migration: declare it in
`supabase/config.toml` (`[storage.buckets]`, `public = false`) or via the
dashboard. Access only through short-lived signed URLs minted by the API.
Audio objects are immutable once written.

## Verifying isolation

- Offline (every test run): `FakeDatabase` mirrors owner scoping —
  `services/api/tests/test_rls_probe.py`.
- Live: `uv run pytest -m live_db` with `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
  `SUPABASE_SERVICE_ROLE_KEY` set proves user A's `captures`/`meal_logs` are
  invisible to user B under the real policies (deselected by default in
  `pyproject.toml` addopts).
