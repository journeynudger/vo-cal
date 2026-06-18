"""Durable-truth access for: parses.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). Parses are immutable: a refine appends
a new row with ``supersedes`` pointing at the original; rows are never mutated.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from ..db import SupportsDatabase


class ParsesStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def insert(
        self,
        *,
        parse_id: UUID,
        user_id: UUID,
        payload: dict[str, Any],
        model: str,
        prompt_version: str,
        capture_id: UUID | None = None,
        transcript_id: UUID | None = None,
        supersedes: UUID | None = None,
    ) -> dict[str, Any]:
        return await self._db.insert(
            "parses",
            {
                "id": str(parse_id),
                "user_id": str(user_id),
                "capture_id": str(capture_id) if capture_id else None,
                "transcript_id": str(transcript_id) if transcript_id else None,
                "supersedes": str(supersedes) if supersedes else None,
                "payload": payload,
                "model": model,
                "prompt_version": prompt_version,
            },
        )

    async def get(self, parse_id: UUID, user_id: UUID) -> dict[str, Any] | None:
        rows = await self._db.select("parses", {"id": str(parse_id)}, user_id=user_id)
        return rows[0] if rows else None
