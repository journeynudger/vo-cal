"""Phase G: checkin API (offline — FakeDatabase + X-Test-User seam).

Covers: store a check-in, due logic (never-checked-in vs recent), the live
situational nudge from this week's meal_logs, auth, and per-user RLS scoping.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta


def _checkin_body(**over) -> dict:
    body = {"weight_kg": 80.0, "hunger": 3, "energy": 3, "adherence_self": 4, "notes": "ok week"}
    body.update(over)
    return body


def _log_meal(client, headers, *, cid, logged_at: datetime):
    """Log a minimal meal at a specific time (drives nudge signals)."""
    return client.post(
        "/meals",
        json={
            "client_meal_id": cid,
            "meal_type": "lunch",
            "logged_at": logged_at.isoformat(),
            "items": [
                {
                    "name": "rice",
                    "grams": 100.0,
                    "macros": {
                        "kcal": 130.0,
                        "protein": 2.7,
                        "carbs": 28.0,
                        "fat": 0.3,
                        "fiber": 0.4,
                    },
                    "confidence": 0.9,
                }
            ],
        },
        headers=headers,
    )


# -- auth ---------------------------------------------------------------------


def test_create_checkin_requires_auth(client):
    assert client.post("/checkin/checkins", json=_checkin_body()).status_code == 401


def test_due_requires_auth(client):
    assert client.get("/checkin/checkins/due").status_code == 401


def test_current_nudge_requires_auth(client):
    assert client.get("/checkin/nudges/current").status_code == 401


# -- store a check-in ---------------------------------------------------------


def test_create_checkin_persists_row(client, auth_headers, fake_db):
    resp = client.post("/checkin/checkins", json=_checkin_body(), headers=auth_headers)
    assert resp.status_code == 201
    body = resp.json()
    assert body["weight_kg"] == 80.0
    assert body["adherence_self"] == 4
    assert "id" in body
    assert len(fake_db.tables["checkins"]) == 1


# -- due logic ----------------------------------------------------------------


def test_due_true_when_never_checked_in(client, auth_headers):
    resp = client.get("/checkin/checkins/due", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["due"] is True
    assert body["days_since_last"] is None
    assert "is_mid_week" in body


def test_due_false_right_after_checkin(client, auth_headers):
    client.post("/checkin/checkins", json=_checkin_body(), headers=auth_headers)
    body = client.get("/checkin/checkins/due", headers=auth_headers).json()
    # Just checked in → not due again yet (cadence is several days).
    assert body["due"] is False
    assert body["days_since_last"] == 0


def test_due_true_when_last_checkin_is_old(client, auth_headers, fake_db, test_user_id):
    # Insert a check-in dated well in the past directly into the fake DB.
    old = (datetime.now(UTC) - timedelta(days=10)).isoformat()
    fake_db.tables.setdefault("checkins", []).append(
        {
            "id": "00000000-0000-0000-0000-0000000000aa",
            "user_id": str(test_user_id),
            "weight_kg": 80.0,
            "created_at": old,
        }
    )
    body = client.get("/checkin/checkins/due", headers=auth_headers).json()
    assert body["due"] is True
    assert body["days_since_last"] == 10


# -- current nudge (computed from this week's meal_logs) ----------------------


def test_nudge_no_log_today_when_no_meals(client, auth_headers):
    body = client.get("/checkin/nudges/current", headers=auth_headers).json()
    # No meals at all this week → never-logged → the "rough day?" nudge.
    assert body["trigger"] == "no_log_today"
    assert body["branch_options"]


def test_nudge_reflects_recent_log(client, auth_headers):
    # A meal logged moments ago → not the no-log nudge; with one fresh day this
    # week the engine returns a structured nudge (mid-week-slipping or all-clear).
    _log_meal(client, auth_headers, cid="fresh-1", logged_at=datetime.now(UTC))
    body = client.get("/checkin/nudges/current", headers=auth_headers).json()
    assert body["trigger"] != "no_log_today"
    assert "message" in body


# -- RLS / per-user scoping ---------------------------------------------------


def test_checkins_scoped_per_user(client, auth_headers, auth_headers_user_2):
    client.post("/checkin/checkins", json=_checkin_body(), headers=auth_headers)
    # User 2 has no check-in → still "never checked in" / due.
    body = client.get("/checkin/checkins/due", headers=auth_headers_user_2).json()
    assert body["due"] is True
    assert body["days_since_last"] is None


def test_nudge_signals_scoped_per_user(client, auth_headers, auth_headers_user_2):
    # User 1 logs a fresh meal; user 2 has none → user 2 still sees no-log-today.
    _log_meal(client, auth_headers, cid="u1-only", logged_at=datetime.now(UTC))
    body = client.get("/checkin/nudges/current", headers=auth_headers_user_2).json()
    assert body["trigger"] == "no_log_today"
