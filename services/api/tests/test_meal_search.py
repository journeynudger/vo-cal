"""Search over what the person has logged, for a typed log (meals/search.py, GET /meals/search)."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from api.meals.search import SearchSource, rank, sources_from_meals

from .conftest import confirmed_items, parse_transcript


def _src(kind: str, name: str, *, times: int = 1, days_ago: int = 0, kcal: float | None = None) -> SearchSource:
    return SearchSource(kind=kind, id=f"{kind}:{name}", name=name, kcal=kcal, times=times,
                        last_logged_at=datetime.now(UTC) - timedelta(days=days_ago))


# -- the pure ranking ---------------------------------------------------------------


def test_prefix_beats_word_prefix_beats_substring() -> None:
    hits = rank("chi", [_src("meal", "Rice & chicken"), _src("meal", "Chili"), _src("meal", "Zucchini")])
    assert [h.name for h in hits] == ["Chili", "Rice & chicken", "Zucchini"]


def test_frequency_then_recency_break_ties() -> None:
    hits = rank("smoothie", [
        _src("meal", "Smoothie bowl", times=1, days_ago=1),
        _src("meal", "Smoothie", times=4, days_ago=10),
        _src("meal", "Smoothie with oats", times=1, days_ago=20),
    ])
    assert [h.name for h in hits] == ["Smoothie", "Smoothie bowl", "Smoothie with oats"]


def test_same_name_collapses_to_one_hit_preferring_the_usual() -> None:
    hits = rank("beef", [_src("meal", "Beef bowl", times=3, kcal=500), _src("usual", "beef bowl", kcal=510), _src("personal_food", "Beef bowl")])
    assert len(hits) == 1
    assert hits[0].kind == "usual"
    assert hits[0].times == 5
    assert hits[0].kcal == 510


def test_empty_or_unmatched_queries_return_nothing() -> None:
    assert rank("", [_src("meal", "Eggs")]) == []
    assert rank("   ", [_src("meal", "Eggs")]) == []
    assert rank("pizza", [_src("meal", "Eggs")]) == []


def test_meal_rows_group_by_display_name_keeping_the_newest() -> None:
    rows = [
        {"id": "a", "name": None, "items": [{"name": "eggs", "grams": 100, "macros": {"kcal": 140}}], "totals": {"kcal": 140}, "logged_at": "2026-09-01T08:00:00+00:00"},
        {"id": "b", "name": None, "items": [{"name": "eggs", "grams": 100, "macros": {"kcal": 150}}], "totals": {"kcal": 150}, "logged_at": "2026-09-03T08:00:00+00:00"},
        {"id": "c", "name": "Eggs", "items": [], "totals": {"kcal": 160}, "logged_at": "2026-09-02T08:00:00+00:00"},
    ]
    sources = sources_from_meals(rows)
    assert len(sources) == 1
    assert sources[0].id == "b"
    assert sources[0].times == 3
    assert sources[0].kcal == 150


# -- the API ------------------------------------------------------------------------


def test_search_returns_meals_usuals_and_personal_foods(client, auth_headers):
    parsed = parse_transcript(client, auth_headers, "some chicken and some rice")
    logged = client.post("/meals", json={"client_meal_id": "m-s-1", "parse_id": parsed["parse_id"], "items": confirmed_items(parsed)}, headers=auth_headers)
    assert logged.status_code == 201
    saved = client.post(
        "/foods/personal",
        json={"name": "Chicken shawarma bowl", "per_serving": {"protein": 40, "carbs": 50, "fat": 20}},
        headers=auth_headers,
    )
    assert saved.status_code == 201, saved.text

    hits = client.get("/meals/search", params={"q": "chick"}, headers=auth_headers).json()
    kinds = {h["kind"] for h in hits}
    assert "meal" in kinds
    assert "personal_food" in kinds
    meal_hit = next(h for h in hits if h["kind"] == "meal")
    assert meal_hit["items"], "a meal hit carries its items to log again"
    assert meal_hit["kcal"] > 0
    food_hit = next(h for h in hits if h["kind"] == "personal_food")
    assert food_hit["items"] == []
    assert food_hit["kcal"] == 540


def test_search_is_owner_scoped_and_validated(client, auth_headers, auth_headers_user_2):
    parsed = parse_transcript(client, auth_headers)
    client.post("/meals", json={"client_meal_id": "m-s-2", "parse_id": parsed["parse_id"], "items": confirmed_items(parsed)}, headers=auth_headers)
    assert client.get("/meals/search", params={"q": "beef"}, headers=auth_headers).json()
    assert client.get("/meals/search", params={"q": "beef"}, headers=auth_headers_user_2).json() == []
    assert client.get("/meals/search", params={"q": ""}, headers=auth_headers).status_code == 422
    assert client.get("/meals/search", params={"q": "x" * 61}, headers=auth_headers).status_code == 422
    assert client.get("/meals/search", headers=auth_headers).status_code == 422
