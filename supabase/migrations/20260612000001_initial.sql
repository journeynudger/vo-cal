-- =============================================================================
-- VO-CAL — Initial Schema (Phase A6)
-- =============================================================================
-- Full data model, migration-first, so Phases B–H add logic rather than fight
-- schema. Immutability classes per table are documented in docs/DATABASE.md:
--   immutable / append-only : captures, transcripts, parses, corrections,
--                             intake_responses, client_metrics, admin_audit_log
--   mutable                 : profiles, meal_logs, saved_meals, checkins,
--                             protocols (active flag only)
--   derived cache           : food_dictionary, usda_cache
--
-- User-owned tables reference auth.users(id) directly (not profiles) so a
-- voice-first capture can be owned before the profile row exists; profiles is
-- the 1:1 app-level extension of auth.users, not the identity root.
-- =============================================================================

-- =============================================================================
-- TABLES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- profiles — 1:1 extension of auth.users (mutable)
-- -----------------------------------------------------------------------------
CREATE TABLE public.profiles (
    id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    phone text UNIQUE,
    tz text,
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.profiles IS 'App-level user profile extending Supabase auth.users';

-- -----------------------------------------------------------------------------
-- intake_responses — versioned onboarding answers (append-only)
-- -----------------------------------------------------------------------------
CREATE TABLE public.intake_responses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    version int NOT NULL DEFAULT 1,
    answers jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_intake_responses_user ON public.intake_responses (user_id);

COMMENT ON TABLE public.intake_responses IS 'Versioned intake answers; re-intake appends a new row';

-- -----------------------------------------------------------------------------
-- protocols — versioned targets + whys; only the active flag mutates
-- -----------------------------------------------------------------------------
CREATE TABLE public.protocols (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    version int NOT NULL,
    supersedes uuid REFERENCES public.protocols (id),
    active bool NOT NULL DEFAULT true,
    targets jsonb NOT NULL,
    whys jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_protocols_user ON public.protocols (user_id);

-- One active protocol per user; revisions insert a new row (supersedes the old)
-- and flip the old row's active flag — never rewrite targets in place.
CREATE UNIQUE INDEX idx_one_active_protocol
ON public.protocols (user_id)
WHERE active;

COMMENT ON TABLE public.protocols IS 'Versioned nutrition protocols; new version supersedes, old deactivates';

-- -----------------------------------------------------------------------------
-- captures — raw voice capture records (append-only; status is workflow state)
-- -----------------------------------------------------------------------------
CREATE TABLE public.captures (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    client_capture_id text NOT NULL,
    audio_path text,
    duration_ms int,
    device text,
    status text NOT NULL CHECK (
        status IN (
            'uploaded',
            'transcription_pending',
            'transcribing',
            'parsed_pending',
            'parsing',
            'ready',
            'exhausted'
        )
    ),
    created_at timestamptz NOT NULL DEFAULT now(),

    -- Client-generated id makes upload retries idempotent per user.
    CONSTRAINT unique_client_capture UNIQUE (user_id, client_capture_id)
);

CREATE INDEX idx_captures_user ON public.captures (user_id);
CREATE INDEX idx_captures_status ON public.captures (status);

COMMENT ON TABLE public.captures IS 'Raw capture records — audio is ground truth; rows are append-only for clients (status transitions are service-role only)';

-- -----------------------------------------------------------------------------
-- transcripts — derived artifact of a capture (immutable)
-- -----------------------------------------------------------------------------
CREATE TABLE public.transcripts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    capture_id uuid NOT NULL REFERENCES public.captures (id) ON DELETE CASCADE,
    provider text NOT NULL,
    text text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_transcripts_capture ON public.transcripts (capture_id);

COMMENT ON TABLE public.transcripts IS 'Derived transcription artifacts; re-transcription appends a new row';

-- -----------------------------------------------------------------------------
-- parses — derived parser-contract artifact (immutable; re-parse supersedes)
-- -----------------------------------------------------------------------------
CREATE TABLE public.parses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    capture_id uuid NOT NULL REFERENCES public.captures (id) ON DELETE CASCADE,
    transcript_id uuid NOT NULL REFERENCES public.transcripts (id) ON DELETE CASCADE,
    supersedes uuid REFERENCES public.parses (id),
    payload jsonb NOT NULL,
    model text NOT NULL,
    prompt_version text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_parses_capture ON public.parses (capture_id);
CREATE INDEX idx_parses_transcript ON public.parses (transcript_id);

COMMENT ON TABLE public.parses IS 'Parser-contract payloads (docs/PARSER_CONTRACT.md); re-parse appends with supersedes';

-- -----------------------------------------------------------------------------
-- meal_logs — user-confirmed meals (mutable: edits + soft delete)
-- -----------------------------------------------------------------------------
CREATE TABLE public.meal_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    parse_id uuid REFERENCES public.parses (id),
    client_meal_id text,
    name text,
    meal_type text,
    items jsonb NOT NULL,
    totals jsonb NOT NULL,
    confidence numeric,
    logged_at timestamptz NOT NULL,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_meal_logs_user_logged ON public.meal_logs (user_id, logged_at DESC);

-- Client-generated id makes log retries idempotent per user (outbox replays).
CREATE UNIQUE INDEX idx_meal_logs_client_meal
ON public.meal_logs (user_id, client_meal_id)
WHERE client_meal_id IS NOT NULL;

COMMENT ON TABLE public.meal_logs IS 'User-confirmed meals; mutable (edits, soft delete via deleted_at); provenance via parse_id';

-- -----------------------------------------------------------------------------
-- corrections — append-only audit trail + training data
-- -----------------------------------------------------------------------------
CREATE TABLE public.corrections (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    meal_log_id uuid NOT NULL REFERENCES public.meal_logs (id) ON DELETE CASCADE,
    item_index int NOT NULL,
    field text NOT NULL,
    parsed_value jsonb,
    confirmed_value jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_corrections_meal_log ON public.corrections (meal_log_id);

COMMENT ON TABLE public.corrections IS 'Append-only parsed→confirmed deltas; the parser training data and audit trail';

-- -----------------------------------------------------------------------------
-- saved_meals — "usuals" (mutable)
-- -----------------------------------------------------------------------------
CREATE TABLE public.saved_meals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    name text NOT NULL,
    items jsonb NOT NULL,
    totals jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_saved_meals_user ON public.saved_meals (user_id);

COMMENT ON TABLE public.saved_meals IS 'User-saved meal templates ("usuals")';

-- -----------------------------------------------------------------------------
-- checkins — weekly check-ins (mutable: accepted is set after recommendation)
-- -----------------------------------------------------------------------------
CREATE TABLE public.checkins (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    weight_kg numeric,
    hunger int,
    energy int,
    adherence_self int,
    notes text,
    computed jsonb,
    recommendation jsonb,
    accepted bool,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_checkins_user ON public.checkins (user_id, created_at DESC);

COMMENT ON TABLE public.checkins IS 'Weekly check-in inputs, computed trends, and protocol recommendations';

-- -----------------------------------------------------------------------------
-- food_dictionary — internal foods reference (derived cache, shared read)
-- -----------------------------------------------------------------------------
CREATE TABLE public.food_dictionary (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    canonical_name text NOT NULL UNIQUE,
    aliases text [] NOT NULL DEFAULT '{}',
    per_100g jsonb NOT NULL,
    unit_conversions jsonb,
    raw_cooked_factor numeric,
    variants jsonb
);

CREATE INDEX idx_food_dictionary_aliases ON public.food_dictionary USING gin (aliases);

COMMENT ON TABLE public.food_dictionary IS 'Internal food reference: aliases, per-100g macros, unit/state conversions';

-- -----------------------------------------------------------------------------
-- usda_cache — USDA FDC lookup cache (derived cache, shared read)
-- -----------------------------------------------------------------------------
CREATE TABLE public.usda_cache (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    query_key text NOT NULL UNIQUE,
    fdc_id bigint,
    profile jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.usda_cache IS 'Cache of USDA FoodData Central lookups, keyed by normalized query';

-- -----------------------------------------------------------------------------
-- admin_reviews — admin verdicts on meal logs (service-role only)
-- -----------------------------------------------------------------------------
CREATE TABLE public.admin_reviews (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    meal_log_id uuid NOT NULL REFERENCES public.meal_logs (id) ON DELETE CASCADE,
    reviewer text NOT NULL,
    verdict text NOT NULL,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_admin_reviews_meal_log ON public.admin_reviews (meal_log_id);

COMMENT ON TABLE public.admin_reviews IS 'Admin parse-quality review verdicts (Phase H)';

-- -----------------------------------------------------------------------------
-- admin_audit_log — append-only audit of admin access (service-role only)
-- -----------------------------------------------------------------------------
CREATE TABLE public.admin_audit_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_email text NOT NULL,
    action text NOT NULL,
    subject_type text,
    subject_id uuid,
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.admin_audit_log IS 'Append-only record of admin access to user data (AGENTS.md non-negotiable #7)';

-- -----------------------------------------------------------------------------
-- client_metrics — client-reported telemetry events (append-only)
-- Durations, counts, confidence only — never phone numbers or health values.
-- -----------------------------------------------------------------------------
CREATE TABLE public.client_metrics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    name text NOT NULL,
    value numeric NOT NULL,
    attributes jsonb NOT NULL DEFAULT '{}',
    ts timestamptz NOT NULL
);

CREATE INDEX idx_client_metrics_user_ts ON public.client_metrics (user_id, ts DESC);

COMMENT ON TABLE public.client_metrics IS 'Client-reported metric events ingested via POST /metrics/client';

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================
-- Posture: owner-only on every user table (user_id = auth.uid()); child
-- artifacts scoped through their parent's owner via EXISTS; reference caches
-- read-only for authenticated; admin tables have RLS enabled with NO policies,
-- so only the service role (BYPASSRLS) can touch them.

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.intake_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.protocols ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.captures ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transcripts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.parses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meal_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saved_meals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.checkins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.food_dictionary ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usda_cache ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_metrics ENABLE ROW LEVEL SECURITY;

-- profiles: keyed on id = auth.uid()
CREATE POLICY profiles_select_own ON public.profiles
FOR SELECT TO authenticated USING (id = (SELECT auth.uid()));
CREATE POLICY profiles_insert_own ON public.profiles
FOR INSERT TO authenticated WITH CHECK (id = (SELECT auth.uid()));
CREATE POLICY profiles_update_own ON public.profiles
FOR UPDATE TO authenticated
USING (id = (SELECT auth.uid()))
WITH CHECK (id = (SELECT auth.uid()));

-- intake_responses: append-only — select + insert, no update/delete policies
CREATE POLICY intake_select_own ON public.intake_responses
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY intake_insert_own ON public.intake_responses
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));

-- protocols: select/insert own; update own limited in practice to the active
-- flag flip (versioned rows are superseded, never rewritten — see DATABASE.md)
CREATE POLICY protocols_select_own ON public.protocols
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY protocols_insert_own ON public.protocols
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY protocols_update_own ON public.protocols
FOR UPDATE TO authenticated
USING (user_id = (SELECT auth.uid()))
WITH CHECK (user_id = (SELECT auth.uid()));

-- captures: select + insert own; no client update/delete (append-only)
CREATE POLICY captures_select_own ON public.captures
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY captures_insert_own ON public.captures
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));

-- transcripts: read-only for the owner of the parent capture; written only by
-- the enrichment worker (service role), so no insert policy for authenticated
CREATE POLICY transcripts_select_owner ON public.transcripts
FOR SELECT TO authenticated USING (
    EXISTS (
        SELECT 1 FROM public.captures AS c
        WHERE c.id = transcripts.capture_id AND c.user_id = (SELECT auth.uid())
    )
);

-- parses: same posture as transcripts (service-role written, owner readable)
CREATE POLICY parses_select_owner ON public.parses
FOR SELECT TO authenticated USING (
    EXISTS (
        SELECT 1 FROM public.captures AS c
        WHERE c.id = parses.capture_id AND c.user_id = (SELECT auth.uid())
    )
);

-- meal_logs: owner CRUD minus delete — deletion is soft (deleted_at) so the
-- log's audit trail (corrections) survives
CREATE POLICY meal_logs_select_own ON public.meal_logs
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY meal_logs_insert_own ON public.meal_logs
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY meal_logs_update_own ON public.meal_logs
FOR UPDATE TO authenticated
USING (user_id = (SELECT auth.uid()))
WITH CHECK (user_id = (SELECT auth.uid()));

-- corrections: owner (via parent meal_log) may read and append; never mutate
CREATE POLICY corrections_select_owner ON public.corrections
FOR SELECT TO authenticated USING (
    EXISTS (
        SELECT 1 FROM public.meal_logs AS m
        WHERE m.id = corrections.meal_log_id AND m.user_id = (SELECT auth.uid())
    )
);
CREATE POLICY corrections_insert_owner ON public.corrections
FOR INSERT TO authenticated WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.meal_logs AS m
        WHERE m.id = corrections.meal_log_id AND m.user_id = (SELECT auth.uid())
    )
);

