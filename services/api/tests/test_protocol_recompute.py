"""Recompute-all-active-protocols maintenance pass (the 2026-07 calorie backfill).

Two layers: the pure sweep over FakeDatabase (recompute.py), and the admin-gated,
audit-logged endpoint (admin/router.py). The load-bearing properties: a stale protocol
is superseded to the correct numbers, a correct one is left untouched (idempotent, no
version churn), missing/invalid intake is skipped not guessed, dry-run writes nothing,
and only an allowlisted admin can trigger it — audited before any user data is touched.
"""

from __future__ import annotations

from uuid import UUID, uuid4

import pytest

from api.config import settings
from api.db import FakeDatabase
from api.dependencies import make_test_token
from api.protocols.recompute import recompute_active_protocols

from .conftest import TEST_USER_2_ID, TEST_USER_ID

ADMIN_EMAIL = "admin@vocal.test"

# The worked-example male body; intake answers as stored in intake_responses.answers.
_WORKED_EXAMPLE = {
    "age": 30, "sex": "male", "height_in": 70.0, "weight_lb": 200.0,
    "goal": "cut", "work": "desk", "train": "moderate", "kids": False,
    "med": "none", "stress": "moderate", "meals_per_day": 3,
}


def _seed_intake(db: FakeDatabase, user_id: UUID, answers: dict, version: int = 1) -> None:
    db.tables.setdefault("intake_responses", []).append(
        {"id": str(uuid4()), "user_id": str(user_id), "version": version, "answers": answers}
    )


def _seed_protocol(db: FakeDatabase, user_id: UUID, targets: dict, *, version: int = 1) -> str:
    pid = str(uuid4())
    db.tables.setdefault("protocols", []).append(
        {
            "id": pid, "user_id": str(user_id), "version": version,
            "supersedes": None, "active": True, "targets": {**targets, "version": version},
            "whys": {},
        }
    )
    return pid


def _stale_targets() -> dict:
    # A protocol as the BUGGY engine would have stored it: the worked-example body at the
    # auto-25% deficit -> 1690 kcal (the field bug), everything else plausible-but-stale.
    return {
        "version": 1, "kcal": 1690, "protein": 163, "protein_min": 131, "protein_max": 163,
        "carbs": 130, "fat": 54, "fiber": 32, "water_oz": 100, "produce_servings": 6,
        "meals_per_day": 3, "whys": {},
    }


def _correct_targets() -> dict:
    # What the FIXED engine produces for the worked example (test_protocols_api pins these).
    return {
        "version": 1, "kcal": 1805, "protein": 163, "protein_min": 131, "protein_max": 163,
        "carbs": 167, "fat": 54, "fiber": 32, "water_oz": 100, "produce_servings": 6,
        "meals_per_day": 3, "whys": {},
    }


# -- the pure sweep --------------------------------------------------------------


async def test_stale_protocol_is_corrected():
    db = FakeDatabase()
    _seed_intake(db, TEST_USER_ID, _WORKED_EXAMPLE)
    pid = _seed_protocol(db, TEST_USER_ID, _stale_targets())

    result = await recompute_active_protocols(db)

    assert result.scanned == 1
    assert result.corrected == 1
    assert result.unchanged == 0
    assert result.changes[0].old_kcal == 1690
    assert result.changes[0].new_kcal == 1805
    assert result.changes[0].new_version == 2

    # The active protocol is now the corrected v2; the stale v1 is deactivated (immutable).
    rows = db.tables["protocols"]
    active = [r for r in rows if r["active"]]
    assert len(active) == 1
    assert active[0]["version"] == 2
    assert active[0]["targets"]["kcal"] == 1805
    old = next(r for r in rows if r["id"] == pid)
    assert old["active"] is False
    assert old["targets"]["kcal"] == 1690  # never rewritten in place


async def test_correct_protocol_left_untouched_and_idempotent():
    db = FakeDatabase()
    _seed_intake(db, TEST_USER_ID, _WORKED_EXAMPLE)
    _seed_protocol(db, TEST_USER_ID, _correct_targets())

    first = await recompute_active_protocols(db)
    assert first.corrected == 0
    assert first.unchanged == 1
    assert len(db.tables["protocols"]) == 1  # no new version

    # Running again after a correction converges — nothing left to change.
    db2 = FakeDatabase()
    _seed_intake(db2, TEST_USER_ID, _WORKED_EXAMPLE)
    _seed_protocol(db2, TEST_USER_ID, _stale_targets())
    await recompute_active_protocols(db2)
    second = await recompute_active_protocols(db2)
    assert second.corrected == 0
    assert second.unchanged == 1


