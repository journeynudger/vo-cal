"""The person's timezone: the one read every surface buckets its days by.

Four routers carried their own copy of "profiles.tz, or UTC", each catching only
ZoneInfoNotFoundError. ZoneInfo raises ValueError for a malformed key ("/etc/localtime", a path,
a NUL byte), and the profile row is the owner's to write through PostgREST as well as through
the validated PATCH /account/profile, so such a name 500'd the nudge plan, Today, the check-in
and the week (2026-10-22 audit). One read, one catch.
"""

from __future__ import annotations

from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .db import SupportsDatabase


def zone_or_none(name: str | None) -> ZoneInfo | None:
    """A ZoneInfo for an IANA name, or None (absent, unknown or malformed)."""
    if not name:
        return None
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return None


async def profile_zone(db: SupportsDatabase, user_id: UUID) -> ZoneInfo:
    """The person's profiles.tz, or UTC when it is absent or unusable."""
    rows = await db.select("profiles", user_id=user_id)
    return zone_or_none(rows[0].get("tz") if rows else None) or ZoneInfo("UTC")
