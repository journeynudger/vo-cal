"""Two writes for one person in flight at once, on the append-only version tables.

tracking_preferences and meal_plans take the next version per person under a unique
(user_id, version) index. On 2026-10-22, against Postgres behind PostgREST, two concurrent
PUT /tracking (one the mode, one the reminders) both answered 200 and the later version wrote
back the stale value of the other field, 12 times in 12; six concurrent PUTs (either table)
gave three 500s. The merge now runs inside the retry, on the version it appends after, and a
burst no retry can carry is a 409 the client can retry, never a 500.

Offline, ``_InterleavedWrite`` lands the competing request's row between this request's read
and its insert: the same interleaving Postgres produced.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from fastapi.testclient import TestClient

from api.db import FakeDatabase
from api.dependencies import make_test_token
from api.main import create_app
from api.storage import FakeStorage
from api.tracking.router import apply_update
from api.tracking.schemas import NudgeLevel, TrackingMode, TrackingUpdate
from api.tracking.store import TrackingStore

from .conftest import TEST_USER_ID


class _InterleavedWrite(FakeDatabase):
    """While armed, each insert into ``table`` is preceded by a competitor's row taking the same
    version, as a request that read the same latest and committed first would. ``times`` caps
    how many inserts lose the race (None: every one)."""

    def __init__(self, table: str, competitor: Callable[[dict[str, Any]], dict[str, Any]]) -> None:
        super().__init__()
        self._table = table
        self._competitor = competitor
        self.armed = False
        self.times: int | None = 1
        self.lost = 0

    async def insert(self, table: str, row: dict[str, Any]) -> dict[str, Any]:
        if self.armed and table == self._table and (self.times is None or self.lost < self.times):
            self.lost += 1
            await super().insert(table, self._competitor(row))
        return await super().insert(table, row)


def _mode_calories(row: dict[str, Any]) -> dict[str, Any]:
    # The other request changed the mode, and wrote what it read of every other field.
    return {**row, "id": f"competitor-{row['version']}", "mode": "calories", "nudge_level": "standard"}


async def test_a_concurrent_change_to_another_field_survives():
    db = _InterleavedWrite("tracking_preferences", _mode_calories)
    await apply_update(db, TEST_USER_ID, TrackingUpdate(mode=TrackingMode.FIVE, nudge_level=NudgeLevel.STANDARD))

    db.armed = True
    result = await apply_update(db, TEST_USER_ID, TrackingUpdate(nudge_level=NudgeLevel.OFF))

    latest = await TrackingStore(db).latest(TEST_USER_ID)
    assert db.lost == 1
    # Both changes stand: the competitor's mode and this request's reminders.
    assert latest.mode is TrackingMode.CALORIES
    assert latest.nudge_level is NudgeLevel.OFF
    assert result.version == latest.version == 3


async def test_the_first_version_races_too():
    db = _InterleavedWrite("tracking_preferences", _mode_calories)
    db.armed = True
    await apply_update(db, TEST_USER_ID, TrackingUpdate(nudge_level=NudgeLevel.ESSENTIAL))

    latest = await TrackingStore(db).latest(TEST_USER_ID)
    assert (latest.version, latest.mode, latest.nudge_level) == (2, TrackingMode.CALORIES, NudgeLevel.ESSENTIAL)


def _client(db: FakeDatabase) -> TestClient:
    return TestClient(create_app(database=db, storage=FakeStorage()))


_HEADERS = {"X-Test-User": make_test_token(TEST_USER_ID)}


def test_a_burst_no_retry_carries_is_a_409_not_a_500():
    db = _InterleavedWrite("tracking_preferences", _mode_calories)
    db.armed, db.times = True, None
    with _client(db) as client:
        resp = client.put("/tracking", json={"nudge_level": "off"}, headers=_HEADERS)
    assert resp.status_code == 409, resp.text
    # Every lost attempt is the competitor's row: nothing of this request was written.
    assert all(row["nudge_level"] != "off" for row in db.tables["tracking_preferences"])


def _plan_body(name: str) -> dict[str, Any]:
    return {
        "slots": [
            {
                "name": name,
                "items": [
                    {"name": "oatmeal", "amount": 80, "unit": "g", "grams": 80,
                     "macros": {"kcal": 300, "protein": 10, "carbs": 54, "fat": 5, "fiber": 8},
                     "confidence": 0.9},
                ],
            }
        ]
    }


def _other_plan(row: dict[str, Any]) -> dict[str, Any]:
    return {**row, "id": f"competitor-{row['version']}", "slots": []}


def test_a_plan_saved_while_another_save_lands_takes_the_next_version():
    db = _InterleavedWrite("meal_plans", _other_plan)
    db.armed = True
    with _client(db) as client:
        resp = client.put("/meals/plan", json=_plan_body("Oats"), headers=_HEADERS)
        assert resp.status_code == 200, resp.text
        latest = client.get("/meals/plan", headers=_HEADERS).json()
    versions = sorted(int(r["version"]) for r in db.tables["meal_plans"])
    assert versions == [1, 2]
    # The save the person made is the latest; the competitor's is the version before it.
    assert latest["version"] == 2
    assert [s["name"] for s in latest["slots"]] == ["Oats"]


def test_a_plan_burst_no_retry_carries_is_a_409_not_a_500():
    db = _InterleavedWrite("meal_plans", _other_plan)
    db.armed, db.times = True, None
    with _client(db) as client:
        resp = client.put("/meals/plan", json=_plan_body("Oats"), headers=_HEADERS)
    assert resp.status_code == 409, resp.text
