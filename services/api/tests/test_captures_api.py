"""C4: /captures upload tests (offline — FakeStorage + FakeDatabase).

Audio is the ground-truth artifact; upload is idempotent by client_capture_id and
only acks 'uploaded' after both blob and row land.
"""

from __future__ import annotations

CAF = b"caf-bytes-pretend-audio" * 100


def _upload(client, headers, *, cid="cap-1", data=CAF):
    return client.post(
        "/captures",
        files={"audio": ("voice.caf", data, "audio/x-caf")},
        data={"client_capture_id": cid, "duration_ms": "4200", "device": "sim"},
        headers=headers,
    )


def test_upload_requires_auth(client):
    assert _upload(client, {}).status_code == 401


def test_upload_stores_blob_and_row(client, auth_headers, fake_storage, fake_db):
    resp = _upload(client, auth_headers)
    assert resp.status_code == 201
    body = resp.json()
    assert body["status"] == "uploaded"
    assert body["deduped"] is False
    # blob durably stored and a captures row committed
    assert len(fake_storage.blobs) == 1
    assert len(fake_db.tables["captures"]) == 1


def test_upload_is_idempotent(client, auth_headers, fake_storage):
    first = _upload(client, auth_headers, cid="dup").json()
    second = _upload(client, auth_headers, cid="dup").json()
    assert first["id"] == second["id"]
    assert second["deduped"] is True
    assert len(fake_storage.blobs) == 1  # not re-stored


def test_empty_audio_rejected(client, auth_headers):
    assert _upload(client, auth_headers, data=b"").status_code == 422


def test_get_capture_status(client, auth_headers):
    cid = _upload(client, auth_headers, cid="status-1").json()["id"]
    resp = client.get(f"/captures/{cid}", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["status"] == "uploaded"


def test_capture_scoped_per_user(client, auth_headers, auth_headers_user_2):
    cid = _upload(client, auth_headers, cid="owned").json()["id"]
    # user 2 cannot read user 1's capture
    assert client.get(f"/captures/{cid}", headers=auth_headers_user_2).status_code == 404


def test_rejects_unsafe_client_capture_id(client, auth_headers):
    # path-traversal-ish ids must be rejected (they become part of the storage key)
    resp = client.post(
        "/captures",
        files={"audio": ("voice.caf", CAF, "audio/x-caf")},
        data={"client_capture_id": "../22222222-2222-2222-2222-222222222222/evil"},
        headers=auth_headers,
    )
    assert resp.status_code == 422
