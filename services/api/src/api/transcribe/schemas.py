"""Transcribe API response contract."""

from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel


class TranscriptResult(BaseModel):
    """The immutable transcript produced for a capture, returned to the client.

    `transcript_id` is then passed to /parse so the parse row carries provenance
    back to the capture and transcript (AGENTS.md #5: derived artifacts reference
    the ground-truth audio).
    """

    transcript_id: UUID
    capture_id: UUID
    text: str
    provider: str
    language_code: str | None = None
    duration_ms: int | None = None