-- saved_meals: full owner CRUD (user-managed templates)
CREATE POLICY saved_meals_select_own ON public.saved_meals
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY saved_meals_insert_own ON public.saved_meals
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY saved_meals_update_own ON public.saved_meals
FOR UPDATE TO authenticated
USING (user_id = (SELECT auth.uid()))
WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY saved_meals_delete_own ON public.saved_meals
FOR DELETE TO authenticated USING (user_id = (SELECT auth.uid()));

-- checkins: select/insert own; update own (accepted is set after the
-- recommendation is shown)
CREATE POLICY checkins_select_own ON public.checkins
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY checkins_insert_own ON public.checkins
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY checkins_update_own ON public.checkins
FOR UPDATE TO authenticated
USING (user_id = (SELECT auth.uid()))
WITH CHECK (user_id = (SELECT auth.uid()));

-- food_dictionary + usda_cache: shared reference data — read for any
-- authenticated user; writes are service-role only (no write policies)
CREATE POLICY food_dictionary_read ON public.food_dictionary
FOR SELECT TO authenticated USING (true);
CREATE POLICY usda_cache_read ON public.usda_cache
FOR SELECT TO authenticated USING (true);

-- admin_reviews / admin_audit_log: RLS enabled, NO policies — service-role only.

