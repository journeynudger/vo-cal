-- Meal plans: the meals a person plans for a day, checked off as they log them (decision 65,
-- plan P8). Written by the person from their usuals or a typed meal (D5 a); the engine checks
-- the plan against the protocol and says so in one line. One row per version, append-only,
-- like tracking_preferences: the latest version is the plan; the history is the record.
-- Applied by the Deploy workflow (supabase db push); agents MUST NOT run migrations by hand
-- (AGENTS.md MUST NOT #1).

CREATE TABLE public.meal_plans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    version int NOT NULL,
    -- person | coach: who wrote this version. The coach lane is designed for here and built
    -- later; a plan always says whose it is.
    author text NOT NULL DEFAULT 'person',
    -- The slots in order: [{"index", "name", "usual_id", "items": [ConfirmedItem...],
    -- "totals": Macros}] (meals/plan.py PlanSlot). Items and totals are the server's: a usual's
    -- stored items, or a typed meal's items re-priced on the confirm path (RT-02).
    slots jsonb NOT NULL DEFAULT '[]'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_meal_plans_user
ON public.meal_plans (user_id, version DESC);

-- Versions are dense and unique per person (mirrored in FakeDatabase._UNIQUE_INDEXES).
CREATE UNIQUE INDEX uq_meal_plans_version
ON public.meal_plans (user_id, version);

ALTER TABLE public.meal_plans ENABLE ROW LEVEL SECURITY;

-- Owner select + insert only; append-only like tracking_preferences.
CREATE POLICY meal_plans_select_own ON public.meal_plans
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY meal_plans_insert_own ON public.meal_plans
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));

REVOKE UPDATE, DELETE ON public.meal_plans FROM anon, authenticated;

COMMENT ON TABLE public.meal_plans IS 'The meals a person plans for a day, from their usuals or a typed meal, checked against the protocol; versioned, append-only; the latest version is the plan';
