"""Phase H admin review API tests (offline — FakeDatabase + FakeStorage).

Proves the load-bearing properties: the allowlist gate (non-admin -> 403), the
audit-on-every-detail-read invariant (#7), signed audio URL on the chain, review
insert, and aggregates math on seeded fixtures.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from api.config import settings
from api.dependencies import make_test_token

from .conftest import TEST_USER_ID

ADMIN_EMAIL = "admin@vocal.test"


@pytest.fixture(autouse=True)
def _allowlist() -> object:
    """Put ADMIN_EMAIL on the server-side allowlist for the duration of a test."""
    original = settings.admin_emails
    settings.admin_emails = [ADMIN_EMAIL]
    yield
    settings.admin_emails = original


@pytest.fixture
def admin_headers() -> dict[str, str]:
    """Authenticate as a normal user AND assert admin via X-Test-Admin."""
    return {
        "X-Test-User": make_test_token(TEST_USER_ID),
        "X-Test-Admin": ADMIN_EMAIL,
    }


def _seed(db, *, meal_id, parse_id, confidence, questions, corrections, logged_at=None):
    """Insert a parse + meal_log (+ corrections) directly through the seam."""
    logged_at = logged_at or datetime.now(UTC)
    items = [{"name": "chicken", "grams": 100.0, "macros": {"kcal": 165.0}}]
    db.tables.setdefault("parses", []).append(
        {
            "id": parse_id,
            "user_id": str(TEST_USER_ID),
            "capture_id": None,
            "payload": {
                "parsed_meal": {"items": items},
                "result": {"items": items, "questions": questions},
            },
        }
    )
    db.tables.setdefault("meal_logs", []).append(
        {
            "id": meal_id,
            "user_id": str(TEST_USER_ID),
            "parse_id": parse_id,
            "name": "Lunch",
            "meal_type": "lunch",
            "items": items,
            "totals": {"kcal": 165.0},
            "confidence": confidence,
            "logged_at": logged_at.isoformat(),
        }
    )
    for i, field in enumerate(corrections):
        db.tables.setdefault("corrections", []).append(
            {
                "id": f"corr-{meal_id}-{i}",
                "meal_log_id": meal_id,
                "item_index": 0,
                "field": field,
                "parsed_value": "x",
                "confirmed_value": "y",
            }
        )


# -- the gate is provable ----------------------------------------------------


def test_non_admin_jwt_gets_403(client, auth_headers):
    """A normal authenticated user (no X-Test-Admin) cannot reach /admin/*."""
    assert client.get("/admin/logs", headers=auth_headers).status_code == 403
    assert client.get("/admin/aggregates", headers=auth_headers).status_code == 403
    assert client.get("/admin/logs/anything", headers=auth_headers).status_code == 403


def test_unauthenticated_gets_401(client):
    assert client.get("/admin/logs").status_code == 401


def test_non_allowlisted_email_gets_403(client, auth_headers):
    """An email that is NOT on the allowlist is rejected even via the test seam."""
    headers = {**auth_headers, "X-Test-Admin": "stranger@nope.test"}
    assert client.get("/admin/logs", headers=headers).status_code == 403


def test_admin_can_list_logs(client, admin_headers, fake_db):
    _seed(fake_db, meal_id="m1", parse_id="p1", confidence=0.6, questions=[], corrections=[])
    resp = client.get("/admin/logs", headers=admin_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body) == 1
    assert body[0]["id"] == "m1"


# -- detail chain + signed url + audit ---------------------------------------


def test_admin_reads_chain_with_signed_url(client, admin_headers, fake_db, fake_storage):
    _seed(fake_db, meal_id="m1", parse_id="p1", confidence=0.9, questions=[], corrections=["amount"])
    # A capture with audio_path, plus the blob in storage so signed_url is non-empty.
    fake_db.tables["captures"] = [{"id": "cap1", "audio_path": "u/cap1.caf"}]
    fake_db.tables["parses"][0]["capture_id"] = "cap1"
    fake_storage.blobs[("capture-audio", "u/cap1.caf")] = b"audio"

    resp = client.get("/admin/logs/m1", headers=admin_headers)
    assert resp.status_code == 200
    chain = resp.json()
    assert chain["meal_log_id"] == "m1"
    assert chain["signed_audio_url"]  # present + non-empty
    assert "ttl=300" in chain["signed_audio_url"]
    assert chain["corrections"][0]["field"] == "amount"
    assert chain["parse_result"]["items"]


def test_every_detail_read_writes_audit(client, admin_headers, fake_db):
    _seed(fake_db, meal_id="m1", parse_id="p1", confidence=0.5, questions=[], corrections=[])
    assert "admin_audit_log" not in fake_db.tables or not fake_db.tables["admin_audit_log"]
    client.get("/admin/logs/m1", headers=admin_headers)
    client.get("/admin/logs/m1", headers=admin_headers)
    audit = fake_db.tables["admin_audit_log"]
    assert len(audit) == 2  # one row per detail read
    assert all(r["action"] == "read_log_chain" for r in audit)
    assert all(r["admin_email"] == ADMIN_EMAIL for r in audit)
    assert all(r["subject_id"] == "m1" for r in audit)


def test_detail_404_for_missing_log_still_audits(client, admin_headers, fake_db):
    resp = client.get("/admin/logs/ghost", headers=admin_headers)
    assert resp.status_code == 404
    # The access attempt is recorded even though assembly found nothing.
    assert len(fake_db.tables["admin_audit_log"]) == 1


# -- review insert -----------------------------------------------------------


def test_admin_inserts_review(client, admin_headers, fake_db):
    _seed(fake_db, meal_id="m1", parse_id="p1", confidence=0.7, questions=[], corrections=[])
    resp = client.post(
        "/admin/logs/m1/review",
        json={"verdict": "parse_wrong_amount", "notes": "rice was 2 cups not 1"},
        headers=admin_headers,
    )
    assert resp.status_code == 201
    body = resp.json()
    assert body["verdict"] == "parse_wrong_amount"
    assert body["reviewer"] == ADMIN_EMAIL
    rows = fake_db.tables["admin_reviews"]
    assert len(rows) == 1
    assert rows[0]["meal_log_id"] == "m1"


def test_review_rejects_bad_verdict(client, admin_headers, fake_db):
    _seed(fake_db, meal_id="m1", parse_id="p1", confidence=0.7, questions=[], corrections=[])
    resp = client.post(
        "/admin/logs/m1/review",
        json={"verdict": "made_up", "notes": None},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_review_404_for_missing_log(client, admin_headers):
    resp = client.post(
        "/admin/logs/ghost/review",
        json={"verdict": "parse_ok"},
        headers=admin_headers,
    )
    assert resp.status_code == 404


# -- aggregates math ---------------------------------------------------------


def test_aggregates_correction_and_calibration(client, admin_headers, fake_db):
    # Two meals: one high-confidence corrected, one high-confidence clean.
    base = datetime(2026, 6, 1, tzinfo=UTC)
    _seed(
        fake_db, meal_id="m1", parse_id="p1", confidence=0.9,
        questions=[{"field": "items[0].amount"}], corrections=["amount"], logged_at=base,
    )
    _seed(
        fake_db, meal_id="m2", parse_id="p2", confidence=0.95,
        questions=[], corrections=[], logged_at=base + timedelta(days=1),
    )
    resp = client.get("/admin/aggregates", headers=admin_headers)
    assert resp.status_code == 200
    agg = resp.json()

    # Correction rate that week: 1 corrected item / 2 total items = 0.5.
    week = agg["correction_rate_by_week"][0]
    assert week["items"] == 2
    assert week["corrected"] == 1
    assert week["rate"] == 0.5

    # Calibration: the 0.9-1.0 bucket has 2 meals, 1 corrected -> 0.5 observed.
    top_bucket = next(b for b in agg["confidence_calibration"] if b["bucket"] == "0.9-1.0")
    assert top_bucket["meals"] == 2
    assert top_bucket["observed_correction_rate"] == 0.5

    # Question precision: 1 meal asked, that meal was corrected -> 1.0.
    assert agg["question_precision"]["meals_with_questions"] == 1
    assert agg["question_precision"]["precision"] == 1.0

    # Dictionary gap: chicken corrected once.
    assert agg["top_corrected_foods"][0]["food"] == "chicken"
    assert agg["top_corrected_foods"][0]["corrections"] == 1
