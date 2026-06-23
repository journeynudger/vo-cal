"""Transcribe API: a durably-uploaded capture -> an immutable transcript.

Flow (server-side ElevenLabs Scribe, decision 2026-06-23 reversing #24):
  /captures (audio durable)  ->  POST /transcribe {capture_id}  ->  /parse {transcript_id}

The route is orchestration only: it authorizes the capture (owner scope), reads
the ground-truth blob, hands bytes to the injected transcriber, and persists the
immutable transcripts row. The provider lives behind the ``Transcriber`` seam, so
the offline suite runs through ``FakeTranscriber`` with zero network — exactly the
parser's posture. A transcription failure (502) never mutates the capture: audio
is the ground truth and re-transcription is always possible.
"""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Form, HTTPException, status

from ..captures.store import CapturesStore
from ..config import settings
from ..dependencies import CurrentUser, Db, Storage
from ..storage import CAPTURE_AUDIO_BUCKET
from .elevenlabs import (
    ElevenLabsTranscriber,
    FakeTranscriber,
    Transcriber,
    TranscriptionError,
)
from .schemas import TranscriptResult
from .store import TranscriptsStore


def get_transcriber() -> Transcriber:
    """Live ElevenLabs Scribe in production; the offline fake under test or no key.

    test_mode is always offline (recorded fake), regardless of any real key in a
    local .env — mirrors get_parser_client so tests never reach a live provider.
    """
    if settings.test_mode:
        return FakeTranscriber()
    if settings.elevenlabs_api_key:
        return ElevenLabsTranscriber()
    return FakeTranscriber()


TranscriberDep = Annotated[Transcriber, Depends(get_transcriber)]

router = APIRouter(prefix="/transcribe", tags=["transcribe"])


@router.post("", response_model=TranscriptResult)
async def transcribe(
    user_id: CurrentUser,
    db: Db,
    storage: Storage,
    transcriber: TranscriberDep,
    capture_id: Annotated[UUID, Form()],
) -> TranscriptResult:
    capture = await CapturesStore(db).get(capture_id, user_id)
    if capture is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "capture not found")

    audio_path = capture.get("audio_path")
    if not audio_path:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "capture has no audio")

    audio = await storage.get(CAPTURE_AUDIO_BUCKET, audio_path)
    if not audio:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "audio blob missing")

    try:
        result = await transcriber.transcribe(
            audio, content_type=capture.get("content_type") or "audio/x-caf"
        )
    except TranscriptionError as exc:
        # Provider failure — capture stays intact, retry remains possible (VALUES rule).
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY, f"transcription failed: {exc}"
        ) from exc

    row = await TranscriptsStore(db).insert(
        capture_id=capture_id, provider=result.provider, text=result.text
    )
    return TranscriptResult(
        transcript_id=row["id"],
        capture_id=capture_id,
        text=result.text,
        provider=result.provider,
        language_code=result.language_code,
        duration_ms=result.duration_ms,
    )
