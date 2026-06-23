"""Transcription step — capture audio -> transcript text, provider-injectable.

The Database-seam pattern applied to speech-to-text (the same shape as the parser's
LLM seam):

- ``ElevenLabsTranscriber`` — real ElevenLabs Scribe. ``POST /v1/speech-to-text``,
  ``model_id=scribe_v1``, multipart ``file``. Verified live 2026-06-23: returns
  ``{text, language_code, words[], transcription_id, audio_duration_secs}``. The
  async httpx client is injectable; production builds it from ``settings``.
- ``FakeTranscriber`` — a deterministic offline transcript. The entire offline
  suite (and any local dev with no key) runs through this, zero network.

Decision (2026-06-23): server-side ElevenLabs Scribe, reversing the C5 scope-cut
to on-device transcription (decision #24). The key stays server-side — it never
ships in the app. This realigns with the original MASTER-PLAN transcription
architecture. Audio remains the immutable ground truth; a transcription failure
is never a capture failure (the route maps provider errors to 502 and never
mutates the capture row).

AGENTS.md #6 stays intact: STT extracts words; it computes no nutrition numbers.
"""

from __future__ import annotations

import logging
from typing import Any, Protocol

from ..config import settings

logger = logging.getLogger(__name__)

ELEVENLABS_STT_URL = "https://api.elevenlabs.io/v1/speech-to-text"
DEFAULT_STT_MODEL = "scribe_v1"


class TranscriptionError(Exception):
    """The STT provider could not produce a transcript (transient or permanent)."""


class TranscriptionResult:
    """A transcript plus the provider + light metadata that produced it."""

    def __init__(
        self,
        text: str,
        *,
        provider: str,
        language_code: str | None = None,
        duration_ms: int | None = None,
    ) -> None:
        self.text = text
        self.provider = provider
        self.language_code = language_code
        self.duration_ms = duration_ms


class Transcriber(Protocol):
    """The seam: turn audio bytes into a transcript."""

    provider: str

    async def transcribe(
        self, audio: bytes, *, content_type: str = "audio/x-caf"
    ) -> TranscriptionResult: ...


class FakeTranscriber:
    """Deterministic offline transcript — the offline STT.

    Returns a fixed, contract-realistic transcript so the suite exercises the
    full /transcribe -> transcripts-row flow without any network.
    """

    provider = "fake"

    def __init__(self, text: str = "some chicken and some rice") -> None:
        # Default matches a recorded parser fixture so the offline
        # transcribe -> parse chain resolves end-to-end with zero network.
        self._text = text

    async def transcribe(
        self, audio: bytes, *, content_type: str = "audio/x-caf"
    ) -> TranscriptionResult:
        del content_type
        if not audio:
            raise TranscriptionError("empty audio")
        return TranscriptionResult(self._text, provider=self.provider, language_code="eng")


class ElevenLabsTranscriber:
    """Real ElevenLabs Scribe client (httpx multipart)."""

    provider = "elevenlabs"

    def __init__(
        self,
        *,
        model: str | None = None,
        client: Any | None = None,
        timeout: float = 60.0,
    ) -> None:
        self._model = model or DEFAULT_STT_MODEL
        self._client = client  # injectable async httpx client; lazily built if None
        self._timeout = timeout

    def _ensure_client(self) -> Any:
        if self._client is None:
            import httpx  # noqa: PLC0415  (lazy: only the live path needs it)

            self._client = httpx.AsyncClient(timeout=self._timeout)
        return self._client

    async def transcribe(
        self, audio: bytes, *, content_type: str = "audio/x-caf"
    ) -> TranscriptionResult:
        if not audio:
            raise TranscriptionError("empty audio")
        client = self._ensure_client()
        try:
            resp = await client.post(
                ELEVENLABS_STT_URL,
                headers={"xi-api-key": settings.elevenlabs_api_key},
                data={"model_id": self._model},
                files={"file": ("capture", audio, content_type)},
            )
        except Exception as exc:  # network / timeout — transient
            raise TranscriptionError(f"elevenlabs request failed: {exc}") from exc

        if resp.status_code != 200:
            # 4xx (bad audio/permissions) and 5xx (provider) both surface as a
            # provider error; the route returns 502 and leaves the capture intact.
            raise TranscriptionError(f"elevenlabs {resp.status_code}: {resp.text[:200]}")

        body = resp.json()
        text = (body.get("text") or "").strip()
        if not text:
            raise TranscriptionError("elevenlabs returned an empty transcript")
        duration = body.get("audio_duration_secs")
        duration_ms = int(duration * 1000) if isinstance(duration, (int, float)) else None
        return TranscriptionResult(
            text,
            provider=self.provider,
            language_code=body.get("language_code"),
            duration_ms=duration_ms,
        )
