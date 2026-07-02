"""CheckinStore window reads.

The recalibration path (checkin/router.py) sums meal_logs over a window via
CheckinStore.meal_logs_between. Ordering must be by the parsed INSTANT, not the raw
ISO string — string order mis-sorts across differing UTC offsets, exactly the bug the
meals store documents fixing with _parse_dt.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from api.checkin.store import CheckinStore
from api.db import FakeDatabase

_USER = UUID("11111111-1111-1111-1111-111111111111")


async def test_meal_logs_between_sorts_by_instant_not_iso_string():
    db = FakeDatabase()
    # "B" is the EARLIER instant (10:00Z) but sorts AFTER "A" as a raw string,
    # because "...T10:00:00+00:00" > "...T09:00:00-05:00" lexically while "A" (09:00-05:00
    # = 14:00Z) is the LATER instant. A correct sort returns [B, A]; the string sort [A, B].
    await db.insert(
        "meal_logs",
        {"user_id": str(_USER), "client_meal_id": "a", "logged_at": "2026-06-01T09:00:00-05:00"},
    )
    await db.insert(
        "meal_logs",
        {"user_id": str(_USER), "client_meal_id": "b", "logged_at": "2026-06-01T10:00:00+00:00"},
    )

    start = datetime.fromisoformat("2026-06-01T00:00:00+00:00")
    end = datetime.fromisoformat("2026-06-02T00:00:00+00:00")
    rows = await CheckinStore(db).meal_logs_between(_USER, start, end)

    assert [r["logged_at"] for r in rows] == [
        "2026-06-01T10:00:00+00:00",  # 10:00Z — earlier instant first
        "2026-06-01T09:00:00-05:00",  # 14:00Z — later instant second
    ]
