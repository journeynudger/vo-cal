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


def test_delete_account_is_idempotent_on_retry(client, auth_headers, fake_db, fake_storage):
    # Deletion is delete-what-exists across three systems (Storage, DB rows, auth identity),
    # so it can't be atomic — its safety property is convergence on RETRY. A second DELETE after
    # a (simulated) partial failure must be a clean no-op that still returns 204, never a 500 on
    # an already-empty account. This locks the property the recalibration of a half-delete relies on.
    _seed(client, auth_headers)
    assert client.delete("/account", headers=auth_headers).status_code == 204
    assert client.delete("/account", headers=auth_headers).status_code == 204
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


# -- red-team regressions -----------------------------------------------------


class _StubBucket:
    """Mimics storage3's paginated .list(): honors limit/offset, caps each page at `page`."""

    def __init__(self, names: list[str], page: int = 100):
        self._names = names
        self._page = page

    async def list(self, prefix, options):
        offset = options["offset"]
        limit = min(options["limit"], self._page)
        return [{"name": n} for n in self._names[offset : offset + limit]]


class _StubStorageClient:
    def __init__(self, names: list[str], page: int = 100):
        self._bucket = _StubBucket(names, page)

    @property
    def storage(self):
        return self

    def from_(self, _bucket):
        return self._bucket


async def test_supabase_storage_list_paginates_past_one_page():
    # 250 blobs with a 100/page server cap must all be returned (account deletion depends on it).
    from api.storage import CAPTURE_AUDIO_BUCKET, SupabaseStorage

    names = [f"cap{i}.caf" for i in range(250)]
    storage = SupabaseStorage(_StubStorageClient(names, page=100))
    paths = await storage.list(CAPTURE_AUDIO_BUCKET, "user-1")
    assert len(paths) == 250
    assert paths[0] == "user-1/cap0.caf"
    assert paths[-1] == "user-1/cap249.caf"


def test_delete_purges_transcripts_and_corrections(client, auth_headers, fake_db):
    capture_id = _seed_intake_and_capture(client, auth_headers)
    # seed a transcript (no user_id) + a logged meal with a correction (no user_id)
    fake_db.tables.setdefault("transcripts", []).append(
        {"id": "t1", "capture_id": capture_id, "provider": "fake", "text": "two eggs"}
    )
    fake_db.tables.setdefault("meal_logs", []).append(
        {"id": "m1", "user_id": "11111111-1111-1111-1111-111111111111"}
    )
    fake_db.tables.setdefault("corrections", []).append({"id": "c1", "meal_log_id": "m1"})

    assert client.delete("/account", headers=auth_headers).status_code == 204
    assert fake_db.tables.get("transcripts", []) == []
    assert fake_db.tables.get("corrections", []) == []


def _seed_intake_and_capture(client, headers) -> str:
    client.post("/intake", json={"intake": _intake()}, headers=headers)
    return client.post(
        "/captures",
        files={"audio": ("voice.caf", CAF, "audio/x-caf")},
        data={"client_capture_id": "cap-x"},
        headers=headers,
    ).json()["id"]
