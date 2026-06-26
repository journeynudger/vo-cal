"""/transcribe tests (offline — FakeStorage + FakeDatabase + FakeTranscriber).

Covers the route flow (capture -> immutable transcript), owner scoping, and the
real ElevenLabsTranscriber's response/error handling via an injected fake httpx
client (no network). A transcription failure must never mutate the capture.
"""

from __future__ import annotations

import pytest

from api.transcribe.elevenlabs import ElevenLabsTranscriber, TranscriptionError

CAF = b"caf-bytes-pretend-audio" * 100


def _upload(client, headers, *, cid="cap-1", data=CAF):
    return client.post(
        "/captures",
        files={"audio": ("voice.caf", data, "audio/x-caf")},
        data={"client_capture_id": cid, "duration_ms": "4200", "device": "sim"},
        headers=headers,
    )


def _transcribe(client, headers, capture_id):
    return client.post("/transcribe", data={"capture_id": capture_id}, headers=headers)


def _upload_m4a(client, headers, *, cid):
    return client.post(
        "/captures",
        files={"audio": ("voice.m4a", CAF, "audio/mp4")},
        data={"client_capture_id": cid},
        headers=headers,
    )


# ---- RT-42: real content type is persisted and used for transcription -------


def test_upload_persists_content_type(client, auth_headers, fake_db):
    # RT-42: the real upload content type must be stored on the capture so transcription
    # doesn't treat every blob as audio/x-caf regardless of the true format.
    _upload_m4a(client, auth_headers, cid="ct-1")
    assert fake_db.tables["captures"][0]["content_type"] == "audio/mp4"


def test_transcribe_uses_real_content_type(client, auth_headers, monkeypatch):
    from api.transcribe import elevenlabs

    seen: dict[str, str] = {}
    real = elevenlabs.FakeTranscriber.transcribe

    async def spy(self, audio, *, content_type="audio/x-caf"):
        seen["content_type"] = content_type
        return await real(self, audio, content_type=content_type)

    monkeypatch.setattr(elevenlabs.FakeTranscriber, "transcribe", spy)
    cid = _upload_m4a(client, auth_headers, cid="ct-2").json()["id"]
    _transcribe(client, auth_headers, cid)
    assert seen["content_type"] == "audio/mp4"  # not the audio/x-caf default


# ---- route flow -------------------------------------------------------------


def test_transcribe_requires_auth(client):
    assert _transcribe(client, {}, "11111111-1111-1111-1111-111111111111").status_code == 401


def test_transcribe_happy_path_writes_immutable_transcript(client, auth_headers, fake_db):
    capture_id = _upload(client, auth_headers, cid="t-1").json()["id"]
    resp = _transcribe(client, auth_headers, capture_id)
    assert resp.status_code == 200
    body = resp.json()
    assert body["capture_id"] == capture_id
    assert body["provider"] == "fake"
    assert "chicken" in body["text"]
    assert body["transcript_id"]
    # an immutable transcripts row landed, scoped to the capture
    rows = fake_db.tables["transcripts"]
    assert len(rows) == 1
    assert rows[0]["capture_id"] == capture_id


def test_transcribe_feeds_parse(client, auth_headers):
    capture_id = _upload(client, auth_headers, cid="t-parse").json()["id"]
    t = _transcribe(client, auth_headers, capture_id).json()
    # the transcript text + provenance ids flow straight into /parse
    parsed = client.post(
        "/parse",
        json={
            "transcript": t["text"],
            "capture_id": capture_id,
            "transcript_id": t["transcript_id"],
        },
        headers=auth_headers,
    )
    assert parsed.status_code == 200
    assert parsed.json()["items"]


def test_transcribe_unknown_capture_404(client, auth_headers):
    assert _transcribe(
        client, auth_headers, "99999999-9999-9999-9999-999999999999"
    ).status_code == 404


def test_transcribe_scoped_per_user(client, auth_headers, auth_headers_user_2):
    capture_id = _upload(client, auth_headers, cid="t-owned").json()["id"]
    # user 2 cannot transcribe user 1's capture, and no transcript leaks out
    resp = _transcribe(client, auth_headers_user_2, capture_id)
    assert resp.status_code == 404


# ---- real ElevenLabs client logic (offline, injected fake httpx) ------------


class _FakeResponse:
    def __init__(self, status_code, payload=None, text=""):
        self.status_code = status_code
        self._payload = payload or {}
        self.text = text

    def json(self):
        return self._payload


class _FakeHttpx:
    def __init__(self, response):
        self._response = response
        self.calls: list[dict] = []

    async def post(self, url, *, headers, data, files):
        self.calls.append({"url": url, "headers": headers, "data": data, "files": files})
        return self._response


async def test_elevenlabs_parses_scribe_response():
    http = _FakeHttpx(
        _FakeResponse(
            200,
            {
                "text": "two eggs and toast",
                "language_code": "eng",
                "audio_duration_secs": 3.5,
            },
        )
    )
    out = await ElevenLabsTranscriber(client=http).transcribe(b"audio", content_type="audio/wav")
    assert out.text == "two eggs and toast"
    assert out.provider == "elevenlabs"
    assert out.language_code == "eng"
    assert out.duration_ms == 3500
    # forced the contract: scribe model + the audio file part
    assert http.calls[0]["data"]["model_id"] == "scribe_v1"
    assert http.calls[0]["files"]["file"][2] == "audio/wav"


async def test_elevenlabs_maps_non_200_to_error():
    http = _FakeHttpx(_FakeResponse(401, text="missing_permissions"))
    with pytest.raises(TranscriptionError):
        await ElevenLabsTranscriber(client=http).transcribe(b"audio")


async def test_elevenlabs_rejects_empty_transcript():
    http = _FakeHttpx(_FakeResponse(200, {"text": "   "}))
    with pytest.raises(TranscriptionError):
        await ElevenLabsTranscriber(client=http).transcribe(b"audio")


async def test_elevenlabs_rejects_empty_audio():
    with pytest.raises(TranscriptionError):
        await ElevenLabsTranscriber(client=_FakeHttpx(_FakeResponse(200))).transcribe(b"")
