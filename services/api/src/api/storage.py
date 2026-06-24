"""Object-storage seam — where capture audio blobs live (Supabase Storage).

Same seam pattern as db.py: one small contract, two implementations.

- ``SupabaseStorage`` — the private ``capture-audio`` bucket (production).
- ``FakeStorage``     — in-memory dict (the offline test suite).

The server may acknowledge a capture ``uploaded`` only after the blob is durably
stored here AND the immutable captures row is committed (Serein data-plane rule,
ported to Supabase). Audio is the ground truth; transcripts/parses are derived.
"""

from __future__ import annotations

from typing import Any, Protocol

CAPTURE_AUDIO_BUCKET = "capture-audio"


class SupportsStorage(Protocol):
    async def put(self, bucket: str, path: str, data: bytes, *, content_type: str) -> str: ...

    async def get(self, bucket: str, path: str) -> bytes: ...

    async def signed_url(self, bucket: str, path: str, *, ttl_seconds: int = 3600) -> str: ...

    async def list(self, bucket: str, prefix: str) -> list[str]: ...

    async def remove(self, bucket: str, paths: list[str]) -> None: ...


class SupabaseStorage:
    """Supabase Storage backed by the async client. Private bucket; signed URLs only."""

    def __init__(self, client: Any) -> None:
        self._client = client

    async def put(self, bucket: str, path: str, data: bytes, *, content_type: str) -> str:
        await self._client.storage.from_(bucket).upload(
            path, data, {"content-type": content_type, "upsert": "true"}
        )
        return path

    async def get(self, bucket: str, path: str) -> bytes:
        # Server-side read of the ground-truth blob (e.g. transcription). Returns raw bytes.
        return await self._client.storage.from_(bucket).download(path)

    async def signed_url(self, bucket: str, path: str, *, ttl_seconds: int = 3600) -> str:
        result = await self._client.storage.from_(bucket).create_signed_url(path, ttl_seconds)
        return result.get("signedURL") or result.get("signed_url") or ""

    async def list(self, bucket: str, prefix: str) -> list[str]:
        # Objects live under "{user_id}/...": list that folder, return full paths. MUST paginate
        # — the storage SDK defaults to a 100-object page, so a single .list() would silently
        # return only the first 100 and account deletion would orphan the rest (audio is the most
        # sensitive data; AGENTS.md #1). Loop until a short page, capped to avoid an unbounded loop.
        # Request the SDK's default page size (it caps larger requests, which would silently
        # truncate), and advance by it until a short page signals the end.
        page = 100
        names: list[str] = []
        offset = 0
        while True:
            items = await self._client.storage.from_(bucket).list(
                prefix, {"limit": page, "offset": offset}
            )
            batch = [i.get("name") for i in (items or []) if i.get("name")]
            names.extend(batch)
            if len(batch) < page:
                break
            offset += page
        return [f"{prefix}/{name}" for name in names]

    async def remove(self, bucket: str, paths: list[str]) -> None:
        if paths:
            await self._client.storage.from_(bucket).remove(paths)


class FakeStorage:
    """In-memory blob store for tests. Signed URLs are deterministic fakes."""

    def __init__(self) -> None:
        self.blobs: dict[tuple[str, str], bytes] = {}

    async def put(self, bucket: str, path: str, data: bytes, *, content_type: str) -> str:
        del content_type
        self.blobs[(bucket, path)] = data
        return path

    async def get(self, bucket: str, path: str) -> bytes:
        return self.blobs.get((bucket, path), b"")

    async def signed_url(self, bucket: str, path: str, *, ttl_seconds: int = 3600) -> str:
        if (bucket, path) not in self.blobs:
            return ""
        return f"https://fake.storage.local/{bucket}/{path}?ttl={ttl_seconds}"

    async def list(self, bucket: str, prefix: str) -> list[str]:
        return [p for (b, p) in self.blobs if b == bucket and p.startswith(prefix)]

    async def remove(self, bucket: str, paths: list[str]) -> None:
        for path in paths:
            self.blobs.pop((bucket, path), None)
