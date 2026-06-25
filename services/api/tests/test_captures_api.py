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


def test_concurrent_duplicate_upload_is_idempotent(
    client, auth_headers, fake_storage, fake_db, monkeypatch
):
    # RT-08: upload is a non-atomic check-then-insert. Two replays with the same
    # client_capture_id can both pass get_by_client_id (None) before either commits;
    # the second insert then hits the unique index. The endpoint must catch that and
    # return the deduped row — never a 500 a retry loop can wedge on.
    from api.captures import store as store_mod

    first = _upload(client, auth_headers, cid="race").json()
    assert len(fake_db.tables["captures"]) == 1

    # Force the SECOND request to behave as if its dedup check ran before the first
    # row committed: get_by_client_id returns None on its next call only, so we fall
    # through to insert and collide with the unique index (the race window).
    real_get = store_mod.CapturesStore.get_by_client_id
    calls = {"n": 0}

    async def flaky_get(self, user_id, client_capture_id):
        calls["n"] += 1
        if calls["n"] == 1:
            return None
        return await real_get(self, user_id, client_capture_id)

    monkeypatch.setattr(store_mod.CapturesStore, "get_by_client_id", flaky_get)

    resp = _upload(client, auth_headers, cid="race")
    assert resp.status_code == 201
    body = resp.json()
    assert body["deduped"] is True
    assert body["id"] == first["id"]
    assert len(fake_db.tables["captures"]) == 1  # no duplicate row
    assert len(fake_storage.blobs) == 1  # blob keyed by path, not re-stored


def test_empty_audio_rejected(client, auth_headers):
    assert _upload(client, auth_headers, data=b"").status_code == 422


def test_get_capture_status(client, auth_headers):
    cid = _upload(client, auth_headers, cid="status-1").json()["id"]
    resp = client.get(f"/captures/{cid}", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["status"] == "uploaded"


def test_get_capture_non_uuid_is_404_not_500(client, auth_headers):
    # A non-UUID path id must be a clean 404, never an uncaught ValueError → 500 (RT-29/47).
    assert client.get("/captures/not-a-uuid", headers=auth_headers).status_code == 404


def test_upload_rejects_dot_only_client_id(client, auth_headers):
    # "." / ".." make degenerate storage keys; the charset requires a leading alphanumeric (RT-46).
    assert _upload(client, auth_headers, cid="..").status_code == 422
    assert _upload(client, auth_headers, cid=".").status_code == 422


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
