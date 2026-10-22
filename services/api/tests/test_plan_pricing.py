"""A meal plan prices each food as itself (decisions 65 and 73; the 2026-10-22 audit).

The confirm path's composed-meal grammar (parser/compose.py) reads one spoken meal's items as a
dish and its contents: "a turkey sandwich" plus turkey and bread stores the sandwich as a
zero-gram grouping. A plan's items are not one spoken meal. Run over a drafted day, or over a
saved slot without its transcript, the grammar zeroed real food: a burrito bowl drafted beside
chicken breast at 0 kcal, with the check line saying the day was hundreds of calories under;
a typed Chipotle bowl saved at half its parse. Each plan item is priced as the food it is, and a
grouping its parse already decided (zero grams) keeps that verdict.

A food the resolver can price only in servings (a label food saved without its weight) is drafted
in servings, and one it can price only by weight is never counted in pieces.
"""

from __future__ import annotations

from .conftest import confirmed_items, parse_transcript

INTAKE = {
    "age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0,
    "goal": "cut", "work": "desk", "train": "moderate", "kids": False,
    "med": "none", "stress": "moderate",
}


def _protocol(client, headers) -> None:
    client.post("/intake", json={"intake": INTAKE}, headers=headers)
    assert client.post("/protocols/generate", json={"intake": INTAKE}, headers=headers).status_code == 201


def _generate(client, headers, foods, **shape) -> dict:
    body = {"meals": 3, "snacks": 0, "dessert": False, "foods": foods, "may_add": False, **shape}
    resp = client.post("/meals/plan/generate", json=body, headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _day_kcal(slots) -> float:
    return round(sum(i["macros"]["kcal"] for s in slots for i in s["items"]), 1)


def test_a_drafted_dish_is_priced_beside_foods_that_could_be_its_contents(client, auth_headers):
    _protocol(client, auth_headers)
    foods = ["burrito bowl", "chicken breast", "brown rice", "broccoli", "egg", "oatmeal", "banana"]
    draft = _generate(client, auth_headers, foods)

    items = [i for s in draft["slots"] for i in s["items"]]
    bowls = [i for i in items if i["name"] == "burrito bowl"]
    assert bowls, draft["slots"]
    for item in items:
        assert item["grams"] > 0, item
        assert item["macros"]["kcal"] > 0, item
    # The check reads the day the slots carry, so it cannot say "under" about a priced bowl.
    assert draft["check"]["kcal"] == _day_kcal(draft["slots"])


def test_the_saved_draft_is_the_drafted_plan(client, auth_headers):
    _protocol(client, auth_headers)
    draft = _generate(client, auth_headers, ["burger", "chicken breast", "greek yogurt", "oatmeal", "broccoli", "blueberries"])
    slots = [{"name": s["name"], "items": s["items"]} for s in draft["slots"]]

    saved = client.put("/meals/plan", json={"slots": slots}, headers=auth_headers)
    assert saved.status_code == 200, saved.text
    plan = saved.json()
    assert [s["totals"]["kcal"] for s in plan["slots"]] == [s["totals"]["kcal"] for s in draft["slots"]]
    assert plan["check"]["line"] == draft["check"]["line"]


def test_a_typed_slot_keeps_the_verdict_of_its_parse(client, auth_headers):
    # The parse prices the bowl beside its add-ons; the saved slot must say the same.
    parsed = parse_transcript(client, auth_headers, "Chipotle bowl, double chicken, white rice, mild salsa, light cheese")
    parse_kcal = round(sum(i["macros"]["kcal"] for i in parsed["items"]), 1)
    saved = client.put(
        "/meals/plan", json={"slots": [{"items": confirmed_items(parsed)}]}, headers=auth_headers
    )
    assert saved.status_code == 200, saved.text
    assert saved.json()["slots"][0]["totals"]["kcal"] == parse_kcal


def test_a_grouping_its_parse_zeroed_stays_zero(client, auth_headers):
    # A dish the person described by its contents arrives as a zero-gram grouping; pricing it
    # again on its own would count the meal twice.
    items = [
        {"name": "turkey sandwich", "amount": None, "unit": None, "grams": 0.0,
         "macros": {"kcal": 0, "protein": 0, "carbs": 0, "fat": 0, "fiber": 0}, "confidence": 0.9},
        {"name": "turkey", "amount": 56, "unit": "g", "grams": 56.0,
         "macros": {"kcal": 60, "protein": 12, "carbs": 1, "fat": 1, "fiber": 0}, "confidence": 0.9},
        {"name": "whole wheat bread", "amount": 2, "unit": "slice", "grams": 56.0,
         "macros": {"kcal": 140, "protein": 7, "carbs": 24, "fat": 2, "fiber": 4}, "confidence": 0.9},
    ]
    saved = client.put("/meals/plan", json={"slots": [{"items": items}]}, headers=auth_headers)
    assert saved.status_code == 200, saved.text
    slot = saved.json()["slots"][0]
    sandwich = slot["items"][0]
    assert (sandwich["grams"], sandwich["macros"]["kcal"]) == (0.0, 0.0)
    assert slot["totals"]["kcal"] == round(sum(i["macros"]["kcal"] for i in slot["items"][1:]), 1)
    assert slot["name"] == "Turkey sandwich"


def test_a_food_saved_without_its_weight_is_drafted_in_servings(client, auth_headers):
    _protocol(client, auth_headers)
    food = {"name": "moms chili", "per_serving": {"kcal": 450, "protein": 35, "carbs": 30, "fat": 20, "fiber": 8}}
    assert client.post("/foods/personal", json=food, headers=auth_headers).status_code == 201

    draft = _generate(client, auth_headers, ["moms chili", "white rice", "broccoli", "oatmeal", "blueberries", "egg"])

    chili = [i for s in draft["slots"] for i in s["items"] if i["name"] == "moms chili"]
    assert chili, draft["slots"]
    for item in chili:
        assert item["unit"] is None, item
        assert 0 < item["amount"] < 5, item
        assert item["macros"]["kcal"] == round(450 * item["amount"], 1), item
    assert "moms chili" not in draft["unpriced"]


def test_slot_names_fit_what_a_save_accepts(client, auth_headers):
    _protocol(client, auth_headers)
    long_names = [
        "kirkland signature organic boneless skinless chicken breast",
        "kirkland signature organic long grain brown rice",
        "kirkland signature organic fresh wild blueberries",
        "broccoli",
    ]
    for name in long_names[:3]:
        per = {"kcal": 120, "protein": 22, "carbs": 2, "fat": 2, "fiber": 0}
        resp = client.post(
            "/foods/personal", json={"name": name, "per_serving": per, "serving_grams": 100}, headers=auth_headers
        )
        assert resp.status_code == 201, resp.text
    draft = _generate(client, auth_headers, long_names, meals=2)
    assert all(len(s["name"]) <= 120 for s in draft["slots"]), [s["name"] for s in draft["slots"]]

    # A plan stored before names were clipped sends its long name back: the save takes it.
    slots = [{"name": "x" * 169, "items": draft["slots"][0]["items"]}]
    saved = client.put("/meals/plan", json={"slots": slots}, headers=auth_headers)
    assert saved.status_code == 200, saved.text
    assert len(saved.json()["slots"][0]["name"]) <= 120
