"""Durable-truth access for: meal_logs, corrections, saved_meals.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). meal_logs are mutable (edits, soft
delete via deleted_at); corrections are append-only; saved_meals are templates.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from uuid import UUID, uuid4

from ..db import SupportsDatabase
from .learning import FORGET_FIELD, NAME_FIELD

# How long a deleted meal can be restored (Bill: "recently deleted w/ 30 day recover").
# The app hides a tombstone the moment the window closes; the admin purge sweep
# (admin/router.py) is what removes the row for good. Deterministic, one number, both places.
RECENTLY_DELETED_DAYS = 30


class MealsStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def get_by_client_id(self, user_id: UUID, client_meal_id: str) -> dict[str, Any] | None:
        rows = await self._db.select(
            "meal_logs", {"client_meal_id": client_meal_id}, user_id=user_id
        )
        # FakeDatabase has no partial-unique index; pick the first live row.
        live = [r for r in rows if not r.get("deleted_at")]
        return live[0] if live else None

    async def insert_meal(
        self,
        *,
        user_id: UUID,
        client_meal_id: str,
        parse_id: UUID | None,
        name: str | None,
        meal_type: str,
        items: list[dict[str, Any]],
        totals: dict[str, Any],
        confidence: float,
        logged_at: datetime,
    ) -> dict[str, Any]:
        return await self._db.insert(
            "meal_logs",
            {
                "id": str(uuid4()),
                "user_id": str(user_id),
                "parse_id": str(parse_id) if parse_id else None,
                "client_meal_id": client_meal_id,
                "name": name,
                "meal_type": meal_type,
                "items": items,
                "totals": totals,
                "confidence": confidence,
                "logged_at": logged_at.isoformat(),
            },
        )

    async def insert_correction(
        self,
        *,
        meal_log_id: str,
        item_index: int,
        field: str,
        parsed_value: Any,
        confirmed_value: Any,
    ) -> None:
        await self._db.insert(
            "corrections",
            {
                "id": str(uuid4()),
                "meal_log_id": meal_log_id,
                "item_index": item_index,
                "field": field,
                "parsed_value": parsed_value,
                "confirmed_value": confirmed_value,
            },
        )

    async def count_corrections(self, meal_log_id: str) -> int:
        # A Settings "Forget" appends a name_forget row on the meal the rename was learned
        # from (the audit trail needs a parent); it is not an edit the person made to that meal.
        rows = await self._db.select("corrections", {"meal_log_id": meal_log_id})
        return len([row for row in rows if row.get("field") != FORGET_FIELD])

    async def name_corrections(self, user_id: UUID) -> list[dict[str, Any]]:
        """Every name-teaching row across the user's meals (one owner-scoped query per field)."""
        rows: list[dict[str, Any]] = []
        for field in (NAME_FIELD, FORGET_FIELD):
            rows.extend(
                await self._db.select_owned_via(
                    "corrections",
                    parent_table="meal_logs",
                    parent_key="meal_log_id",
                    user_id=user_id,
                    filters={"field": field},
                )
            )
        return rows

    async def list_between(
        self, user_id: UUID, start: datetime, end: datetime
    ) -> list[dict[str, Any]]:
        """Live meals with ``logged_at`` in [start, end), oldest first, filtered and ordered
        by the database: a day view never pulls the user's whole history (findings F6)."""
        return await self._db.select(
            "meal_logs",
            user_id=user_id,
            where=[
                ("logged_at", "gte", start.isoformat()),
                ("logged_at", "lt", end.isoformat()),
                ("deleted_at", "is_null", None),
            ],
            order_by="logged_at",
        )

    async def get(self, meal_id: UUID, user_id: UUID) -> dict[str, Any] | None:
        rows = await self._db.select("meal_logs", {"id": str(meal_id)}, user_id=user_id)
        return rows[0] if rows else None

    async def update_items(
        self,
        meal_id: UUID,
        user_id: UUID,
        *,
        items: list[dict[str, Any]],
        totals: dict[str, Any],
        confidence: float,
        name: str | None,
        meal_type: str,
    ) -> dict[str, Any] | None:
        """Replace a meal's items/totals after an edit (meal_logs are mutable). Owner-scoped."""
        updated = await self._db.update(
            "meal_logs",
            {"id": str(meal_id)},
            {
                "items": items,
                "totals": totals,
                "confidence": confidence,
                "name": name,
                "meal_type": meal_type,
            },
            user_id=user_id,
        )
        return updated[0] if updated else None

    async def tombstone(self, meal_id: UUID, user_id: UUID, *, when: datetime) -> bool:
        updated = await self._db.update(
            "meal_logs",
            {"id": str(meal_id)},
            {"deleted_at": when.isoformat()},
            user_id=user_id,
        )
        return bool(updated)

    async def list_deleted(self, user_id: UUID, *, since: datetime) -> list[dict[str, Any]]:
        """Tombstoned meals deleted at or after ``since``, newest deletion first. Owner-scoped."""
        return await self._db.select(
            "meal_logs",
            user_id=user_id,
            where=[("deleted_at", "gte", since.isoformat())],
            order_by="deleted_at",
            descending=True,
        )

    async def restore(self, meal_id: UUID, user_id: UUID) -> dict[str, Any] | None:
        """Clear an owned tombstone; the row never left, so items, totals and corrections come
        back exactly as they were. None when nothing owned and deleted matched. Raises
        ``UniqueViolationError`` when an outbox replay re-logged the same client_meal_id
        while this one was deleted (the partial unique index admits one live copy)."""
        row = await self.get(meal_id, user_id)
        if row is None or not row.get("deleted_at"):
            return None
        updated = await self._db.update(
            "meal_logs", {"id": str(meal_id)}, {"deleted_at": None}, user_id=user_id
        )
        return updated[0] if updated else None

    async def purge_tombstones(self, *, older_than: datetime, dry_run: bool = False) -> int:
        """Hard-delete every meal tombstoned before ``older_than`` (with its corrections, as
        the FK cascade would). A service-role sweep over every user, reached only through the
        admin-gated, audited endpoint. Returns the count; ``dry_run`` counts without deleting."""
        doomed = await self._db.select(
            "meal_logs", where=[("deleted_at", "lt", older_than.isoformat())]
        )
        if dry_run:
            return len(doomed)
        purged = 0
        for row in doomed:
            await self._db.delete("corrections", {"meal_log_id": row["id"]})
            purged += await self._db.delete("meal_logs", {"id": row["id"]})
        return purged

    async def insert_saved_meal(
        self,
        *,
        user_id: UUID,
        name: str,
        items: list[dict[str, Any]],
        totals: dict[str, Any],
    ) -> dict[str, Any]:
        return await self._db.insert(
            "saved_meals",
            {
                "id": str(uuid4()),
                "user_id": str(user_id),
                "name": name,
                "items": items,
                "totals": totals,
            },
        )

    async def list_saved_meals(self, user_id: UUID) -> list[dict[str, Any]]:
        """The user's "usuals", newest first. Owner-scoped."""
        rows = await self._db.select("saved_meals", user_id=user_id)
        rows.sort(key=_created_at_key, reverse=True)
        return rows

    async def delete_saved_meal(self, saved_meal_id: UUID, user_id: UUID) -> bool:
        """Hard-delete a "usual"; False when nothing owned matched.

        A real DELETE, not a tombstone: saved_meals is a mutable TEMPLATE table (its RLS
        grants owner DELETE), and a template is a user shortcut, not a capture — the
        append-only immutability rule covers captures/transcripts/parses/corrections. Meals
        already logged FROM this template are untouched durable rows.
        """
        removed = await self._db.delete(
            "saved_meals", {"id": str(saved_meal_id)}, user_id=user_id
        )
        return removed > 0


