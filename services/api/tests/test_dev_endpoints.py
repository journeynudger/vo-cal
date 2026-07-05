"""/__dev agent endpoints — security gate first, then behavior (offline, FakeDatabase).

The suite's conftest does NOT set dev_endpoints, so the default client proves the 404
posture; dev-enabled clients are built explicitly here.
"""

from __future__ import annotations

from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient

from api.config import settings
from api.db import FakeDatabase
from api.main import create_app
from api.storage import FakeStorage

DEV_EMAIL = "dev@vo-cal.test"
DEV_UUID = "11111111-1111-1111-1111-111111111111"


@pytest.fixture
def dev_client(fake_db: FakeDatabase, fake_storage: FakeStorage) -> Generator[TestClient]:
    """A client with the /__dev router mounted (DEV_ENDPOINTS on)."""
    original = settings.dev_endpoints
    settings.dev_endpoints = True
    app = create_app(database=fake_db, storage=fake_storage)
    with TestClient(app) as c:
        yield c
    settings.dev_endpoints = original


# -- the security gate ----------------------------------------------------------


def test_dev_routes_are_404_when_flag_unset(client):
    # The default suite app has dev_endpoints=False: every /__dev path must be absent.
    assert client.get("/__dev").status_code == 404
    assert client.get("/__dev/preflight").status_code == 404
    assert client.get(f"/__dev/log-me-in/{DEV_EMAIL}").status_code == 404
    assert client.post("/__dev/capture", json={"text": "4oz 93/7 beef"}).status_code == 404


def test_boot_refuses_dev_endpoints_against_hosted_db():
    # The failure CLASS (dev surfaces + real user data) is stopped at startup.
    from api.main import _refuse_test_auth_against_hosted_db

    original = (settings.dev_endpoints, settings.supabase_url, settings.test_mode)
    settings.dev_endpoints = True
    settings.supabase_url = "https://example.supabase.co"
    settings.test_mode = False  # isolate: the X-Test-User guard must not fire first
    try:
        with pytest.raises(RuntimeError, match="__dev"):
            _refuse_test_auth_against_hosted_db()
    finally:
        settings.dev_endpoints, settings.supabase_url, settings.test_mode = original


# -- behavior ---------------------------------------------------------------------


def test_dev_index_lists_endpoints(dev_client):
    body = dev_client.get("/__dev").json()
    assert "POST /__dev/capture" in body["endpoints"]
    assert DEV_EMAIL in body["seed_users"]


def test_log_me_in_returns_test_header(dev_client):
    body = dev_client.get(f"/__dev/log-me-in/{DEV_EMAIL}").json()
    assert body["use_header"] == {"X-Test-User": DEV_UUID}


def test_log_me_in_unknown_email_lists_seeds(dev_client):
    resp = dev_client.get("/__dev/log-me-in/nobody@nowhere.test")
    assert resp.status_code == 404
    assert "seeded" in resp.json()["detail"]


def test_capture_runs_real_parse_and_store(dev_client, fake_db):
    # The mic bypass: text -> REAL parse (recorded fixture) -> REAL meal_logs row.
    resp = dev_client.post("/__dev/capture", json={"text": "4oz 93/7 beef", "email": DEV_EMAIL})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["parse"]["items"][0]["name"] == "ground beef"
    assert body["parse"]["certainty"] is not None
    assert body["stored_meal"] is not None
    # Durable proof, not just a response: the row exists, owner-scoped.
    rows = [r for r in fake_db.tables.get("meal_logs", []) if r["user_id"] == DEV_UUID]
    assert len(rows) == 1
    # And the parse artifact was persisted (real pipeline, real provenance).
    assert len(fake_db.tables.get("parses", [])) == 1


def test_capture_parse_only_when_confirm_false(dev_client, fake_db):
    resp = dev_client.post(
        "/__dev/capture", json={"text": "4oz 93/7 beef", "confirm": False}
    )
    assert resp.status_code == 200
    assert resp.json()["stored_meal"] is None
    assert fake_db.tables.get("meal_logs", []) in ([], None) or not [
        r for r in fake_db.tables["meal_logs"] if r["user_id"] == DEV_UUID
    ]


def test_preflight_reports_fakes_honestly(dev_client):
    body = dev_client.get("/__dev/preflight").json()
    checks = body["checks"]
    assert checks["database"]["fake"] is True  # FakeDatabase in the suite — said out loud
    assert checks["parse_provider"]["fake"] is True  # recorded fixtures, named as such
    assert checks["auth_seam"]["ok"] is True  # conftest sets TEST_MODE+DEBUG
    for c in checks.values():
        assert c.get("why")  # every check carries a human-readable reason


def test_db_summary_counts_meals(dev_client):
    dev_client.post("/__dev/capture", json={"text": "4oz 93/7 beef"})
    body = dev_client.get("/__dev/db/summary", params={"email": DEV_EMAIL}).json()
    assert body["counts"]["meal_logs"] == 1
    assert body["recent_meals"][0]["kcal"] > 0
