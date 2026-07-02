-- =============================================================================
-- STORAGE — capture-audio bucket + object RLS (declared in code, not the dashboard)
-- =============================================================================
-- The initial migration deferred bucket creation to "a config step" and never
-- declared Storage object RLS. That left the most sensitive data in the system —
-- raw capture audio — protected only by convention + the API's signed-URL discipline.
-- If the bucket were ever created public, or created without object RLS, a direct
-- Storage read would bypass the API entirely and expose every user's audio
-- (INVARIANTS §12 — cross-account access must fail MECHANICALLY, not by convention;
-- AGENTS.md #1 — audio is ground truth). This migration makes the boundary mechanical.
--
-- Idempotent: safe to run against a project where the bucket was already created by
-- hand (ON CONFLICT) — it just enforces private + the policies.

-- 1. Bucket exists and is PRIVATE (no public reads; signed URLs only).
INSERT INTO storage.buckets (id, name, public)
VALUES ('capture-audio', 'capture-audio', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- 2. Object RLS scoped to the per-user "{user_id}/..." key prefix that the API writes
--    (services/api storage key = f"{user_id}/{client_capture_id}.caf") and that account
--    deletion relies on. storage.foldername(name)[1] is the first path segment — it must
--    equal the caller's auth.uid() for every authenticated operation. The service role
--    (API/worker) bypasses RLS and is unaffected; these policies bound DIRECT client access.
--
--    Audio is immutable once written (AGENTS.md #1): authenticated callers get INSERT +
--    SELECT within their own prefix, never UPDATE. DELETE is allowed within the prefix so
--    account deletion works even if it ever runs as the user rather than the service role.

CREATE POLICY "capture-audio owner insert"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
    bucket_id = 'capture-audio'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);

CREATE POLICY "capture-audio owner read"
ON storage.objects FOR SELECT TO authenticated
USING (
    bucket_id = 'capture-audio'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);

CREATE POLICY "capture-audio owner delete"
ON storage.objects FOR DELETE TO authenticated
USING (
    bucket_id = 'capture-audio'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);
