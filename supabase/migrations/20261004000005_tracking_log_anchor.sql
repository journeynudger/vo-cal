-- Behavior change end to end (decision 69): when the person said they will log joins the
-- preference. The two consistency reminders follow it (nudges/engine.py slot_for; the phone is
-- told the same hours through tracking/projection.py check_slots_for) and the late-morning check
-- names the plan back in the catalog's own words (nudges/catalog.py message_for). Additive: a
-- client that sends nothing changes nothing, and a row written before this migration reads as
-- "never asked", which moves nothing. Applied by the Deploy workflow (supabase db push); agents
-- MUST NOT run migrations by hand (AGENTS.md MUST NOT #1).

ALTER TABLE public.tracking_preferences
    -- after_eating | when_seated | before_bed | own (tracking/schemas.py LogAnchor); NULL = never
    -- asked (every account from before 2026-10-04).
    ADD COLUMN log_anchor text;

COMMENT ON COLUMN public.tracking_preferences.log_anchor IS 'When the person said they will log; the consistency reminders follow it (engine.slot_for); NULL when never asked';
