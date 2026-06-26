"""Durable-truth access for: captures.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). Captures are immutable after commit
(append-only ground-truth audio records).
"""

from __future__ import annotations

from typing import Any
from uuid import UUID, uuid4

from ..db import SupportsDatabase


class CapturesStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def get_by_client_id(
        self, user_id: UUID, client_capture_id: str
    ) -> dict[str, Any] | None:
        rows = await self._db.select(
            "captures", {"client_capture_id": client_capture_id}, user_id=user_id
        )
        return rows[0] if rows else None

    async def insert(
        self,
        *,
        user_id: UUID,
        client_capture_id: str,
        audio_path: str,
        duration_ms: int | None,
        device: str | None,
        content_type: str | None = None,
        status: str = "uploaded",
    ) -> dict[str, Any]:
        return await self._db.insert(
            "captures",
            {
                "id": str(uuid4()),
                "user_id": str(user_id),
                "client_capture_id": client_capture_id,
                "audio_path": audio_path,
                "duration_ms": duration_ms,
                "device": device,
                # Persist the real upload format so transcription uses it instead of
                # assuming audio/x-caf for every blob (RT-42).
                "content_type": content_type,
                "status": status,
            },
        )

    async def get(self, capture_id: UUID, user_id: UUID) -> dict[str, Any] | None:
        rows = await self._db.select("captures", {"id": str(capture_id)}, user_id=user_id)
        return rows[0] if rows else None
