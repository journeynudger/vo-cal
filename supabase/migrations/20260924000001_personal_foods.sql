-- Personal foods: the foods a person declares (a meal-prep label, a batch they cooked and
-- divided into servings) and then speaks by name. Versioned, never rewritten: saving a
-- name the person already has retires the old row and inserts the new one, so a meal
-- priced with the old numbers keeps them (the identity is persisted on its items) while
-- the next parse uses the new ones. Applied by the Deploy workflow (supabase db push);
-- agents MUST NOT run migrations by hand (AGENTS.md MUST NOT #1).

CREATE TABLE public.personal_foods (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    name text NOT NULL,
    -- The normalized name the resolver looks foods up by (nutrition/dictionary.py normalize_name).
    name_key text NOT NULL,
    aliases jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- One serving: kcal, protein, carbs, fat, fiber (nutrition/schemas.py NutrientProfile).
    per_serving jsonb NOT NULL,
    -- Grams in one serving when known; null prices by servings only.
    serving_grams numeric,
    servings_per_package numeric,
    -- 'label' (as printed) or 'batch' (summed from resolved ingredients, divided by servings).
    source text NOT NULL,
    -- For a batch: the parse, the resolved items and totals it was built from.
    provenance jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    retired_at timestamptz
);

CREATE INDEX idx_personal_foods_user_live
ON public.personal_foods (user_id, created_at DESC)
WHERE retired_at IS NULL;

-- One live row per (user, name): a rename of the numbers retires first, then inserts.
CREATE UNIQUE INDEX uq_personal_foods_live_name
ON public.personal_foods (user_id, name_key)
WHERE retired_at IS NULL;

ALTER TABLE public.personal_foods ENABLE ROW LEVEL SECURITY;

-- Owner select, insert, and update (the update is the retire mark); never delete.
CREATE POLICY personal_foods_select_own ON public.personal_foods
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY personal_foods_insert_own ON public.personal_foods
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY personal_foods_update_own ON public.personal_foods
FOR UPDATE TO authenticated USING (user_id = (SELECT auth.uid()))
WITH CHECK (user_id = (SELECT auth.uid()));

REVOKE DELETE ON public.personal_foods FROM anon, authenticated;

COMMENT ON TABLE public.personal_foods IS 'Foods the person declared (label or batch), per serving; versioned by retire-then-insert; spoken by name';
