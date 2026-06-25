"""Captures API (C4): durable audio upload — the ground-truth/audit artifact.

With on-device transcription (decision #24) the result loop runs through /parse;
this endpoint exists so the spoken audio is durably stored for the admin audit
trail and possible later re-transcription. Audio is the ground truth.

The server acknowledges ``uploaded`` only after the blob is durably in storage
AND the immutable captures row is committed (Serein data-plane rule). Idempotent
by client_capture_id so outbox/offline retries are safe.
"""

from __future__ import annotations

import re
from uuid import UUID

from fastapi import APIRouter, File, Form, HTTPException, UploadFile, status

from ..dependencies import CurrentUser, Db, Storage
from ..storage import CAPTURE_AUDIO_BUCKET
from .schemas import CaptureStatus
from .store import CapturesStore

router = APIRouter(prefix="/captures", tags=["captures"])

# 50 MB hard cap (INVARIANTS resource bounds: a single payload is bounded).
_MAX_AUDIO_BYTES = 50 * 1024 * 1024

# Safe client_capture_id charset — no path separators/traversal (it becomes part of the
# storage object key; account deletion relies on the per-user "{user_id}/" prefix).
# Must START with an alphanumeric so dot/dash-only ids (".", "..", "--") — which make odd or
# empty-looking storage keys — are rejected; real ids (e.g. "voice_<ts>_<hex>") start with one.
_SAFE_CLIENT_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")


@router.post("", response_model=CaptureStatus, status_code=status.HTTP_201_CREATED)
async def upload_capture(
    user_id: CurrentUser,
    db: Db,
    storage: Storage,
    audio: UploadFile = File(...),
    client_capture_id: str = Form(...),
    duration_ms: int | None = Form(default=None),
    device: str | None = Form(default=None),
) -> CaptureStatus:
    # client_capture_id is interpolated into the storage key (f"{user_id}/{id}.caf"), so it must
    # not contain path separators or traversal — otherwise a blob could escape the per-user
    # prefix that account deletion relies on. Restrict to a safe id charset.
    if not _SAFE_CLIENT_ID.fullmatch(client_capture_id):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "client_capture_id must match [A-Za-z0-9._-]{1,128}",
        )

    store = CapturesStore(db)

    existing = await store.get_by_client_id(user_id, client_capture_id)
    if existing is not None:
        # Idempotent replay: the blob + row already landed.
        return CaptureStatus(
            id=existing["id"],
            client_capture_id=client_capture_id,
            status=existing["status"],
            duration_ms=existing.get("duration_ms"),
            deduped=True,
        )

    data = await audio.read()
    if len(data) > _MAX_AUDIO_BYTES:
        raise HTTPException(
            status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "audio exceeds 50 MB cap"
        )
    if not data:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "empty audio")

    # Blob first, then row — ack 'uploaded' only after BOTH are durable.
    path = f"{user_id}/{client_capture_id}.caf"
    await storage.put(
        CAPTURE_AUDIO_BUCKET, path, data, content_type=audio.content_type or "audio/x-caf"
    )
    row = await store.insert(
        user_id=user_id,
        client_capture_id=client_capture_id,
        audio_path=path,
        duration_ms=duration_ms,
        device=device,
    )
    return CaptureStatus(
        id=row["id"],
        client_capture_id=client_capture_id,
        status=row["status"],
        duration_ms=duration_ms,
    )


@router.get("/{capture_id}", response_model=CaptureStatus)
async def get_capture(capture_id: str, user_id: CurrentUser, db: Db) -> CaptureStatus:
    try:
        cid = UUID(capture_id)
    except ValueError as e:
        # A non-UUID path id is "not found", never a 500 (uncaught ValueError).
        raise HTTPException(status.HTTP_404_NOT_FOUND, "capture not found") from e
    row = await CapturesStore(db).get(cid, user_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "capture not found")
    return CaptureStatus(
        id=row["id"],
        client_capture_id=row["client_capture_id"],
        status=row["status"],
        duration_ms=row.get("duration_ms"),
    )
