"""Durable-truth access for: checkins (Phase G — mid-week nudging).

Stores answer "what is durably true?" — no planning, no side effects beyond the
database (AGENTS.md, deep couplings). The nudge/recalibration *decisions* live in
nudge.py / recommend.py; this store only reads and writes rows. ``checkins`` is
mutable (``accepted`` is set after a recommendation is shown), per the migration.

The logging-signal reads here go against ``meal_logs`` (owner-scoped, same as the
meals store) so the nudge engine has deterministic inputs without reaching across
package boundaries into another agent's store.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

from ..db import SupportsDatabase
from ..meals.store import MealsStore


class CheckinStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def insert(
        self,
        *,
        user_id: UUID,
        weight_kg: float | None,
        hunger: int | None,
        energy: int | None,
        adherence_self: int | None,
        notes: str | None,
        computed: dict[str, Any] | None = None,
        recommendation: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return await self._db.insert(
            "checkins",
            {
                "id": str(uuid4()),
                "user_id": str(user_id),
                "weight_kg": weight_kg,
                "hunger": hunger,
                "energy": energy,
                "adherence_self": adherence_self,
                "notes": notes,
                "computed": computed,
                "recommendation": recommendation,
                "accepted": None,
            },
        )

    async def latest(self, user_id: UUID) -> dict[str, Any] | None:
        """The user's most recent check-in by created_at, or None."""
        rows = await self.list_recent(user_id, limit=1)
        return rows[0] if rows else None

    async def list_recent(self, user_id: UUID, limit: int = 52) -> list[dict[str, Any]]:
        """Newest-first check-in history, capped by the database — the weight-trend read."""
        return await self._db.select(
            "checkins", user_id=user_id, order_by="created_at", descending=True, limit=limit
        )

    async def meal_logs_between(
        self, user_id: UUID, start: datetime, end: datetime
    ) -> list[dict[str, Any]]:
        """Owner-scoped live meal_logs with ``logged_at`` in [start, end): the meals store's
        read, not a second copy of it."""
        return await MealsStore(self._db).list_between(user_id, start, end)
