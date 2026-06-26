-- RT-42: persist the real upload content type on captures so transcription uses it
-- instead of assuming audio/x-caf for every blob. Nullable — pre-existing rows (and any
-- client that omits it) fall back to audio/x-caf at transcribe time. Run with `make db-migrate`.
ALTER TABLE public.captures ADD COLUMN content_type text;
