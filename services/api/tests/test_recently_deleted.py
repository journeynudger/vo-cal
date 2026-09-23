"""R10: recently deleted meals with Restore (Bill: "recently deleted w/ 30 day recover").

A delete is a tombstone (the row never leaves); inside the window the person sees it under
Settings > Recently deleted and can put it back exactly as it was. Past the window it is
hidden at once and the admin purge sweep removes it for good.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from api.config import settings
from api.dependencies import make_test_token

from .conftest import TEST_USER_ID, confirmed_items, parse_transcript

ADMIN_EMAIL = "admin@vocal.test"


def _log(client, headers, client_meal_id="del-1", edit=False):
    parsed = parse_transcript(client, headers)
    items = confirmed_items(parsed)
    if edit:
        items[0]["amount"] = 6.0
    payload = {
        "client_meal_id": client_meal_id,
        "parse_id": parsed["parse_id"],
        "meal_type": "lunch",
        "items": items,
        "logged_at": datetime.now(UTC).isoformat(),
    }
    resp = client.post("/meals", json=payload, headers=headers)
    assert resp.status_code == 201
    return resp.json(), payload


def _day(client, headers):
    date_str = datetime.now(UTC).strftime("%Y-%m-%d")
    return client.get(f"/meals?date={date_str}", headers=headers).json()["meals"]


def _deleted(client, headers):
    resp = client.get("/meals/deleted", headers=headers)
    assert resp.status_code == 200
    return resp.json()


def test_deleted_meal_is_listed_with_its_window(client, auth_headers):
    logged, _ = _log(client, auth_headers)
    assert _deleted(client, auth_headers) == []
    assert client.delete(f"/meals/{logged['id']}", headers=auth_headers).status_code == 204
    listed = _deleted(client, auth_headers)
    assert [m["id"] for m in listed] == [logged["id"]]
    deleted_at = datetime.fromisoformat(listed[0]["deleted_at"])
    restore_until = datetime.fromisoformat(listed[0]["restore_until"])
    assert restore_until - deleted_at == timedelta(days=30)
    assert listed[0]["totals"]["kcal"] == logged["totals"]["kcal"]
    assert all(m["id"] != logged["id"] for m in _day(client, auth_headers))


def test_restore_puts_the_meal_back_exactly(client, auth_headers):
    logged, _ = _log(client, auth_headers, edit=True)
    assert logged["corrections_count"] >= 1
    client.delete(f"/meals/{logged['id']}", headers=auth_headers)
    resp = client.post(f"/meals/{logged['id']}/restore", headers=auth_headers)
    assert resp.status_code == 200
    restored = resp.json()
    assert restored["id"] == logged["id"]
    assert restored["totals"] == logged["totals"]
    assert restored["items"] == logged["items"]
    assert restored["corrections_count"] == logged["corrections_count"]
    assert [m["id"] for m in _day(client, auth_headers)] == [logged["id"]]
    assert _deleted(client, auth_headers) == []


def test_restore_needs_a_deleted_owned_meal(client, auth_headers, auth_headers_user_2):
    logged, _ = _log(client, auth_headers)
    assert client.post(f"/meals/{logged['id']}/restore", headers=auth_headers).status_code == 404
    assert client.post("/meals/not-a-uuid/restore", headers=auth_headers).status_code == 404
    client.delete(f"/meals/{logged['id']}", headers=auth_headers)
    assert _deleted(client, auth_headers_user_2) == []
    assert client.post(f"/meals/{logged['id']}/restore", headers=auth_headers_user_2).status_code == 404
    assert [m["id"] for m in _deleted(client, auth_headers)] == [logged["id"]]


def test_window_closes_after_thirty_days(client, auth_headers, fake_db):
    logged, _ = _log(client, auth_headers)
    client.delete(f"/meals/{logged['id']}", headers=auth_headers)
    row = next(r for r in fake_db.tables["meal_logs"] if r["id"] == logged["id"])
    row["deleted_at"] = (datetime.now(UTC) - timedelta(days=31)).isoformat()
    assert _deleted(client, auth_headers) == []
    assert client.post(f"/meals/{logged['id']}/restore", headers=auth_headers).status_code == 410


def test_restore_conflicts_with_a_replayed_copy(client, auth_headers):
    logged, payload = _log(client, auth_headers, client_meal_id="replay-restore")
    client.delete(f"/meals/{logged['id']}", headers=auth_headers)
    replay = client.post("/meals", json=payload, headers=auth_headers)
    assert replay.status_code == 201
    resp = client.post(f"/meals/{logged['id']}/restore", headers=auth_headers)
    assert resp.status_code == 409
    assert len(_day(client, auth_headers)) == 1


@pytest.fixture
def admin_headers():
    """The allowlisted admin for one test (same shape as test_admin_api.py)."""
    previous = settings.admin_emails
    settings.admin_emails = [ADMIN_EMAIL]
    yield {"X-Test-User": make_test_token(TEST_USER_ID), "X-Test-Admin": ADMIN_EMAIL}
    settings.admin_emails = previous


def test_purge_removes_only_tombstones_past_the_window(client, auth_headers, admin_headers, fake_db):
    old, _ = _log(client, auth_headers, client_meal_id="old", edit=True)
    recent, _ = _log(client, auth_headers, client_meal_id="recent")
    live, _ = _log(client, auth_headers, client_meal_id="live")
    for meal in (old, recent):
        client.delete(f"/meals/{meal['id']}", headers=auth_headers)
    row = next(r for r in fake_db.tables["meal_logs"] if r["id"] == old["id"])
    row["deleted_at"] = (datetime.now(UTC) - timedelta(days=40)).isoformat()
    assert any(c["meal_log_id"] == old["id"] for c in fake_db.tables["corrections"])

    assert client.post("/admin/meals/purge-deleted", headers=auth_headers).status_code == 403
    dry = client.post("/admin/meals/purge-deleted?dry_run=true", headers=admin_headers)
    assert dry.status_code == 200
    assert dry.json() == {"purged": 1, "dry_run": True}
    assert len(fake_db.tables["meal_logs"]) == 3

    resp = client.post("/admin/meals/purge-deleted", headers=admin_headers)
    assert resp.status_code == 200
    assert resp.json() == {"purged": 1, "dry_run": False}
    ids = {r["id"] for r in fake_db.tables["meal_logs"]}
    assert ids == {recent["id"], live["id"]}
    assert all(c["meal_log_id"] != old["id"] for c in fake_db.tables["corrections"])
    actions = [r["action"] for r in fake_db.tables["admin_audit_log"]]
    assert actions == ["purge_deleted_meals_dry_run", "purge_deleted_meals"]
    assert [m["id"] for m in _deleted(client, auth_headers)] == [recent["id"]]
