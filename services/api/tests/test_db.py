"""FakeDatabase contract: it must model the UNIQUE indexes the migrations declare.

RT-31: the offline suite runs entirely against FakeDatabase, so any dedup/idempotency
invariant that Postgres enforces but the fake ignores ships green here and 500s in
prod. FakeDatabase mirrors the declared UNIQUE indexes — including the partial WHERE
clauses — and raises the same ``UniqueViolationError`` type both backends surface, so the
dedup/idempotency findings (RT-08/12/13) reproduce offline instead of only on a live DB.
"""

from __future__ import annotations

import pytest

from api.db import FakeDatabase, UniqueViolationError

USER_A = "11111111-1111-1111-1111-111111111111"
USER_B = "22222222-2222-2222-2222-222222222222"


async def test_fake_db_enforces_unique_client_capture() -> None:
    # captures: CONSTRAINT unique_client_capture UNIQUE (user_id, client_capture_id).
    db = FakeDatabase()
    await db.insert("captures", {"user_id": USER_A, "client_capture_id": "dup", "status": "uploaded"})
    with pytest.raises(UniqueViolationError):
        await db.insert(
            "captures", {"user_id": USER_A, "client_capture_id": "dup", "status": "uploaded"}
        )


async def test_unique_client_capture_is_scoped_per_user() -> None:
    # The index is (user_id, client_capture_id): the same client id under a DIFFERENT
    # user is not a conflict.
    db = FakeDatabase()
    await db.insert("captures", {"user_id": USER_A, "client_capture_id": "x", "status": "uploaded"})
    row = await db.insert(
        "captures", {"user_id": USER_B, "client_capture_id": "x", "status": "uploaded"}
    )
    assert row["user_id"] == USER_B


async def test_live_duplicate_client_meal_conflicts() -> None:
    # meal_logs partial unique index on (user_id, client_meal_id): two LIVE rows collide.
    db = FakeDatabase()
    await _insert_meal(db, USER_A, "m1")
    with pytest.raises(UniqueViolationError):
        await _insert_meal(db, USER_A, "m1")


async def test_tombstoned_meal_frees_client_meal_slot() -> None:
    # RT-12: the partial unique index excludes soft-deleted rows
    # (WHERE deleted_at IS NULL), so a re-log after delete inserts a fresh LIVE row
    # rather than colliding with the tombstone (which 500s on Postgres today).
    db = FakeDatabase()
    first = await _insert_meal(db, USER_A, "m1")
    await db.update("meal_logs", {"id": first["id"]}, {"deleted_at": "2026-06-25T13:00:00+00:00"})

    relog = await _insert_meal(db, USER_A, "m1")
    assert relog["id"] != first["id"]
    # The tombstone is retained (audit trail); the slot held exactly one live row.
    rows = db.tables["meal_logs"]
    assert len(rows) == 2
    assert len([r for r in rows if not r.get("deleted_at")]) == 1


async def test_null_client_meal_never_conflicts() -> None:
    # The partial index has WHERE client_meal_id IS NOT NULL: ad-hoc logs without a
    # client id (legacy / non-outbox writes) must not collide with each other.
    db = FakeDatabase()
    await _insert_meal(db, USER_A, None)
    await _insert_meal(db, USER_A, None)  # no raise
    assert len(db.tables["meal_logs"]) == 2


async def test_fake_db_enforces_unique_client_water() -> None:
    # water_logs partial unique index on (user_id, client_water_id) (RT-13).
    db = FakeDatabase()
    await db.insert(
        "water_logs",
        {"user_id": USER_A, "client_water_id": "w1", "amount_oz": 16, "logged_at": "2026-06-25T12:00:00+00:00"},
    )
    with pytest.raises(UniqueViolationError):
        await db.insert(
            "water_logs",
            {"user_id": USER_A, "client_water_id": "w1", "amount_oz": 16, "logged_at": "2026-06-25T12:00:00+00:00"},
        )


async def _insert_meal(db: FakeDatabase, user_id: str, client_meal_id: str | None) -> dict:
    return await db.insert(
        "meal_logs",
        {
            "user_id": user_id,
            "client_meal_id": client_meal_id,
            "items": [],
            "totals": {},
            "logged_at": "2026-06-25T12:00:00+00:00",
        },
    )
