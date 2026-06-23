"""Durable-truth access for: transcripts.

Stores answer "what is durably true?" — no planning, no side effects beyond the
database (AGENTS.md, deep couplings). Transcripts are immutable: re-transcription
appends a new row (never mutated). The table has no ``user_id`` column — ownership
is scoped through ``capture_id`` -> captures.user_id, so the route verifies the
capture belongs to the caller BEFORE inserting/reading a transcript.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID, uuid4

from ..db import SupportsDatabase


class TranscriptsStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def insert(self, *, capture_id: UUID, provider: str, text: str) -> dict[str, Any]:
        return await self._db.insert(
            "transcripts",
            {
                "id": str(uuid4()),
                "capture_id": str(capture_id),
                "provider": provider,
                "text": text,
            },
        )

    async def get(self, transcript_id: UUID) -> dict[str, Any] | None:
        # No user scope here: transcripts carry no owner column. Callers must have
        # already authorized via the parent capture.
        rows = await self._db.select("transcripts", {"id": str(transcript_id)})
        return rows[0] if rows else None
