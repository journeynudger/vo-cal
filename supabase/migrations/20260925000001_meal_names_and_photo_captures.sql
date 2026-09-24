-- =============================================================================
-- Meal names have a source; photos are captures too (2026-09-25)
-- =============================================================================
-- 1. meal_logs.name_source: how a meal got its name. Every meal is now named after what
--    was eaten (services/api/src/api/meals/naming.py) unless the person named it; an
--    auto name follows the items on edit, a person's name never does. Additive and
--    nullable: rows before this migration read as "named by the person" when they carry
--    a name and as "auto" when they do not (naming.is_user_named).
ALTER TABLE public.meal_logs
    ADD COLUMN IF NOT EXISTS name_source text
    CHECK (name_source IS NULL OR name_source IN ('auto', 'user', 'recognized'));

COMMENT ON COLUMN public.meal_logs.name_source IS
    'auto = from the items; user = typed by the person; recognized = copied from a confirmed usual';

-- 2. capture-photos: a private bucket for photographed meals, the same boundary as
--    capture-audio (migration 20260701000001): private, owner-prefixed keys
--    ("{user_id}/{client_capture_id}.jpg"), object RLS so a direct client read of another
--    person's photo fails mechanically (INVARIANTS §12). Photos are captures (AGENTS.md #5:
--    immutable ground truth): INSERT + SELECT within the prefix, never UPDATE; DELETE for
--    account deletion.
INSERT INTO storage.buckets (id, name, public)
VALUES ('capture-photos', 'capture-photos', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS "capture-photos owner insert" ON storage.objects;
CREATE POLICY "capture-photos owner insert"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
    bucket_id = 'capture-photos'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);

DROP POLICY IF EXISTS "capture-photos owner read" ON storage.objects;
CREATE POLICY "capture-photos owner read"
ON storage.objects FOR SELECT TO authenticated
USING (
    bucket_id = 'capture-photos'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);

DROP POLICY IF EXISTS "capture-photos owner delete" ON storage.objects;
CREATE POLICY "capture-photos owner delete"
ON storage.objects FOR DELETE TO authenticated
USING (
    bucket_id = 'capture-photos'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);