-- client_metrics: insert + select own (append-only telemetry)
CREATE POLICY client_metrics_select_own ON public.client_metrics
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY client_metrics_insert_own ON public.client_metrics
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));

-- =============================================================================
-- APPEND-ONLY ENFORCEMENT (grant layer)
-- =============================================================================
-- REVOKE rather than a raise-exception trigger: the enrichment worker
-- (service role) must still transition captures.status through its workflow,
-- and a trigger would block service-role writes too. Absent UPDATE/DELETE
-- policies already deny these via RLS for client roles; the REVOKE is
-- defense-in-depth at the grant layer — it survives an accidentally-permissive
-- future policy (e.g. a careless FOR ALL policy added in a later migration).
-- Supabase grants ALL on public tables to anon/authenticated by default.

REVOKE UPDATE, DELETE ON public.captures FROM anon, authenticated;
REVOKE UPDATE, DELETE ON public.transcripts FROM anon, authenticated;
REVOKE UPDATE, DELETE ON public.parses FROM anon, authenticated;
REVOKE UPDATE, DELETE ON public.corrections FROM anon, authenticated;
REVOKE UPDATE, DELETE ON public.intake_responses FROM anon, authenticated;
REVOKE UPDATE, DELETE ON public.client_metrics FROM anon, authenticated;

-- =============================================================================
-- STORAGE — capture-audio bucket (config step, documented here)
-- =============================================================================
-- A private bucket named `capture-audio` holds raw capture audio (the ground
-- truth). It is NOT created in this migration: bucket creation is a Supabase
-- config step — declare it in supabase/config.toml ([storage.buckets] entry,
-- public = false) or create it via the dashboard, in the same setup pass as
-- `make db-start` (Phase A7). Access is via short-lived signed URLs minted by
-- the API only; no public access, no client-side direct paths. Audio objects
-- are immutable once written (audio is ground truth — AGENTS.md #1).
