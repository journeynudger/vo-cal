"""Meals are named after what was eaten; the person can rename them; a rename is a usual.

Pins the naming rules (meals/naming.py) and the API behaviour around them: a confirm with no
name gets an auto name, /today shows it, an edit recomputes an auto name but never a typed
one, PATCH /meals/{id}/name renames and creates the usual, and rows from before names
existed still read a name (display_name).
"""

from __future__ import annotations

import pytest

from api.meals.naming import (
    NAME_SOURCE_AUTO,
    NAME_SOURCE_USER,
    auto_name,
    display_name,
    is_user_named,
)

from .conftest import confirmed_items, parse_transcript


def _item(name: str, kcal: float, grams: float = 100.0, **extra) -> dict:
    return {"name": name, "grams": grams, "macros": {"kcal": kcal, "protein": 1, "carbs": 1, "fat": 1, "fiber": 0}, **extra}


# -- the pure rules -----------------------------------------------------------------


def test_auto_name_shapes() -> None:
    assert auto_name([_item("oatmeal", 300)]) == "Oatmeal"
    assert auto_name([_item("banana", 100), _item("oatmeal", 300)]) == "Oatmeal & banana"
    assert auto_name([_item("banana", 100), _item("oatmeal", 300), _item("peanut butter", 190)]) == (
        "Oatmeal, peanut butter & banana"
    )
    assert auto_name(
        [_item("banana", 100), _item("oatmeal", 300), _item("peanut butter", 190), _item("honey", 60), _item("milk", 90)]
    ) == "Oatmeal, peanut butter, banana & 2 more"


def test_auto_name_keeps_spoken_order_on_ties_and_brand_case() -> None:
    assert auto_name([_item("eggs", 140), _item("toast", 140)]) == "Eggs & toast"
    assert auto_name([_item("Chobani greek yogurt", 150), _item("granola", 200)]) == "Granola & Chobani greek yogurt"


def test_auto_name_uses_the_dish_for_a_composed_meal() -> None:
    # The container is stored as a zero-kcal, zero-gram grouping; its parts carry the meal.
    items = [_item("turkey sandwich", 0, grams=0), _item("turkey", 120), _item("bread", 160), _item("mayo", 90)]
    assert auto_name(items) == "Turkey sandwich"


def test_auto_name_dedupes_and_handles_nothing() -> None:
    assert auto_name([]) is None
    assert auto_name([_item("", 10)]) is None
    assert auto_name([_item("egg", 70), _item("Egg", 70)]) == "Egg"


def test_display_name_and_ownership_of_legacy_rows() -> None:
    legacy_unnamed = {"name": None, "items": [_item("salmon", 300), _item("rice", 200)]}
    assert display_name(legacy_unnamed) == "Salmon & rice"
    assert is_user_named(legacy_unnamed) is False
    legacy_named = {"name": "Lunch", "items": [_item("salmon", 300)]}
    assert display_name(legacy_named) == "Lunch"
    assert is_user_named(legacy_named) is True  # named before sources existed: the person's
    auto = {"name": "Salmon", "name_source": NAME_SOURCE_AUTO, "items": [_item("salmon", 300)]}
    assert is_user_named(auto) is False


# -- the API ------------------------------------------------------------------------


