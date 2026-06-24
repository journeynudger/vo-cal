"""I2: DELETE /account — total, owner-scoped data deletion (App Review 5.1.1(v)).

Offline (FakeDatabase + FakeStorage; the auth-user delete is a no-op under test_mode).
Proves: auth required; a user's rows + audio blobs are purged; another user is untouched.
"""

from __future__ import annotations

CAF = b"caf-bytes-pretend-audio" * 50


def _intake() -> dict:
    return {
        "age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0,
        "goal": "cut", "work": "desk", "train": "moderate", "kids": False,
        "med": "none", "stress": "moderate",
    }


def _seed(client, headers, cid="cap-1"):
    client.post("/intake", json={"intake": _intake()}, headers=headers)
    client.post(
        "/captures",
        files={"audio": ("voice.caf", CAF, "audio/x-caf")},
        data={"client_capture_id": cid},
        headers=headers,
    )


def test_delete_requires_auth(client):
    assert client.delete("/account").status_code == 401


def test_delete_purges_user_rows_and_blobs(client, auth_headers, fake_db, fake_storage):
    _seed(client, auth_headers)
    assert len(fake_db.tables["intake_responses"]) == 1
    assert len(fake_db.tables["captures"]) == 1
    assert len(fake_storage.blobs) == 1

    resp = client.delete("/account", headers=auth_headers)
    assert resp.status_code == 204

    assert fake_db.tables.get("intake_responses", []) == []
    assert fake_db.tables.get("captures", []) == []
    assert fake_storage.blobs == {}


def test_delete_is_scoped_to_caller(client, auth_headers, auth_headers_user_2, fake_db, fake_storage):
    _seed(client, auth_headers, cid="u1")
    _seed(client, auth_headers_user_2, cid="u2")

    client.delete("/account", headers=auth_headers)

    # user 2's data survives intact
    assert len(fake_db.tables.get("intake_responses", [])) == 1
    assert len(fake_db.tables.get("captures", [])) == 1
    assert len(fake_storage.blobs) == 1