class WaterStore:
    """Durable-truth access for the day's water tally.

    Water lives in its own ``water_logs`` table rather than as a ``kind='water'``
    marker on ``meal_logs`` (which requires non-null ``items``/``totals`` and is
    keyed for the macro/produce aggregation): a separate append-only table is the
    lean option — one row per logged amount, owner-scoped, summed for /today.
    Idempotent by ``client_water_id`` so outbox/offline replays converge (RT-13);
    see supabase/migrations for the column + partial unique index.
    """

    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    @staticmethod
    def _missing_dedup_column(exc: Exception) -> bool:
        # Deploy-ahead-of-migration resilience (mirrors captures/store.py content_type):
        # client_water_id shipped in migration 20260625; a hosted DB that hasn't been
        # migrated raises 42703/PGRST204 on every water write, and the tile swallowed it —
        # water logging was dead in prod for weeks (field bug 2026-07). Losing the DEDUP
        # column must degrade to losing dedup, never to losing the user's water.
        msg = str(exc)
        return "client_water_id" in msg and (
            "PGRST204" in msg or "42703" in msg or "column" in msg.lower()
        )

    async def get_by_client_id(
        self, user_id: UUID, client_water_id: str
    ) -> dict[str, Any] | None:
        try:
            rows = await self._db.select(
                "water_logs", {"client_water_id": client_water_id}, user_id=user_id
            )
        except Exception as exc:
            if self._missing_dedup_column(exc):
                return None  # pre-migration DB: no dedup lookup possible
            raise
        return rows[0] if rows else None

    async def add(
        self, *, user_id: UUID, client_water_id: str, amount_oz: float, logged_at: datetime
    ) -> dict[str, Any]:
        row = {
            "id": str(uuid4()),
            "user_id": str(user_id),
            "client_water_id": client_water_id,
            "amount_oz": amount_oz,
            "logged_at": logged_at.isoformat(),
        }
        try:
            return await self._db.insert("water_logs", row)
        except Exception as exc:
            if self._missing_dedup_column(exc):
                row.pop("client_water_id", None)
                return await self._db.insert("water_logs", row)
            raise

    async def total_between(self, user_id: UUID, start: datetime, end: datetime) -> float:
        rows = await self._db.select(
            "water_logs",
            user_id=user_id,
            where=[("logged_at", "gte", start.isoformat()), ("logged_at", "lt", end.isoformat())],
        )
        return round(sum(float(row["amount_oz"]) for row in rows), 1)


def _parse_dt(value: str) -> datetime:
    return datetime.fromisoformat(value)


def _created_at_key(row: dict[str, Any]) -> datetime:
    """Sort key for newest-first listings; an unreadable timestamp sorts oldest.

    ``created_at`` is NOT NULL DEFAULT now(), so this guards a hand-seeded row rather
    than a real gap — and it normalizes a naive value to UTC, because Python refuses to
    compare naive against aware and one odd row would TypeError the whole listing.
    """
    raw = row.get("created_at")
    try:
        parsed = _parse_dt(raw) if isinstance(raw, str) else None
    except ValueError:
        parsed = None
    if parsed is None:
        return datetime.min.replace(tzinfo=UTC)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)
