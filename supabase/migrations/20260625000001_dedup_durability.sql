-- Durability dedup fixes (RT-12, RT-13). Reconciles the idempotency indexes with
-- soft-delete semantics and gives water logging an idempotency key, so outbox/offline
-- replays converge instead of 500ing or double-counting. Captures already had
-- unique_client_capture (RT-08 is a code-only catch). Run with `make db-migrate`.

-- RT-12: the original partial index did NOT exclude soft-deleted rows, so a tombstoned
-- meal kept its (user_id, client_meal_id) slot occupied — an outbox replay that crosses
-- a delete (or a re-log of the same staged meal) then hit the unique index and 500'd.
-- Excluding deleted_at frees the slot so the replay inserts a fresh live row; the
-- tombstone is retained as the audit trail. Matches FakeDatabase _is_live_client_meal.
DROP INDEX IF EXISTS idx_meal_logs_client_meal;
CREATE UNIQUE INDEX idx_meal_logs_client_meal
ON public.meal_logs (user_id, client_meal_id)
WHERE client_meal_id IS NOT NULL AND deleted_at IS NULL;

-- RT-13: water logging had no idempotency key, so a retried POST (the timeout-then-retry
-- the outbox exists for) double-counted a dashboard pillar. Add a client-generated id and
-- a partial unique index mirroring client_meal_id. Nullable so existing rows backfill clean.
ALTER TABLE public.water_logs ADD COLUMN client_water_id text;
CREATE UNIQUE INDEX idx_water_logs_client_water
ON public.water_logs (user_id, client_water_id)
WHERE client_water_id IS NOT NULL;
