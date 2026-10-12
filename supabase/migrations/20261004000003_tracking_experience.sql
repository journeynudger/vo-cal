-- The onboarding that asks (decision 66): two more answers join the preference. The nudge level
-- moves from a phone setting the record never saw into the one durable place, where the engine
-- reads it and the export carries it; the frictions name what gets in the person's way, each
-- moving exactly one thing (tracking/projection.py experience_for). Additive: a client that
-- sends neither changes nothing, and a row written before this migration reads as "never asked".
-- Applied by the Deploy workflow (supabase db push); agents MUST NOT run migrations by hand
-- (AGENTS.md MUST NOT #1).

ALTER TABLE public.tracking_preferences
    -- essential | standard | off (tracking/schemas.py NudgeLevel); NULL = never asked, the
    -- phone's own value stands (every account from before 2026-10-04).
    ADD COLUMN nudge_level text,
    -- forgetting | portions | eating_out | time (tracking/schemas.py Friction); any or none.
    ADD COLUMN frictions jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.tracking_preferences.nudge_level IS 'How much the app says, in the engine''s three levels; NULL when never asked';
COMMENT ON COLUMN public.tracking_preferences.frictions IS 'What makes tracking hard for the person; each value moves one thing (projection.py)';
