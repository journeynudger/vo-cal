"""Durable-truth access for: meal_logs, corrections, saved_meals.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). meal_logs are mutable (edits, soft
delete via deleted_at); corrections are append-only; saved_meals are templates.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

from ..db import SupportsDatabase


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
        rows = await self._db.select("corrections", {"meal_log_id": meal_log_id})
        return len(rows)

    async def list_between(
        self, user_id: UUID, start: datetime, end: datetime
    ) -> list[dict[str, Any]]:
        rows = await self._db.select("meal_logs", user_id=user_id)
        out = []
        for row in rows:
            if row.get("deleted_at"):
                continue
            logged = _parse_dt(row["logged_at"])
            if start <= logged < end:
                out.append(row)
        out.sort(key=lambda r: r["logged_at"])
        return out

    async def get(self, meal_id: UUID, user_id: UUID) -> dict[str, Any] | None:
        rows = await self._db.select("meal_logs", {"id": str(meal_id)}, user_id=user_id)
        return rows[0] if rows else None

    async def tombstone(self, meal_id: UUID, user_id: UUID, *, when: datetime) -> bool:
        updated = await self._db.update(
            "meal_logs",
            {"id": str(meal_id)},
            {"deleted_at": when.isoformat()},
            user_id=user_id,
        )
        return bool(updated)

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


class WaterStore:
    """Durable-truth access for the day's water tally.

    Water lives in its own ``water_logs`` table rather than as a ``kind='water'``
    marker on ``meal_logs`` (which requires non-null ``items``/``totals`` and is
    keyed for the macro/produce aggregation): a separate append-only table is the
    lean option — one row per logged amount, owner-scoped, summed for /today. The
    table is not yet in the migration; offline tests run against FakeDatabase
    (schema-less). See report: parent must add the migration for the live path.
    """

    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def add(self, *, user_id: UUID, amount_oz: float, logged_at: datetime) -> dict[str, Any]:
        return await self._db.insert(
            "water_logs",
            {
                "id": str(uuid4()),
                "user_id": str(user_id),
                "amount_oz": amount_oz,
                "logged_at": logged_at.isoformat(),
            },
        )

    async def total_between(self, user_id: UUID, start: datetime, end: datetime) -> float:
        rows = await self._db.select("water_logs", user_id=user_id)
        total = 0.0
        for row in rows:
            logged = _parse_dt(row["logged_at"])
            if start <= logged < end:
                total += float(row["amount_oz"])
        return round(total, 1)


def _parse_dt(value: str) -> datetime:
    return datetime.fromisoformat(value)
