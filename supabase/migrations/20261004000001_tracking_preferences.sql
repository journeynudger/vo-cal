-- Tracking preferences: how the person wants to follow their nutrition (decision 57).
-- One row per version, append-only: the history is the person's record of every move up
-- or down the ladder (decision 62) and the beta's richest signal. The latest version is the
-- truth; version 0 is never stored (no row = never chosen = today's dashboard, the "five").
-- Applied by the Deploy workflow (supabase db push); agents MUST NOT run migrations by hand
-- (AGENTS.md MUST NOT #1).

CREATE TABLE public.tracking_preferences (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    version int NOT NULL,
    -- habits | calories | five | macros | meal_plan (tracking/schemas.py TrackingMode).
    mode text NOT NULL,
    -- Opt-in tiles beyond the mode's own (decision 30): fiber, water, produce, carbs, fat,
    -- sugar, sodium.
    focus_metrics jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- Offers the person asked never to see again ("Don't offer this again"): a mode value
    -- ("calories") or a focus metric ("focus:protein") (tracking/schemas.py offer keys).
    declined_offers jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- chosen | invited | declined | coach: who moved the preference, and how.
    source text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_tracking_preferences_user
ON public.tracking_preferences (user_id, version DESC);

-- Versions are dense and unique per person; two concurrent appends collide here instead of
-- producing two "latest" rows (mirrored in FakeDatabase._UNIQUE_INDEXES).
CREATE UNIQUE INDEX uq_tracking_preferences_version
ON public.tracking_preferences (user_id, version);

ALTER TABLE public.tracking_preferences ENABLE ROW LEVEL SECURITY;

-- Owner select + insert only; append-only like intake_responses.
CREATE POLICY tracking_preferences_select_own ON public.tracking_preferences
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY tracking_preferences_insert_own ON public.tracking_preferences
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));

REVOKE UPDATE, DELETE ON public.tracking_preferences FROM anon, authenticated;

COMMENT ON TABLE public.tracking_preferences IS 'How the person follows their nutrition (mode, focus metrics, declined offers); versioned, append-only; the latest version is the truth';
