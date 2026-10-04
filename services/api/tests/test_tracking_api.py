"""P2: GET/PUT /tracking — how the person follows their nutrition (decisions 57, 58, 62).

Offline (FakeDatabase). Proves: the default for an account that never chose is the five at
version 0 with source default; PUT appends versions merged with the latest; a decline joins
declined_offers with source declined; choosing a declined mode by hand clears the decline;
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
    assert body["declined_offers"] == []


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
        "/tracking", json={"decline_offer": "calories"}, headers=auth_headers
    ).json()
    assert body["mode"] == "habits"
    assert body["declined_offers"] == ["calories"]
    assert body["source"] == "declined"


def test_choosing_a_declined_mode_by_hand_clears_the_decline(client, auth_headers):
    client.put("/tracking", json={"mode": "habits"}, headers=auth_headers)
    client.put("/tracking", json={"decline_offer": "calories"}, headers=auth_headers)
    body = client.put("/tracking", json={"mode": "calories"}, headers=auth_headers).json()
    assert body["mode"] == "calories"
    assert body["declined_offers"] == []


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


def test_declining_a_focus_offer_and_adding_it_by_hand(client, auth_headers):
    client.put("/tracking", json={"mode": "calories"}, headers=auth_headers)
    body = client.put("/tracking", json={"decline_offer": "focus:protein"}, headers=auth_headers).json()
    assert body["declined_offers"] == ["focus:protein"]
    # Adding protein as a focus by hand clears the decline: the person chose it themselves.
    body = client.put("/tracking", json={"focus_metrics": ["protein"]}, headers=auth_headers).json()
    assert body["focus_metrics"] == ["protein"]
    assert body["declined_offers"] == []


def test_offerable_focus_is_what_the_mode_does_not_print(client, auth_headers):
    body = client.get("/tracking", headers=auth_headers).json()
    assert body["offerable_focus"] == ["carbs", "fat", "sugar", "sodium"]
    body = client.put("/tracking", json={"mode": "habits"}, headers=auth_headers).json()
    assert body["offerable_focus"] == ["protein", "fiber", "carbs", "fat", "sugar", "sodium"]
    body = client.put("/tracking", json={"mode": "calories"}, headers=auth_headers).json()
    assert body["offerable_focus"] == ["protein", "fiber", "water", "produce", "carbs", "fat", "sugar", "sodium"]


# -- decision 66: how much the app says, what gets in the way ------------------------------


def test_never_asked_carries_no_level_and_todays_experience(client, auth_headers):
    body = client.get("/tracking", headers=auth_headers).json()
    assert body["nudge_level"] is None
    assert body["frictions"] == []
    experience = body["experience"]
    assert experience["offers_invitations"] is True
    assert experience["evening_reminder"] is False
    assert experience["amount_checks"] == "standard"
    assert experience["bar_hint"] == "default"
    assert experience["seed_usuals"] is False


def test_the_level_and_the_frictions_ride_the_versions(client, auth_headers):
    body = client.put(
        "/tracking",
        json={"mode": "five", "nudge_level": "essential", "frictions": ["forgetting", "eating_out"]},
        headers=auth_headers,
    ).json()
    assert body["nudge_level"] == "essential"
    assert body["frictions"] == ["forgetting", "eating_out"]
    assert body["experience"]["offers_invitations"] is False
    assert body["experience"]["evening_reminder"] is True
    assert body["experience"]["bar_hint"] == "photo"
    # Changing the mode alone keeps both.
    later = client.put("/tracking", json={"mode": "macros"}, headers=auth_headers).json()
    assert later["nudge_level"] == "essential"
    assert later["frictions"] == ["forgetting", "eating_out"]
    assert later["version"] == 2


def test_an_empty_frictions_list_is_an_answer(client, auth_headers):
    client.put("/tracking", json={"frictions": ["time", "portions"]}, headers=auth_headers)
    body = client.put("/tracking", json={"frictions": []}, headers=auth_headers).json()
    assert body["frictions"] == []
    assert body["experience"]["seed_usuals"] is False
    assert body["experience"]["amount_checks"] == "standard"


def test_coach_me_is_the_one_level_that_hears_invitations(client, auth_headers):
    for level, offers in [("standard", True), ("essential", False), ("off", False)]:
        body = client.put("/tracking", json={"nudge_level": level}, headers=auth_headers).json()
        assert body["experience"]["offers_invitations"] is offers, level


def test_unknown_level_or_friction_is_rejected(client, auth_headers):
    assert client.put("/tracking", json={"nudge_level": "loud"}, headers=auth_headers).status_code == 422
    assert client.put("/tracking", json={"frictions": ["spoons"]}, headers=auth_headers).status_code == 422


# -- decision 69: when the person logs ------------------------------------------------------


def test_when_you_log_rides_the_versions_and_moves_the_checks(client, auth_headers):
    body = client.put("/tracking", json={"log_anchor": "before_bed"}, headers=auth_headers).json()
    assert body["log_anchor"] == "before_bed"
    assert body["experience"]["check_slots"] == {"late_morning": None, "evening": "20:30"}
    # The before-bed logger's evening check exists whether or not they said they forget.
    assert body["experience"]["evening_reminder"] is True
    later = client.put("/tracking", json={"mode": "macros"}, headers=auth_headers).json()
    assert later["log_anchor"] == "before_bed"
    seated = client.put("/tracking", json={"log_anchor": "when_seated"}, headers=auth_headers).json()
    assert seated["experience"]["check_slots"] == {"late_morning": "12:30", "evening": "20:00"}
    assert seated["experience"]["evening_reminder"] is False


def test_never_asked_when_you_log_keeps_todays_hours(client, auth_headers):
    body = client.get("/tracking", headers=auth_headers).json()
    assert body["log_anchor"] is None
    assert body["experience"]["check_slots"] == {"late_morning": "11:30", "evening": "20:00"}


def test_unknown_anchor_is_rejected(client, auth_headers):
    assert client.put("/tracking", json={"log_anchor": "sometimes"}, headers=auth_headers).status_code == 422