async def test_dry_run_writes_nothing():
    db = FakeDatabase()
    _seed_intake(db, TEST_USER_ID, _WORKED_EXAMPLE)
    _seed_protocol(db, TEST_USER_ID, _stale_targets())

    result = await recompute_active_protocols(db, dry_run=True)

    assert result.dry_run is True
    assert result.corrected == 1  # it WOULD correct one
    assert result.changes[0].new_kcal == 1805
    assert len(db.tables["protocols"]) == 1  # ...but wrote nothing
    assert db.tables["protocols"][0]["targets"]["kcal"] == 1690


async def test_missing_intake_is_skipped_not_guessed():
    db = FakeDatabase()
    _seed_protocol(db, TEST_USER_ID, _stale_targets())  # protocol but no intake row

    result = await recompute_active_protocols(db)

    assert result.scanned == 1
    assert result.corrected == 0
    assert result.skipped_no_intake == 1
    assert db.tables["protocols"][0]["targets"]["kcal"] == 1690  # untouched


async def test_invalid_intake_is_skipped():
    db = FakeDatabase()
    _seed_intake(db, TEST_USER_ID, {"sex": "male"})  # missing required fields -> invalid
    _seed_protocol(db, TEST_USER_ID, _stale_targets())

    result = await recompute_active_protocols(db)
    assert result.skipped_invalid_intake == 1
    assert result.corrected == 0


async def test_sweep_is_owner_scoped_per_user():
    db = FakeDatabase()
    _seed_intake(db, TEST_USER_ID, _WORKED_EXAMPLE)
    _seed_protocol(db, TEST_USER_ID, _stale_targets())
    # A second user with a female intake, also stale.
    _seed_intake(db, TEST_USER_2_ID, {**_WORKED_EXAMPLE, "sex": "female", "weight_lb": 150.0})
    _seed_protocol(db, TEST_USER_2_ID, {**_stale_targets(), "kcal": 999})

    result = await recompute_active_protocols(db)
    assert result.scanned == 2
    assert result.corrected == 2
    # Each user still owns exactly one active protocol.
    for uid in (TEST_USER_ID, TEST_USER_2_ID):
        active = [r for r in db.tables["protocols"] if r["active"] and r["user_id"] == str(uid)]
        assert len(active) == 1
        assert active[0]["version"] == 2


# -- the admin endpoint (gate + audit) -------------------------------------------


@pytest.fixture
def allowlist_admin():
    original = settings.admin_emails
    settings.admin_emails = [ADMIN_EMAIL]
    yield
    settings.admin_emails = original


@pytest.mark.usefixtures("allowlist_admin")
def test_recompute_endpoint_requires_admin(client, auth_headers):
    # A normal authenticated user (no X-Test-Admin) must be refused.
    resp = client.post("/admin/protocols/recompute", headers=auth_headers)
    assert resp.status_code == 403


@pytest.mark.usefixtures("allowlist_admin")
def test_recompute_endpoint_corrects_and_audits(client, fake_db):
    _seed_intake(fake_db, TEST_USER_ID, _WORKED_EXAMPLE)
    _seed_protocol(fake_db, TEST_USER_ID, _stale_targets())
    headers = {"X-Test-User": make_test_token(TEST_USER_ID), "X-Test-Admin": ADMIN_EMAIL}

    resp = client.post("/admin/protocols/recompute", headers=headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["corrected"] == 1
    assert body["changes"][0]["new_kcal"] == 1805

    # Audited BEFORE the sweep (#7).
    audit = fake_db.tables["admin_audit_log"]
    assert any(a["action"] == "recompute_protocols" for a in audit)


@pytest.mark.usefixtures("allowlist_admin")
def test_recompute_endpoint_dry_run_audits_distinctly(client, fake_db):
    _seed_intake(fake_db, TEST_USER_ID, _WORKED_EXAMPLE)
    _seed_protocol(fake_db, TEST_USER_ID, _stale_targets())
    headers = {"X-Test-User": make_test_token(TEST_USER_ID), "X-Test-Admin": ADMIN_EMAIL}

    resp = client.post("/admin/protocols/recompute?dry_run=true", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["dry_run"] is True
    assert fake_db.tables["protocols"][0]["targets"]["kcal"] == 1690  # unchanged
    audit = fake_db.tables["admin_audit_log"]
    assert any(a["action"] == "recompute_protocols_dry_run" for a in audit)
