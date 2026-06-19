-- Water log — the day's water tally (Phase E micros, decision #28).
-- Separate append-only table rather than a kind='water' marker on meal_logs,
-- which has NOT-NULL items/totals and is keyed for macro/produce aggregation.
-- /today sums today's rows into consumed.water; POST /meals/water appends one.

CREATE TABLE public.water_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    amount_oz numeric NOT NULL CHECK (amount_oz > 0),
    logged_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_water_logs_user_logged ON public.water_logs (user_id, logged_at DESC);

ALTER TABLE public.water_logs ENABLE ROW LEVEL SECURITY;

-- Owner CRUD (mirror meal_logs posture); append-only in practice (no UPDATE path).
CREATE POLICY water_logs_select_own ON public.water_logs
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY water_logs_insert_own ON public.water_logs
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));

COMMENT ON TABLE public.water_logs IS 'Per-entry water amounts; summed per day into /today consumed.water';
