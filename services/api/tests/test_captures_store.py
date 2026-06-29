"""Capture upload must not 500 when the optional content_type column isn't migrated yet.

Regression: the RT-42 content_type write was deployed ahead of its migration (20260626), so
PostgREST returned PGRST204 "Could not find the 'content_type' column" and every /captures
upload 500'd — breaking the whole voice loop. content_type is OPTIONAL (transcription falls
back to audio/x-caf), so the store now drops it and retries instead of failing the upload.
"""

from __future__ import annotations

from uuid import uuid4

from api.captures.store import CapturesStore


class _ColumnMissingDB:
    """Stub DB that rejects any insert referencing content_type (mimics PGRST204), like a
    production schema where the migration hasn't run; succeeds once the column is gone."""

    def __init__(self) -> None:
        self.inserts: list[dict] = []

    async def insert(self, table: str, row: dict) -> dict:
        self.inserts.append(dict(row))
        if "content_type" in row:
            raise RuntimeError(
                "{'message': \"Could not find the 'content_type' column of 'captures' "
                "in the schema cache\", 'code': 'PGRST204'}"
            )
        return {**row, "created_at": "2026-06-30T00:00:00Z"}


async def test_insert_retries_without_content_type_when_column_missing():
    db = _ColumnMissingDB()
    store = CapturesStore(db)
    row = await store.insert(
        user_id=uuid4(),
        client_capture_id="c1",
        audio_path="u/c1.caf",
        duration_ms=None,
        device=None,
        content_type="audio/x-caf",
    )
    assert row["audio_path"] == "u/c1.caf"
    assert len(db.inserts) == 2  # first attempt (with content_type) failed, retry succeeded
    assert "content_type" in db.inserts[0]
    assert "content_type" not in db.inserts[1]


class _AlwaysFailDB:
    async def insert(self, table: str, row: dict) -> dict:
        raise RuntimeError("some unrelated database error")


async def test_insert_does_not_swallow_unrelated_errors():
    import pytest

    store = CapturesStore(_AlwaysFailDB())
    with pytest.raises(RuntimeError, match="unrelated"):
        await store.insert(
            user_id=uuid4(), client_capture_id="c2", audio_path="u/c2.caf",
            duration_ms=None, device=None, content_type="audio/x-caf",
        )
