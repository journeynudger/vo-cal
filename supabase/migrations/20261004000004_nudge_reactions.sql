-- Nudge reactions (decision 67): how the person answered a nudge, so the engine can remember.
-- One row per answer, append-only: a dismissal (the card's close or swipe, the notification's
-- "Not today"), an act (Log it, or a log soon after), and the long-press's three reasons (wrong
-- time, not for me, too often), plus the unmute that reverses "not for me". The engine reads them
-- (nudges/reactions.py effects): three dismissals in a row silence a nudge for a month; not for
-- me mutes it until an unmute; wrong time moves its slot later; too often doubles its cooldown.
-- Applied by the Deploy workflow (supabase db push); agents MUST NOT run migrations by hand
-- (AGENTS.md MUST NOT #1).

CREATE TABLE public.nudge_reactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    -- The catalog id (nudges/catalog.py), e.g. treat_headroom.
    nudge_id text NOT NULL,
    -- dismissed | acted | wrong_time | not_for_me | too_often | unmute (nudges/reactions.py).
    kind text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_nudge_reactions_user
ON public.nudge_reactions (user_id, created_at DESC);

ALTER TABLE public.nudge_reactions ENABLE ROW LEVEL SECURITY;

-- Owner select + insert only; append-only like tracking_preferences.
CREATE POLICY nudge_reactions_select_own ON public.nudge_reactions
FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY nudge_reactions_insert_own ON public.nudge_reactions
FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));

REVOKE UPDATE, DELETE ON public.nudge_reactions FROM anon, authenticated;

COMMENT ON TABLE public.nudge_reactions IS 'How the person answered each nudge (dismissed, acted, wrong time, not for me, too often, unmute); append-only; the engine reads it to go quiet';