def _log(client, headers, parsed: dict, *, name: str | None = None, client_meal_id: str = "m-name-1") -> dict:
    body = {"client_meal_id": client_meal_id, "parse_id": parsed["parse_id"], "items": confirmed_items(parsed)}
    if name is not None:
        body["name"] = name
    resp = client.post("/meals", json=body, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def test_confirm_without_a_name_is_named_after_the_items(client, auth_headers, fake_db):
    parsed = parse_transcript(client, auth_headers, "some chicken and some rice")
    meal = _log(client, auth_headers, parsed)
    assert meal["name"] in {"Chicken & white rice", "White rice & chicken"}
    row = fake_db.tables["meal_logs"][0]
    assert row["name_source"] == NAME_SOURCE_AUTO
    day = meal["logged_at"][:10]
    today = client.get("/meals/today", params={"date": day, "tz": "UTC"}, headers=auth_headers).json()
    assert today["meals"][0]["name"] == meal["name"]
    listed = client.get(f"/meals/{meal['id']}", headers=auth_headers).json()
    assert listed["name"] == meal["name"]


def test_a_typed_name_is_kept_as_the_persons_own(client, auth_headers, fake_db):
    parsed = parse_transcript(client, auth_headers)
    meal = _log(client, auth_headers, parsed, name="Post-run beef")
    assert meal["name"] == "Post-run beef"
    assert fake_db.tables["meal_logs"][0]["name_source"] == NAME_SOURCE_USER


def test_edit_recomputes_an_auto_name_but_never_a_typed_one(client, auth_headers):
    parsed = parse_transcript(client, auth_headers, "some chicken and some rice")
    meal = _log(client, auth_headers, parsed)
    only_chicken = [i for i in meal["items"] if i["name"] == "chicken"]
    edited = client.put(f"/meals/{meal['id']}", json={"items": only_chicken}, headers=auth_headers)
    assert edited.status_code == 200, edited.text
    assert edited.json()["name"] == "Chicken"

    typed = _log(client, auth_headers, parsed, name="Sunday lunch", client_meal_id="m-name-2")
    edited = client.put(f"/meals/{typed['id']}", json={"items": only_chicken}, headers=auth_headers)
    assert edited.json()["name"] == "Sunday lunch"


def test_rename_is_the_persons_name_and_becomes_a_usual(client, auth_headers, fake_db):
    parsed = parse_transcript(client, auth_headers)
    meal = _log(client, auth_headers, parsed)
    renamed = client.patch(f"/meals/{meal['id']}/name", json={"name": "  Metal detox   beef "}, headers=auth_headers)
    assert renamed.status_code == 200, renamed.text
    assert renamed.json()["name"] == "Metal detox beef"
    assert fake_db.tables["meal_logs"][0]["name_source"] == NAME_SOURCE_USER
    usuals = client.get("/meals/usuals", headers=auth_headers).json()
    assert [u["name"] for u in usuals] == ["Metal detox beef"]
    assert usuals[0]["items"][0]["name"] == meal["items"][0]["name"]

    # Renaming again to the same name refreshes the one usual instead of adding a twin.
    again = client.patch(f"/meals/{meal['id']}/name", json={"name": "metal detox beef"}, headers=auth_headers)
    assert again.status_code == 200
    assert len(client.get("/meals/usuals", headers=auth_headers).json()) == 1
    # An edit after a rename keeps the person's name.
    edited = client.put(f"/meals/{meal['id']}", json={"items": meal["items"]}, headers=auth_headers)
    assert edited.json()["name"] == "metal detox beef"


def test_rename_is_owner_scoped_and_validated(client, auth_headers, auth_headers_user_2):
    parsed = parse_transcript(client, auth_headers)
    meal = _log(client, auth_headers, parsed)
    foreign = client.patch(f"/meals/{meal['id']}/name", json={"name": "Mine now"}, headers=auth_headers_user_2)
    assert foreign.status_code == 404
    empty = client.patch(f"/meals/{meal['id']}/name", json={"name": "   "}, headers=auth_headers)
    assert empty.status_code in (400, 422)
    assert client.get(f"/meals/{meal['id']}", headers=auth_headers).json()["name"] == meal["name"]


@pytest.mark.parametrize("name", ["x" * 81])
def test_rename_rejects_an_overlong_name(client, auth_headers, name):
    parsed = parse_transcript(client, auth_headers)
    meal = _log(client, auth_headers, parsed)
    assert client.patch(f"/meals/{meal['id']}/name", json={"name": name}, headers=auth_headers).status_code == 422
