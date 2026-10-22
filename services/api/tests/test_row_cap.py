"""A read reaches past PostgREST's row cap (2026-10-22 audit).

Supabase answers a select with at most 1000 rows (db-max-rows) whatever the query asks, in no
promised order without one. Four stores read every version of a person's record and took the
max in Python: past the thousandth version the newest fell out of the answer, the "latest" was
an old one, and every append after it collided with a version that existed, a 409 for good. The
export stopped at the thousandth meal; the deletion's list of meals and captures (the parents of
corrections and transcripts) did too. ``FakeDatabase(max_rows=...)`` answers as PostgREST does.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4

from api.db import FakeDatabase

from .conftest import TEST_USER_ID

CAP = 1000
USER = str(TEST_USER_ID)


def _stamp(i: int) -> str:
    return (datetime(2025, 1, 1, tzinfo=UTC) + timedelta(minutes=i)).isoformat()


def _seed_versions(fake_db, table: str, count: int, **row) -> None:
    rows = fake_db.tables.setdefault(table, [])
    for version in range(1, count + 1):
        rows.append({"id": str(uuid4()), "user_id": USER, "version": version, "created_at": _stamp(version), **row})


def test_the_fake_orders_numbers_as_numbers():
    import asyncio

    db = FakeDatabase()
    db.tables["t"] = [{"id": "a", "version": 9}, {"id": "b", "version": 10}, {"id": "c", "version": 2}]
    newest = asyncio.run(db.select("t", order_by="version", descending=True, limit=1))
    assert newest[0]["version"] == 10


def test_tracking_past_the_cap_reads_the_newest_and_still_changes(client, auth_headers, fake_db):
    _seed_versions(fake_db, "tracking_preferences", CAP + 1, mode="calories", focus_metrics=[], declined_offers=[], source="chosen")
    fake_db.tables["tracking_preferences"][-1]["mode"] = "macros"
    fake_db.max_rows = CAP
    assert client.get("/tracking", headers=auth_headers).json()["mode"] == "macros"
    changed = client.put("/tracking", json={"mode": "habits"}, headers=auth_headers)
    assert changed.status_code == 200, changed.text
    assert changed.json()["version"] == CAP + 2


def test_a_meal_plan_past_the_cap_reads_the_newest_and_still_saves(client, auth_headers, fake_db):
    item = {"name": "egg", "amount": 2, "unit": None, "grams": 100.0,
            "macros": {"kcal": 143, "protein": 12.6, "carbs": 0.7, "fat": 9.5, "fiber": 0}, "confidence": 0.9}
    def slot(name):
        return {"index": 0, "name": name, "items": [item], "totals": item["macros"]}

    _seed_versions(fake_db, "meal_plans", CAP + 1, author="person", slots=[slot("Old")])
    fake_db.tables["meal_plans"][-1]["slots"] = [slot("Newest")]
    fake_db.max_rows = CAP
    assert client.get("/meals/plan", headers=auth_headers).json()["slots"][0]["name"] == "Newest"
    saved = client.put("/meals/plan", json={"slots": [{"name": "Breakfast", "items": [item]}]}, headers=auth_headers)
    assert saved.status_code == 200, saved.text
    assert saved.json()["version"] == CAP + 2


def test_intake_past_the_cap_reads_the_newest(client, auth_headers, fake_db):
    answers = {"age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0}
    _seed_versions(fake_db, "intake_responses", CAP + 1, answers=answers)
    fake_db.tables["intake_responses"][-1]["answers"] = {**answers, "weight_lb": 190.0}
    fake_db.max_rows = CAP
    latest = client.get("/intake/latest", headers=auth_headers)
    assert latest.status_code == 200, latest.text
    assert latest.json()["version"] == CAP + 1


def test_the_export_and_the_deletion_reach_past_the_cap(client, auth_headers, fake_db):
    meals = fake_db.tables.setdefault("meal_logs", [])
    corrections = fake_db.tables.setdefault("corrections", [])
    for i in range(CAP + 250):
        meals.append({"id": f"m-{i:05d}", "user_id": USER, "name": f"meal {i}", "logged_at": _stamp(i),
                      "totals": {"kcal": 100}, "items": [], "created_at": _stamp(i)})
        corrections.append({"id": f"c-{i:05d}", "meal_log_id": f"m-{i:05d}", "created_at": _stamp(i)})
    fake_db.max_rows = CAP

    record = client.get("/account/export", headers=auth_headers).json()
    assert len(record["meals"]) == CAP + 250
    assert len(record["corrections"]) == CAP + 250
    assert len(client.get("/account/export?format=csv", headers=auth_headers).text.splitlines()) == CAP + 251

    assert client.delete("/account", headers=auth_headers).status_code == 204
    assert fake_db.tables.get("corrections", []) == []
