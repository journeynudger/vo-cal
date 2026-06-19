"""F3: /protocols endpoint tests (offline — FakeDatabase + X-Test-User seam).

generate -> active round trip, versioned superseding, RLS scoping, auth required.
The engine math is pinned in test_protocol_engine.py; here we prove the route wires
compute -> store-active -> serve in the iOS ProtocolTargets shape (camelCase keys).
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


def _generate(client, headers, **overrides):
    body = {"intake": _intake(**overrides)}
    return client.post("/protocols/generate", json=body, headers=headers)


def test_generate_requires_auth(client):
    assert _generate(client, {}).status_code == 401


def test_active_requires_auth(client):
    assert client.get("/protocols/active").status_code == 401


def test_generate_returns_ios_shape(client, auth_headers):
    resp = _generate(client, auth_headers)
    assert resp.status_code == 201
    body = resp.json()
    assert body["version"] == 1
    assert body["active"] is True
    assert body["protocol_id"]
    t = body["targets"]
    # iOS VoCalCore.ProtocolTargets shape: snake_case meals_per_day + whys dict.
    assert t["kcal"] == 1971
    assert t["protein"] == 181
    assert t["meals_per_day"] == 3
    assert t["water_oz"] == 100
    assert t["produce_servings"] == 5
    assert isinstance(t["whys"], dict)
    assert t["whys"]["kcal"].strip()


def test_active_404_before_any_generate(client, auth_headers):
    assert client.get("/protocols/active", headers=auth_headers).status_code == 404


def test_generate_then_active_round_trip(client, auth_headers):
    generated = _generate(client, auth_headers).json()
    active = client.get("/protocols/active", headers=auth_headers).json()
    assert active["protocol_id"] == generated["protocol_id"]
    assert active["version"] == generated["version"]
    assert active["targets"]["kcal"] == generated["targets"]["kcal"]
    assert active["targets"]["whys"]["kcal"] == generated["targets"]["whys"]["kcal"]


def test_regenerate_supersedes_and_keeps_one_active(client, auth_headers, fake_db):
    first = _generate(client, auth_headers).json()
    # A different intake produces a different target and a new version.
    second = _generate(client, auth_headers, train="heavy", stress="high").json()
    assert second["version"] == 2
    assert second["targets"]["kcal"] != first["targets"]["kcal"]

    rows = fake_db.tables["protocols"]
    assert len(rows) == 2
    active_rows = [r for r in rows if r["active"]]
    assert len(active_rows) == 1  # one-active invariant holds
    assert active_rows[0]["version"] == 2
    # The new active row supersedes the first.
    assert active_rows[0]["supersedes"] == first["protocol_id"]

    # /active now returns v2.
    active = client.get("/protocols/active", headers=auth_headers).json()
    assert active["version"] == 2
    assert active["protocol_id"] == second["protocol_id"]


def test_stored_targets_carry_matching_version(client, auth_headers, fake_db):
    _generate(client, auth_headers).json()
    _generate(client, auth_headers, train="heavy").json()
    for row in fake_db.tables["protocols"]:
        # The embedded targets jsonb version must equal the row's version column.
        assert row["targets"]["version"] == row["version"]


def test_protocols_scoped_per_user(client, auth_headers, auth_headers_user_2):
    _generate(client, auth_headers).json()
    # User 2 has no protocol of their own.
    assert client.get("/protocols/active", headers=auth_headers_user_2).status_code == 404
    # User 2 generates their own, distinct from user 1's.
    mine = _generate(client, auth_headers_user_2, sex="female", weight_lb=140.0).json()
    theirs = client.get("/protocols/active", headers=auth_headers).json()
    assert mine["protocol_id"] != theirs["protocol_id"]
    assert mine["targets"]["kcal"] != theirs["targets"]["kcal"]


def test_regenerate_per_user_is_independent(client, auth_headers, auth_headers_user_2, fake_db):
    _generate(client, auth_headers)
    _generate(client, auth_headers, train="heavy")  # user 1 now at v2
    _generate(client, auth_headers_user_2, sex="female", weight_lb=140.0)  # user 2 at v1

    u2_active = client.get("/protocols/active", headers=auth_headers_user_2).json()
    assert u2_active["version"] == 1  # user 1's revision did not bump user 2

    # Exactly one active row per user.
    actives = [r for r in fake_db.tables["protocols"] if r["active"]]
    assert len(actives) == 2


def test_invalid_intake_is_422(client, auth_headers):
    # age below the schema minimum is a validation error, not a 500.
    resp = client.post(
        "/protocols/generate", json={"intake": _intake(age=5)}, headers=auth_headers
    )
    assert resp.status_code == 422
