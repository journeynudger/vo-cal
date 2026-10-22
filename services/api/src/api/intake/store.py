"""Durable-truth access for: intake_responses.

Stores answer "what is durably true?" — no planning, no side effects beyond the
database (AGENTS.md, deep couplings). Intake is append-only and versioned: a
re-intake writes a new row with the next version; rows are never mutated.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID, uuid4

from ..db import SupportsDatabase


class IntakeStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def latest(self, user_id: UUID) -> dict[str, Any] | None:
        """The user's most recent intake row, or None: the newest version, one row (a read of
        every version maxed in Python loses the newest past PostgREST's 1000-row cap)."""
        rows = await self._db.select(
            "intake_responses", {}, user_id=user_id, order_by="version", descending=True, limit=1
        )
        return rows[0] if rows else None

    async def insert(self, *, user_id: UUID, answers: dict[str, Any]) -> dict[str, Any]:
        """Append the next intake version for the user (v1 first time, vN+1 after)."""
        previous = await self.latest(user_id)
        version = int(previous["version"]) + 1 if previous else 1
        return await self._db.insert(
            "intake_responses",
            {
                "id": str(uuid4()),
                "user_id": str(user_id),
                "version": version,
                "answers": answers,
            },
        )
