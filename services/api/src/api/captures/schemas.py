"""Schemas for the captures domain: the audio-upload response + status.

The audio blob arrives as multipart (UploadFile + form fields), so the request
isn't a Pydantic body model — these are the response shapes.
"""

from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel


class CaptureStatus(BaseModel):
    id: UUID
    client_capture_id: str
    status: str
    duration_ms: int | None = None
    # Already uploaded? (idempotent replay returns the existing capture.)
    deduped: bool = False
