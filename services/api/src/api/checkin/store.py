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
        rows = await self._db.select("checkins", user_id=user_id)
        if not rows:
            return None
        rows.sort(key=lambda r: r.get("created_at") or "", reverse=True)
        return rows[0]

    async def list_for_user(self, user_id: UUID) -> list[dict[str, Any]]:
        rows = await self._db.select("checkins", user_id=user_id)
        rows.sort(key=lambda r: r.get("created_at") or "", reverse=True)
        return rows

    async def meal_logs_between(
        self, user_id: UUID, start: datetime, end: datetime
    ) -> list[dict[str, Any]]:
        """Owner-scoped live meal_logs with ``logged_at`` in [start, end)."""
        rows = await self._db.select("meal_logs", user_id=user_id)
        out: list[dict[str, Any]] = []
        for row in rows:
            if row.get("deleted_at"):
                continue
            logged_at = row.get("logged_at")
            if not logged_at:
                continue
            logged = datetime.fromisoformat(logged_at)
            if start <= logged < end:
                out.append(row)
        out.sort(key=lambda r: r["logged_at"])
        return out
