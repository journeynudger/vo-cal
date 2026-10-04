"""P2: GET/PUT /tracking — how the person follows their nutrition (decisions 57, 58, 62).

Offline (FakeDatabase). Proves: the default for an account that never chose is the five at
version 0 with source default; PUT appends versions merged with the latest; a decline joins
declined_modes with source declined; choosing a declined mode by hand clears the decline;
owner scoping; auth.
"""

from __future__ import annotations


def test_tracking_requires_auth(client):
    assert client.get("/tracking").status_code == 401
    assert client.put("/tracking", json={"mode": "habits"}).status_code == 401


def test_default_is_the_five_never_chosen(client, auth_headers):
    body = client.get("/tracking", headers=auth_headers).json()
    assert body["mode"] == "five"
    assert body["version"] == 0
    assert body["source"] == "default"
    assert body["focus_metrics"] == []
    assert body["declined_modes"] == []


def test_put_appends_versions(client, auth_headers):
    first = client.put("/tracking", json={"mode": "habits"}, headers=auth_headers)
    assert first.status_code == 200, first.text
    assert first.json()["version"] == 1
    assert first.json()["mode"] == "habits"
    assert first.json()["source"] == "chosen"
    second = client.put("/tracking", json={"mode": "calories"}, headers=auth_headers).json()
    assert second["version"] == 2
    assert client.get("/tracking", headers=auth_headers).json()["mode"] == "calories"


def test_put_focus_only_keeps_the_mode(client, auth_headers):
    client.put("/tracking", json={"mode": "habits"}, headers=auth_headers)
    body = client.put(
        "/tracking", json={"focus_metrics": ["sugar", "fiber"]}, headers=auth_headers
    ).json()
    assert body["mode"] == "habits"
    assert body["focus_metrics"] == ["sugar", "fiber"]
    assert body["version"] == 2


def test_decline_records_the_mode_never_to_offer(client, auth_headers):
    client.put("/tracking", json={"mode": "habits"}, headers=auth_headers)
    body = client.put(
        "/tracking", json={"decline_mode": "calories"}, headers=auth_headers
    ).json()
    assert body["mode"] == "habits"
    assert body["declined_modes"] == ["calories"]
    assert body["source"] == "declined"


def test_choosing_a_declined_mode_by_hand_clears_the_decline(client, auth_headers):
    client.put("/tracking", json={"mode": "habits"}, headers=auth_headers)
    client.put("/tracking", json={"decline_mode": "calories"}, headers=auth_headers)
    body = client.put("/tracking", json={"mode": "calories"}, headers=auth_headers).json()
    assert body["mode"] == "calories"
    assert body["declined_modes"] == []


def test_invited_source_is_recorded(client, auth_headers):
    body = client.put(
        "/tracking", json={"mode": "calories", "source": "invited"}, headers=auth_headers
    ).json()
    assert body["source"] == "invited"


def test_unknown_mode_is_422(client, auth_headers):
    assert client.put("/tracking", json={"mode": "keto"}, headers=auth_headers).status_code == 422


def test_tracking_is_scoped_to_the_caller(client, auth_headers, auth_headers_user_2):
    client.put("/tracking", json={"mode": "macros"}, headers=auth_headers)
    other = client.get("/tracking", headers=auth_headers_user_2).json()
    assert other["mode"] == "five"
    assert other["version"] == 0
