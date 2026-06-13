"""Tenant-isolation probes.

Offline: FakeDatabase mirrors RLS owner scoping, so cross-tenant leaks in store
logic surface in the fast suite. (Once the meals store grows query methods in
Phase D, probe it through the store; for now we test the seam directly.)

Live: @pytest.mark.live_db tests run against a real Supabase (deselected by
default via pyproject addopts) and verify the actual RLS policies: user A's
meal_logs/captures are invisible to user B. Run with:

    SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=... \
        uv run pytest -m live_db
"""

from __future__ import annotations

import os
import uuid
from datetime import UTC, datetime

import pytest

from api.db import FakeDatabase

# ---------------------------------------------------------------------------
# Offline: FakeDatabase owner scoping
# ---------------------------------------------------------------------------


async def test_fake_db_select_scopes_meal_logs_by_user(test_user_id, test_user_2_id):
    db = FakeDatabase()
    await db.insert(
        "meal_logs",
        {"user_id": str(test_user_id), "items": [], "totals": {}, "name": "a-lunch"},
    )
    await db.insert(
        "meal_logs",
        {"user_id": str(test_user_2_id), "items": [], "totals": {}, "name": "b-lunch"},
    )

    a_rows = await db.select("meal_logs", user_id=test_user_id)
    b_rows = await db.select("meal_logs", user_id=test_user_2_id)

    assert [row["name"] for row in a_rows] == ["a-lunch"]
    assert [row["name"] for row in b_rows] == ["b-lunch"]


async def test_fake_db_select_scopes_captures_even_with_filters(test_user_id, test_user_2_id):
    db = FakeDatabase()
    row = await db.insert(
        "captures",
        {"user_id": str(test_user_id), "client_capture_id": "c-1", "status": "uploaded"},
    )

    # User B cannot reach user A's capture even when filtering by its exact id
    leaked = await db.select("captures", {"id": row["id"]}, user_id=test_user_2_id)
    assert leaked == []

    owned = await db.select("captures", {"id": row["id"]}, user_id=test_user_id)
    assert len(owned) == 1


async def test_fake_db_update_respects_owner_scope(test_user_id, test_user_2_id):
    db = FakeDatabase()
    row = await db.insert(
        "captures",
        {"user_id": str(test_user_id), "client_capture_id": "c-2", "status": "uploaded"},
    )

    hijacked = await db.update(
        "captures", {"id": row["id"]}, {"status": "ready"}, user_id=test_user_2_id
    )
    assert hijacked == []

    rows = await db.select("captures", {"id": row["id"]}, user_id=test_user_id)
    assert rows[0]["status"] == "uploaded"


async def test_fake_db_rows_without_owner_never_match_scoped_select(test_user_id):
    # Deny-by-default: a row missing user_id is invisible to any scoped read
    db = FakeDatabase()
    await db.insert("meal_logs", {"items": [], "totals": {}})

    assert await db.select("meal_logs", user_id=test_user_id) == []


async def test_fake_db_shared_tables_skip_owner_scoping(test_user_id):
    db = FakeDatabase()
    await db.insert("food_dictionary", {"canonical_name": "chicken breast", "per_100g": {}})

    rows = await db.select("food_dictionary", user_id=test_user_id)
    assert len(rows) == 1


# ---------------------------------------------------------------------------
# Live: real RLS policies against a running Supabase
# ---------------------------------------------------------------------------


def _live_env() -> tuple[str, str, str]:
    url = os.environ.get("SUPABASE_URL", "")
    anon = os.environ.get("SUPABASE_ANON_KEY", "")
    service = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not (url and anon and service):
        pytest.skip("live_db: SUPABASE_URL/SUPABASE_ANON_KEY/SUPABASE_SERVICE_ROLE_KEY not set")
    return url, anon, service


@pytest.fixture(scope="module")
def live_users():
    """Two throwaway confirmed users with signed-in anon clients; cleaned up after."""
    from supabase import create_client

    url, anon, service = _live_env()
    admin = create_client(url, service)

    user_ids: list[str] = []
    clients = []
    for _ in range(2):
        email = f"rls-probe-{uuid.uuid4().hex[:12]}@example.com"
        password = uuid.uuid4().hex
        created = admin.auth.admin.create_user(
            {"email": email, "password": password, "email_confirm": True}
        )
        user_ids.append(created.user.id)
        client = create_client(url, anon)
        client.auth.sign_in_with_password({"email": email, "password": password})
        clients.append(client)

    yield user_ids, clients

    # Cascades remove all probe rows (FKs reference auth.users ON DELETE CASCADE)
    for user_id in user_ids:
        admin.auth.admin.delete_user(user_id)


@pytest.mark.live_db
def test_rls_user_b_cannot_read_user_a_captures(live_users):
    (user_a, _), (client_a, client_b) = live_users[0], live_users[1]

    inserted = (
        client_a.table("captures")
        .insert(
            {
                "user_id": user_a,
                "client_capture_id": f"probe-{uuid.uuid4().hex[:8]}",
                "status": "uploaded",
            }
        )
        .execute()
    )
    capture_id = inserted.data[0]["id"]

    # B: direct-id read and table scan must both come back empty
    assert client_b.table("captures").select("*").eq("id", capture_id).execute().data == []
    b_scan = client_b.table("captures").select("*").execute().data
    assert all(row["user_id"] != user_a for row in b_scan)

    # A still sees their own row
    assert len(client_a.table("captures").select("*").eq("id", capture_id).execute().data) == 1


@pytest.mark.live_db
def test_rls_user_b_cannot_read_user_a_meal_logs(live_users):
    (user_a, _), (client_a, client_b) = live_users[0], live_users[1]

    inserted = (
        client_a.table("meal_logs")
        .insert(
            {
                "user_id": user_a,
                "items": [],
                "totals": {},
                "name": "rls-probe-meal",
                "logged_at": datetime.now(UTC).isoformat(),
            }
        )
        .execute()
    )
    meal_id = inserted.data[0]["id"]

    assert client_b.table("meal_logs").select("*").eq("id", meal_id).execute().data == []
    b_scan = client_b.table("meal_logs").select("*").execute().data
    assert all(row["user_id"] != user_a for row in b_scan)

    assert len(client_a.table("meal_logs").select("*").eq("id", meal_id).execute().data) == 1


@pytest.mark.live_db
def test_rls_user_b_cannot_insert_as_user_a(live_users):
    (user_a, _), (_, client_b) = live_users[0], live_users[1]

    with pytest.raises(Exception, match=r"(?i)row-level security|violates"):
        client_b.table("meal_logs").insert(
            {
                "user_id": user_a,
                "items": [],
                "totals": {},
                "logged_at": datetime.now(UTC).isoformat(),
            }
        ).execute()
