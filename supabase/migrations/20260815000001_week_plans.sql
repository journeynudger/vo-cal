-- Week plans — Carbon-style weekly calorie budget (per-day kcal allocations).
-- Append-only and versioned like intake_responses: a replan for the same
-- (user, week_start) inserts the next version; rows are never rewritten. The
-- API reads the max version per (user, week_start); past days inside a week are
-- frozen server-side before insert, so history never moves. Run with
-- `make db-migrate` (agents MUST NOT run migrations — AGENTS.md MUST NOT #1).

CREATE TABLE public.week_plans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    -- Monday of the planned week, in the user's timezone at plan time.
    week_start date NOT NULL,
    version int NOT NULL DEFAULT 1,
    -- All 7 ISO dates of the week -> whole kcal (the API validates + freezes).
    allocations jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_week_plans_user_week
ON public.week_plans (user_id, week_start, created_at DESC);

ALTER TABLE public.week_plans ENABLE ROW LEVEL SECURITY;

-- Owner select + insert only — append-only, so no UPDATE/DELETE policies
-- (mirrors intake_responses' posture in the initial migration).
CREATE POLICY week_plans_select_own ON public.week_plans
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY week_plans_insert_own ON public.week_plans
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));

-- Append-only doubled at the grant layer (defense-in-depth, same reasoning as
-- the initial migration's REVOKE block): survives an accidentally-permissive
-- future policy.
REVOKE UPDATE, DELETE ON public.week_plans FROM anon, authenticated;

COMMENT ON TABLE public.week_plans IS 'Versioned per-day kcal allocations for a Monday-start week; replan appends the next version';
