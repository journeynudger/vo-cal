"""Durable-truth access for: personal_foods.

Versioned, never rewritten: saving a name the person already has retires the old row
(``retired_at``) and inserts the new one, so a meal logged last month keeps the identity it
was priced with (the identity is persisted on the meal's items) while the next parse uses
the new numbers. The partial unique index (user, name_key) WHERE retired_at IS NULL holds one
live row per name; FakeDatabase mirrors it (db.py _UNIQUE_INDEXES).
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from uuid import UUID, uuid4

from ..db import SupportsDatabase
from ..nutrition.dictionary import normalize_name


class PersonalFoodsStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def list_active(self, user_id: UUID) -> list[dict[str, Any]]:
        return await self._db.select(
            "personal_foods",
            user_id=user_id,
            where=[("retired_at", "is_null", None)],
            order_by="created_at",
            descending=True,
        )

    async def get_active(self, food_id: UUID, user_id: UUID) -> dict[str, Any] | None:
        rows = await self._db.select("personal_foods", {"id": str(food_id)}, user_id=user_id)
        row = rows[0] if rows else None
        return row if row is not None and not row.get("retired_at") else None

    async def insert(
        self,
        *,
        user_id: UUID,
        name: str,
        aliases: list[str],
        per_serving: dict[str, Any],
        serving_grams: float | None,
        servings_per_package: float | None,
        source: str,
        provenance: dict[str, Any] | None,
    ) -> dict[str, Any]:
        return await self._db.insert(
            "personal_foods",
            {
                "id": str(uuid4()),
                "user_id": str(user_id),
                "name": name,
                "name_key": normalize_name(name),
                "aliases": aliases,
                "per_serving": per_serving,
                "serving_grams": serving_grams,
                "servings_per_package": servings_per_package,
                "source": source,
                "provenance": provenance,
                "retired_at": None,
            },
        )

    async def retire_by_name(self, user_id: UUID, name: str, *, when: datetime) -> int:
        """Retire the live row with this name, if any (the versioning step before an insert)."""
        rows = await self._db.select(
            "personal_foods",
            {"name_key": normalize_name(name)},
            user_id=user_id,
            where=[("retired_at", "is_null", None)],
        )
        for row in rows:
            await self._db.update(
                "personal_foods", {"id": row["id"]}, {"retired_at": when.isoformat()}, user_id=user_id
            )
        return len(rows)

    async def retire(self, food_id: UUID, user_id: UUID) -> bool:
        row = await self.get_active(food_id, user_id)
        if row is None:
            return False
        await self._db.update(
            "personal_foods",
            {"id": str(food_id)},
            {"retired_at": datetime.now(UTC).isoformat()},
            user_id=user_id,
        )
        return True
