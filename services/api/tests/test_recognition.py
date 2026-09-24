"""A repeated meal is recognized by its name or its items (meals/recognition.py), offered
on the parse result, and a confirmed recognition names the meal after the usual.

Candidates are usuals only: a name the person gave. Auto-named meals never interrupt.
"""

from __future__ import annotations

from api.meals.naming import NAME_SOURCE_RECOGNIZED
from api.meals.recognition import NamedMeal, recognize

from .conftest import confirmed_items, parse_transcript

SMOOTHIE = NamedMeal(id="u1", name="Metal detox smoothie", item_names=("banana", "spinach", "protein powder", "almond milk"))
OATS = NamedMeal(id="u2", name="Overnight oats", item_names=("oats", "milk", "chia seeds"))
BEEF = NamedMeal(id="u3", name="Beef bowl", item_names=("beef",))


# -- the pure rules -----------------------------------------------------------------


def test_recognized_by_name_in_the_transcript() -> None:
    hit = recognize("had my metal detox smoothie this morning", ["metal detox smoothie"], [SMOOTHIE, OATS])
    assert hit is not None
    assert hit.meal is SMOOTHIE
    assert hit.reason == "name"


def test_recognized_by_name_as_a_parsed_item_even_when_the_transcript_differs() -> None:
    hit = recognize("the usual detox thing", ["my metal detox smoothie recipe"], [SMOOTHIE])
    assert hit is not None
    assert hit.reason == "name"


def test_recognized_by_items_needs_real_overlap() -> None:
    hit = recognize("banana spinach protein powder and almond milk", ["banana", "spinach", "protein powder", "almond milk"], [SMOOTHIE, OATS])
    assert hit is not None
    assert hit.meal is SMOOTHIE
    assert hit.reason == "items"
    assert hit.score == 1.0
    # Three of four shared, one extra: 3/5 = 0.6, still a match.
    assert recognize("", ["banana", "spinach", "protein powder", "honey"], [SMOOTHIE]) is not None
    # One shared item out of many is not that meal.
    assert recognize("", ["banana", "toast"], [SMOOTHIE]) is None
    # A one-item meal matches a one-item usual exactly.
    assert recognize("", ["beef"], [BEEF]) is not None
    assert recognize("", ["beef", "rice", "broccoli"], [BEEF]) is None


def test_name_beats_items_and_the_longer_name_wins() -> None:
    short = NamedMeal(id="s", name="Smoothie", item_names=("banana",))
    hit = recognize("my metal detox smoothie", ["metal detox smoothie"], [short, SMOOTHIE])
    assert hit is not None
    assert hit.meal is SMOOTHIE


def test_no_candidates_or_tiny_names_never_match() -> None:
    assert recognize("egg and toast", ["egg", "toast"], []) is None
    # A two-letter name can never match by name (it would match every "my ..."); its items
    # still can, so give it different ones to isolate the rule.
    tiny = NamedMeal(id="t", name="my", item_names=("toast",))
    assert recognize("my egg", ["egg"], [tiny]) is None


# -- the API ------------------------------------------------------------------------


def _log_named(client, headers, transcript: str, name: str, client_meal_id: str) -> dict:
    parsed = parse_transcript(client, headers, transcript)
    resp = client.post(
        "/meals",
        json={"client_meal_id": client_meal_id, "parse_id": parsed["parse_id"], "items": confirmed_items(parsed)},
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    meal = resp.json()
    renamed = client.patch(f"/meals/{meal['id']}/name", json={"name": name}, headers=headers)
    assert renamed.status_code == 200, renamed.text
    return meal


def test_parse_offers_the_usual_by_name_and_confirm_takes_its_name(client, auth_headers, fake_db):
    _log_named(client, auth_headers, "4oz 93/7 beef", "Beef bowl", "m-rec-1")
    parsed = parse_transcript(client, auth_headers, "my beef bowl")
    offered = parsed["recognized_meal"]
    assert offered is not None
    assert offered["name"] == "Beef bowl"
    assert offered["reason"] == "name"
    assert offered["items"][0]["name"] == "ground beef"  # as the parse fixture names it
    assert offered["totals"]["kcal"] > 0

    # Yes: the client logs the usual's items and points at the usual.
    resp = client.post(
        "/meals",
        json={
            "client_meal_id": "m-rec-2",
            "parse_id": parsed["parse_id"],
            "recognized_meal_id": offered["id"],
            "items": offered["items"],
        },
        headers=auth_headers,
    )
    assert resp.status_code == 201, resp.text
    assert resp.json()["name"] == "Beef bowl"
    assert resp.json()["totals"]["kcal"] > 0
    rows = sorted(fake_db.tables["meal_logs"], key=lambda r: r["created_at"] if r.get("created_at") else "")
    assert rows[-1]["name_source"] == NAME_SOURCE_RECOGNIZED


def test_parse_offers_the_usual_by_items(client, auth_headers):
    _log_named(client, auth_headers, "4oz 93/7 beef", "Post-run beef", "m-rec-3")
    parsed = parse_transcript(client, auth_headers, "4oz 93/7 beef")
    assert parsed["recognized_meal"] is not None
    assert parsed["recognized_meal"]["reason"] == "items"


def test_an_auto_named_meal_is_never_offered(client, auth_headers):
    parsed = parse_transcript(client, auth_headers, "4oz 93/7 beef")
    resp = client.post(
        "/meals",
        json={"client_meal_id": "m-rec-4", "parse_id": parsed["parse_id"], "items": confirmed_items(parsed)},
        headers=auth_headers,
    )
    assert resp.status_code == 201
    again = parse_transcript(client, auth_headers, "4oz 93/7 beef")
    assert again["recognized_meal"] is None


def test_recognized_meal_id_must_be_the_persons_own(client, auth_headers, auth_headers_user_2):
    _log_named(client, auth_headers, "4oz 93/7 beef", "Beef bowl", "m-rec-5")
    usual = client.get("/meals/usuals", headers=auth_headers).json()[0]
    parsed = parse_transcript(client, auth_headers_user_2, "4oz 93/7 beef")
    resp = client.post(
        "/meals",
        json={"client_meal_id": "m-rec-6", "parse_id": parsed["parse_id"], "recognized_meal_id": usual["id"], "items": confirmed_items(parsed)},
        headers=auth_headers_user_2,
    )
    assert resp.status_code == 404
