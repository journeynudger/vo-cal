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
        """The user's most recent intake row, or None. The per-user set is tiny, so we pick
        the max version in-process rather than rely on DB ordering (works on the Fake too)."""
        rows = await self._db.select("intake_responses", {}, user_id=user_id)
        return max(rows, key=lambda r: int(r["version"])) if rows else None

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
