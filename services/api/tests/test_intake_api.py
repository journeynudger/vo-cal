"""F2: /intake — versioned, append-only persistence of the deep intake.

Offline (FakeDatabase). Proves: auth required; save writes v1 then vN+1; latest returns
the newest; 404 when none; scoped per user.
"""

from __future__ import annotations


def _intake(**overrides) -> dict:
    base = {
        "age": 35,
        "sex": "male",
        "height_in": 70.0,
        "weight_lb": 200.0,
        "goal": "cut",
        "work": "desk",
        "train": "moderate",
        "kids": False,
        "med": "none",
        "stress": "moderate",
    }
    base.update(overrides)
    return base


def _save(client, headers, **overrides):
    return client.post("/intake", json={"intake": _intake(**overrides)}, headers=headers)


def test_save_requires_auth(client):
    assert _save(client, {}).status_code == 401


def test_latest_requires_auth(client):
    assert client.get("/intake/latest").status_code == 401


def test_save_writes_version_one_then_increments(client, auth_headers, fake_db):
    first = _save(client, auth_headers)
    assert first.status_code == 201
    assert first.json()["version"] == 1

    second = _save(client, auth_headers, weight_lb=195.0)
    assert second.json()["version"] == 2
    # append-only: two rows, never mutated
    assert len(fake_db.tables["intake_responses"]) == 2


def test_latest_returns_newest_intake(client, auth_headers):
    _save(client, auth_headers, weight_lb=200.0)
    _save(client, auth_headers, weight_lb=190.0)
    resp = client.get("/intake/latest", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["version"] == 2
    assert body["intake"]["weight_lb"] == 190.0


def test_latest_404_when_none(client, auth_headers):
    assert client.get("/intake/latest", headers=auth_headers).status_code == 404


def test_invalid_intake_rejected(client, auth_headers):
    assert _save(client, auth_headers, age=5).status_code == 422


def test_intake_scoped_per_user(client, auth_headers, auth_headers_user_2):
    _save(client, auth_headers, weight_lb=200.0)
    # user 2 has no intake even though user 1 does
    assert client.get("/intake/latest", headers=auth_headers_user_2).status_code == 404
    # and user 2's first save is their own v1
    assert _save(client, auth_headers_user_2).json()["version"] == 1
