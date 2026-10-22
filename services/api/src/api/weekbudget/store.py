"""Durable-truth access for: week_plans.

Stores answer "what is durably true?" — no planning, no side effects beyond the
database (AGENTS.md, deep couplings). Week plans are append-only and versioned
like intake_responses: a re-plan writes a new row with the next version for the
same (user, week_start); rows are never mutated. The latest version wins.
"""

from __future__ import annotations

from datetime import date
from typing import Any
from uuid import UUID, uuid4

from ..db import SupportsDatabase


class WeekPlansStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def latest(self, user_id: UUID, week_start: date) -> dict[str, Any] | None:
        """The most recent plan row for (user, week_start), or None: the newest version, one
        row (a read of every version maxed in Python loses the newest past PostgREST's cap)."""
        rows = await self._db.select(
            "week_plans", {"week_start": week_start.isoformat()}, user_id=user_id,
            order_by="version", descending=True, limit=1,
        )
        return rows[0] if rows else None

    async def insert(
        self, *, user_id: UUID, week_start: date, allocations: dict[str, int]
    ) -> dict[str, Any]:
        """Append the next plan version for (user, week_start) — v1 first time,
        vN+1 after. ``allocations`` maps all 7 ISO dates of the week to whole
        kcal (the router freezes past days before calling)."""
        previous = await self.latest(user_id, week_start)
        version = int(previous["version"]) + 1 if previous else 1
        return await self._db.insert(
            "week_plans",
            {
                "id": str(uuid4()),
                "user_id": str(user_id),
                "week_start": week_start.isoformat(),
                "version": version,
                "allocations": allocations,
            },
        )
