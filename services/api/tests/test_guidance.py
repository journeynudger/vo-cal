"""Decision 74: one thing to add, without numbers (meals/guidance.py).

Proves: the first gap in the fixed order (protein, produce, fat, fiber) and its thresholds;
nothing when fewer than three days were logged or nothing is short; the person's own foods named,
never one with a digit in its name; no digit in any line; and the two places it shows: Today in a
mode without numbers (unless the person asked for nothing) and the numbers-free check-in.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

import pytest

from api.meals.guidance import (
    GuidanceTargets,
    WeekIntake,
    choose,
    line_for,
    own_foods,
    week_intake,
)

from .conftest import TEST_USER_ID

TARGETS = GuidanceTargets(protein_floor=120.0, produce=5.0, fat=55.0, fiber=30.0)
FULL = WeekIntake(days_logged=5, protein=130.0, produce=6.0, fat=60.0, fiber=32.0)
NONE: dict[str, list[str]] = {}


def _week(**over) -> WeekIntake:
    base = {"days_logged": 5, "protein": 130.0, "produce": 6.0, "fat": 60.0, "fiber": 32.0}
    base.update(over)
    return WeekIntake(**base)


# -- the choice ------------------------------------------------------------------------------


def test_nothing_short_says_nothing():
    assert choose(FULL, TARGETS, NONE) is None


def test_too_few_days_say_nothing():
    assert choose(_week(days_logged=2, protein=10.0), TARGETS, NONE) is None


@pytest.mark.parametrize(("over", "kind"), [
    ({"protein": 90.0}, "protein"),
    ({"produce": 3.0}, "produce"),
    ({"fat": 35.0}, "fat"),
    ({"fiber": 18.0}, "fiber"),
])
def test_each_gap_is_named(over, kind):
    guidance = choose(_week(**over), TARGETS, NONE)
    assert guidance is not None
    assert guidance.kind == kind
    assert guidance.title == "Something to add"


def test_the_order_is_protein_produce_fat_fiber():
    everything_short = _week(protein=50.0, produce=1.0, fat=20.0, fiber=5.0)
    assert choose(everything_short, TARGETS, NONE).kind == "protein"
    assert choose(_week(produce=1.0, fat=20.0, fiber=5.0), TARGETS, NONE).kind == "produce"
    assert choose(_week(fat=20.0, fiber=5.0), TARGETS, NONE).kind == "fat"


def test_just_under_the_line_is_not_short():
    # 80 percent of the protein floor is the line, not 100: a near day is not a gap.
    assert choose(_week(protein=97.0), TARGETS, NONE) is None


def test_the_persons_foods_are_named_never_one_with_a_digit():
    own = {"protein": ["93/7 ground beef", "Greek yogurt", "chicken breast", "tofu"]}
    guidance = choose(_week(protein=60.0), TARGETS, own)
    assert "Your Greek yogurt or chicken breast at one more meal a day" in guidance.line
    assert "93/7" not in guidance.line


@pytest.mark.parametrize("kind", ["protein", "produce", "fat", "fiber"])
@pytest.mark.parametrize("foods", [[], ["oats"], ["oats", "black beans"]])
def test_no_line_carries_a_number(kind, foods):
    line = line_for(kind, foods)
    assert not any(ch.isdigit() for ch in line), line
    assert "—" not in line


# -- reading the week ------------------------------------------------------------------------


def _row(day_offset: int, items: list[dict], *, protein: float, fat: float, fiber: float, kcal: float = 500.0) -> dict:
    logged = datetime.now(UTC) - timedelta(days=day_offset, hours=1)
    return {
        "id": str(uuid4()),
        "user_id": str(TEST_USER_ID),
        "client_meal_id": f"g-{uuid4()}",
        "name": None,
        "meal_type": "lunch",
        "items": items,
        "totals": {"kcal": kcal, "protein": protein, "carbs": 60.0, "fat": fat, "fiber": fiber},
        "confidence": 0.9,
        "logged_at": logged.isoformat(),
    }


def _item(name: str, grams: float, kcal: float, protein: float, fat: float, fiber: float = 0.0) -> dict:
    return {"name": name, "grams": grams, "macros": {"kcal": kcal, "protein": protein, "carbs": 10.0, "fat": fat, "fiber": fiber}}


RICE_AND_BROCCOLI = [_item("white rice", 300, 390, 8, 1, 1.2), _item("broccoli", 150, 52, 3.6, 0.6, 5.0)]


def test_week_intake_averages_over_the_days_that_had_a_meal():
    rows = [
        _row(1, RICE_AND_BROCCOLI, protein=12, fat=2, fiber=6),
        _row(1, RICE_AND_BROCCOLI, protein=12, fat=2, fiber=6),
        _row(3, RICE_AND_BROCCOLI, protein=12, fat=2, fiber=6),
    ]
    week = week_intake(rows, ZoneInfo("UTC"))
    assert week.days_logged == 2
    assert week.protein == pytest.approx(18.0)
    assert week.produce > 0


def test_own_foods_sorts_the_persons_items_by_what_they_add():
    rows = [
        _row(1, [_item("chicken breast", 150, 248, 46.5, 5.4), _item("olive oil", 14, 124, 0, 14)], protein=46, fat=19, fiber=0),
        _row(2, [_item("chicken breast", 150, 248, 46.5, 5.4), _item("black beans", 130, 172, 11.6, 0.7, 11.3)], protein=58, fat=6, fiber=11),
    ]
    own = own_foods(rows)
    assert own["protein"][0] == "chicken breast"
    assert "olive oil" in own["fat"]
    assert "black beans" in own["fiber"]


# -- where it shows ---------------------------------------------------------------------------

INTAKE = {
    "age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0,
    "goal": "cut", "work": "desk", "train": "moderate", "kids": False,
    "med": "none", "stress": "moderate",
}


def _today() -> str:
    return datetime.now(UTC).date().isoformat()


def _setup(client, headers, fake_db, *, mode: str = "habits", nudge_level: str | None = None) -> None:
    client.post("/intake", json={"intake": INTAKE}, headers=headers)
    client.post("/protocols/generate", json={"intake": INTAKE}, headers=headers)
    body = {"mode": mode}
    if nudge_level:
        body["nudge_level"] = nudge_level
    client.put("/tracking", json=body, headers=headers)
    for day in (1, 2, 3, 4):
        fake_db.tables.setdefault("meal_logs", []).append(_row(day, RICE_AND_BROCCOLI, protein=12, fat=2, fiber=6))


def test_today_carries_the_guidance_without_numbers(client, auth_headers, fake_db):
    _setup(client, auth_headers, fake_db)
    body = client.get(f"/meals/today?date={_today()}", headers=auth_headers).json()
    assert body["prints_numbers"] is False
    guidance = body["guidance"]
    assert guidance is not None
    assert guidance["kind"] == "protein"
    assert not any(ch.isdigit() for ch in guidance["line"])


def test_today_says_nothing_to_a_person_who_asked_for_nothing(client, auth_headers, fake_db):
    _setup(client, auth_headers, fake_db, nudge_level="off")
    assert client.get(f"/meals/today?date={_today()}", headers=auth_headers).json()["guidance"] is None


def test_today_in_a_mode_with_numbers_has_no_guidance(client, auth_headers, fake_db):
    _setup(client, auth_headers, fake_db, mode="five")
    assert client.get(f"/meals/today?date={_today()}", headers=auth_headers).json()["guidance"] is None


def test_the_numbers_free_check_in_names_the_one_thing(client, auth_headers, fake_db):
    _setup(client, auth_headers, fake_db)
    client.post("/checkin/checkins", json={"adherence_self": 4}, headers=auth_headers)
    body = client.post("/checkin/recommend", headers=auth_headers).json()
    assert body["kind"] == "hold"
    assert body["headline"] == "One thing to add this week."
    assert body["targets"] is None
    assert not any(ch.isdigit() for ch in body["headline"] + body["rationale"])
