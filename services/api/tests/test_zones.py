"""A profile timezone the API cannot use reads as UTC, never a 500 (2026-10-22 audit).

PATCH /account/profile validates the name, but the profile row is the owner's to write through
PostgREST too, and ZoneInfo raises ValueError (not only ZoneInfoNotFoundError) for a malformed
key. Four routers each caught only the second: the nudge plan, Today, the check-in and the week
answered 500 for a profile tz of "/etc/localtime".
"""

from __future__ import annotations

import pytest

from .conftest import TEST_USER_ID


@pytest.mark.parametrize("name", ["/etc/localtime", "../etc", "America/", "nul\x00zone", "Not/AZone"])
def test_every_surface_reads_an_unusable_profile_zone_as_utc(client, auth_headers, fake_db, name):
    fake_db.tables.setdefault("profiles", []).append({"id": str(TEST_USER_ID), "tz": name})
    assert client.post("/nudges/plan", json={"recently_shown": {}}, headers=auth_headers).status_code == 200
    assert client.get("/meals/today?date=2026-10-22", headers=auth_headers).status_code == 200
    assert client.get("/checkin/checkins/due", headers=auth_headers).status_code == 200
    assert client.get("/week/budget?date=2026-10-22", headers=auth_headers).status_code == 200
