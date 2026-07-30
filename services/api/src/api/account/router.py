"""Account lifecycle — DELETE /account (App Review 5.1.1(v): account creation ⇒ in-app
account deletion).

Deletion is total and irreversible:
  1. Purge the user's capture-audio blobs (Storage — not covered by DB cascade).
  2. Delete every user-owned row (explicit, owner-scoped — also makes the offline suite
     meaningful since FakeDatabase has no auth.users cascade).
  3. Delete the Supabase auth user, which removes the identity and cascades any remainder
     (every user table is ON DELETE CASCADE from auth.users).

Order matters: blobs and rows first, identity last, so a mid-delete failure leaves no
orphaned identity pointing at half-deleted data. A re-signup with the same provider then
gets a clean slate.
"""

from __future__ import annotations

from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel

from ..config import settings
from ..dependencies import CurrentUser, Db, Storage
from ..storage import CAPTURE_AUDIO_BUCKET

router = APIRouter(prefix="/account", tags=["account"])


class ProfileUpdate(BaseModel):
    """PATCH /account/profile body. Only mutable profile fields — identity stays server-owned."""

    tz: str


class ProfileResponse(BaseModel):
    tz: str


@router.patch("/profile", response_model=ProfileResponse)
async def update_profile(req: ProfileUpdate, user_id: CurrentUser, db: Db) -> ProfileResponse:
    """Persist the device's IANA timezone to ``profiles.tz``.

    Until this existed nothing wrote profiles.tz, so every user was bucketed by UTC on
    any endpoint that didn't receive an explicit ``tz`` param — and the nudge planner
    (which has no request to read a param from) computed windows in UTC forever
    (deferred item from #18). The app syncs on launch and on timezone change.
    """
    try:
        ZoneInfo(req.tz)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        # An unknown zone must not be persisted: every reader falls back to UTC on a bad
        # name, so storing junk would silently pin the user to UTC while looking configured.
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "tz must be a valid IANA timezone name"
        ) from exc

    updated = await db.update("profiles", {"id": str(user_id)}, {"tz": req.tz})
    if not updated:
        # Signup creates the profile row (auth trigger); a missing row here is the test/
        # fresh-seed path. Insert rather than 404 — the device's tz is true either way.
        await db.insert("profiles", {"id": str(user_id), "tz": req.tz})
    return ProfileResponse(tz=req.tz)

# User-owned tables, deleted explicitly (each is independently owner-scoped).
_USER_OWNED_TABLES = (
    "client_metrics",
    "checkins",
    "saved_meals",
    "meal_logs",
    "parses",
    "captures",
    "protocols",
    "intake_responses",
    "water_logs",
    "profiles",
)


async def _delete_auth_user(user_id: UUID) -> None:
    """Delete the Supabase auth user (prod only). No-op under test_mode or without creds —
    the offline suite asserts row/blob deletion via the seams instead."""
    if settings.test_mode or not (settings.supabase_url and settings.supabase_service_role_key):
        return
    from supabase import acreate_client  # noqa: PLC0415  (lazy heavy SDK; rare op)

    client = await acreate_client(settings.supabase_url, settings.supabase_service_role_key)
    await client.auth.admin.delete_user(str(user_id))


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
async def delete_account(user_id: CurrentUser, db: Db, storage: Storage) -> None:
    blob_paths = await storage.list(CAPTURE_AUDIO_BUCKET, str(user_id))
    await storage.remove(CAPTURE_AUDIO_BUCKET, blob_paths)

    # Child rows that carry no user_id (transcripts -> captures, corrections -> meal_logs).
    # In prod these also cascade when the parent rows / auth user are deleted; we delete them
    # explicitly too so the purge is complete regardless of FK cascade (and so the offline
    # suite, which has no cascade, faithfully verifies a total wipe).
    capture_ids = [c["id"] for c in await db.select("captures", {}, user_id=user_id)]
    meal_log_ids = [m["id"] for m in await db.select("meal_logs", {}, user_id=user_id)]
    for capture_id in capture_ids:
        await db.delete("transcripts", {"capture_id": capture_id})
    for meal_log_id in meal_log_ids:
        await db.delete("corrections", {"meal_log_id": meal_log_id})

    for table in _USER_OWNED_TABLES:
        await db.delete(table, {}, user_id=user_id)

    await _delete_auth_user(user_id)
