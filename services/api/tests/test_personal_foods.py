"""Personal foods (nutritionist brief, 2026-09-23): the foods no database has.

A label food carries the numbers as printed; a batch food is the sum of its resolved
ingredients divided by the servings it makes; both are priced by name on every later parse,
ahead of every database, with the person's numbers and no estimate flag. Retiring one is a
mark; a meal priced with it keeps its identity.
"""

from __future__ import annotations

from api.foods.index import PersonalFoodIndex, spoken_key
from api.foods.schemas import kcal_from_macros

from .conftest import confirmed_items, parse_transcript

LABEL = {
    "name": "Street taco chicken",
    "per_serving": {"protein": 24, "carbs": 3, "fat": 5},
    "serving_grams": 113.4,
    "servings_per_package": 2,
    "aliases": ["taco chicken"],
}


def _save_label(client, headers, **overrides):
    body = {**LABEL, **overrides}
    resp = client.post("/foods/personal", json=body, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def test_spoken_key_strips_the_ways_people_name_their_own_food() -> None:
    assert spoken_key("My Chili Recipe") == "chili"
    assert spoken_key("a serving of my chili") == "chili"
    assert spoken_key("chili") == "chili"
    assert spoken_key("my") == "my"


def test_label_food_computes_calories_from_macros_when_not_printed(client, auth_headers):
    food = _save_label(client, auth_headers)
    assert food["per_serving"]["kcal"] == kcal_from_macros(24, 3, 5) == 153.0
    assert food["source"] == "label"
    assert food["aliases"] == ["taco chicken"]
    printed = _save_label(client, auth_headers, name="Fire braised chicken", per_serving={"kcal": 140, "protein": 24, "carbs": 0, "fat": 5})
    assert printed["per_serving"]["kcal"] == 140  # a printed label is kept as printed


def test_index_prices_a_label_food_per_serving_and_by_weight(client, auth_headers):
    _save_label(client, auth_headers, name="ground beef", serving_grams=113.4)
    parsed = parse_transcript(client, auth_headers)  # "4oz 93/7 beef" -> ground beef, 4 oz
    item = parsed["items"][0]
    assert item["personal_food_id"]
    assert item["source"] == "manual"
    assert item["is_estimate"] is False
    # 4 oz = 113.4 g = exactly one declared serving.
    assert item["macros"]["protein"] == 24.0
    assert item["macros"]["kcal"] == 153.0
    assert item["confidence"] >= 0.9


def test_index_prices_an_unweighed_food_by_servings(client, auth_headers):
    _save_label(client, auth_headers, name="pasta", serving_grams=None, per_serving={"kcal": 400, "protein": 14, "carbs": 70, "fat": 6})
    parsed = parse_transcript(client, auth_headers, transcript="I had pasta for dinner")
    item = parsed["items"][0]
    assert item["personal_food_id"]
    assert item["macros"]["kcal"] == 400.0  # no amount: one serving
    assert parsed["totals"]["kcal"] == 400.0


def test_a_personal_food_survives_confirm_unchanged(client, auth_headers):
    _save_label(client, auth_headers, name="ground beef", serving_grams=113.4)
    parsed = parse_transcript(client, auth_headers)
    resp = client.post(
        "/meals",
        json={"client_meal_id": "pf-1", "parse_id": parsed["parse_id"], "meal_type": "lunch", "items": confirmed_items(parsed)},
        headers=auth_headers,
    )
    assert resp.status_code == 201, resp.text
    logged = resp.json()
    assert logged["items"][0]["macros"]["protein"] == 24.0
    assert logged["items"][0]["source"] == "manual"
    assert logged["totals"]["kcal"] == 153.0


def test_batch_food_is_the_resolved_total_divided_by_servings(client, auth_headers):
    parsed = parse_transcript(client, auth_headers)  # one resolved ingredient, 4 oz 93/7 beef
    total_kcal = parsed["totals"]["kcal"]
    resp = client.post(
        "/foods/personal/batch",
        json={"name": "My taco meat", "items": confirmed_items(parsed), "servings": 4, "parse_id": parsed["parse_id"]},
        headers=auth_headers,
    )
    assert resp.status_code == 201, resp.text
    food = resp.json()
    assert food["source"] == "batch"
    assert food["per_serving"]["kcal"] == round(total_kcal / 4, 1)
    assert food["serving_grams"] == round(parsed["items"][0]["grams"] / 4, 1)
    assert food["servings_per_package"] == 4
    # Spoken later, by servings: "taco meat" matches the name with "my" stripped.
    again = parse_transcript(client, auth_headers, transcript="I had pasta for dinner")
    assert again["items"][0]["personal_food_id"] is None  # a different food is not it
    listed = client.get("/foods/personal", headers=auth_headers).json()
    assert [f["name"] for f in listed] == ["My taco meat"]


def test_saving_the_same_name_versions_it(client, auth_headers, fake_db):
    first = _save_label(client, auth_headers)
    second = _save_label(client, auth_headers, per_serving={"protein": 30, "carbs": 3, "fat": 5})
    assert second["id"] != first["id"]
    rows = fake_db.tables["personal_foods"]
    assert len(rows) == 2
    assert [r["retired_at"] is None for r in sorted(rows, key=lambda r: r["created_at"])] == [False, True]
    listed = client.get("/foods/personal", headers=auth_headers).json()
    assert [f["id"] for f in listed] == [second["id"]]


def test_retire_is_a_mark_and_stops_matching(client, auth_headers, fake_db):
    food = _save_label(client, auth_headers, name="ground beef", serving_grams=113.4)
    assert client.delete(f"/foods/personal/{food['id']}", headers=auth_headers).status_code == 204
    assert client.delete(f"/foods/personal/{food['id']}", headers=auth_headers).status_code == 404
    assert client.delete("/foods/personal/not-a-uuid", headers=auth_headers).status_code == 404
    assert len(fake_db.tables["personal_foods"]) == 1
    assert client.get("/foods/personal", headers=auth_headers).json() == []
    parsed = parse_transcript(client, auth_headers)
    assert parsed["items"][0]["personal_food_id"] is None


def test_personal_foods_are_owner_scoped(client, auth_headers, auth_headers_user_2):
    _save_label(client, auth_headers, name="ground beef", serving_grams=113.4)
    assert client.get("/foods/personal", headers=auth_headers_user_2).json() == []
    other = parse_transcript(client, auth_headers_user_2)
    assert other["items"][0]["personal_food_id"] is None


def test_index_matches_aliases_and_prefers_a_later_name() -> None:
    rows = [
        {"id": "b", "name": "chili", "aliases": ["taco meat"], "per_serving": {"kcal": 1, "protein": 0, "carbs": 0, "fat": 0}, "serving_grams": None},
        {"id": "a", "name": "taco meat", "aliases": [], "per_serving": {"kcal": 2, "protein": 0, "carbs": 0, "fat": 0}, "serving_grams": None},
    ]
    index = PersonalFoodIndex(rows)  # newest first, as the store lists them
    assert index.match("my taco meat")["id"] == "a"  # a food's own name beats an older alias
    assert index.match("chili recipe")["id"] == "b"
    assert index.match("beef") is None
