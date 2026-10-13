"""The drafted meal plan (decision 73, meals/generator.py): roles, the day's shape, and a draft
that lands on the protocol from the person's own foods, or says how far off it is."""

from __future__ import annotations

import pytest

from api.meals.generator import (
    DayShape,
    DraftRefusedError,
    PlanFood,
    PlanTargets,
    Role,
    draft_plan,
    role_of,
    totals,
)
from api.nutrition.dictionary import get_dictionary

TARGETS = PlanTargets(kcal=1800.0, protein_floor=120.0, protein_target=140.0, fat=54.0, produce=5.0, protein_ceiling=165.0)


def food(name: str, *, added: bool = False) -> PlanFood:
    """A curated food exactly as the router builds one from a dictionary hit."""
    match = get_dictionary().lookup(name)
    assert match is not None, name
    entry = match.entry
    produce = entry.produce_servings / entry.serving_grams * 100.0 if entry.produce_servings else 0.0
    return PlanFood(name=name, per_100g=entry.profile, serving_grams=entry.serving_grams,
                    produce_per_100g=produce, added=added)


STAPLES = {
    Role.PROTEIN: [food("greek yogurt", added=True), food("chicken breast", added=True)],
    Role.STARCH: [food("oatmeal", added=True), food("brown rice", added=True)],
    Role.VEGETABLE: [food("broccoli", added=True)],
    Role.FRUIT: [food("blueberries", added=True)],
    Role.FAT: [food("olive oil", added=True), food("almonds", added=True)],
    Role.DESSERT: [food("dark chocolate", added=True)],
}

AMPLE = [food(n) for n in (
    "chicken breast", "salmon", "egg", "greek yogurt", "white rice", "oatmeal",
    "whole wheat bread", "broccoli", "green beans", "blueberries", "banana", "olive oil",
    "almonds", "dark chocolate",
)]


def _names(draft) -> list[list[str]]:
    return [[p.food.name for p in slot.portions] for slot in draft.slots]


# -- roles ------------------------------------------------------------------------------------


@pytest.mark.parametrize(("name", "role"), [
    ("chicken breast", Role.PROTEIN),
    ("egg", Role.PROTEIN),
    ("greek yogurt", Role.PROTEIN),
    ("white rice", Role.STARCH),
    ("oatmeal", Role.STARCH),
    ("broccoli", Role.VEGETABLE),
    ("cherry tomato", Role.VEGETABLE),
    ("blueberries", Role.FRUIT),
    ("banana", Role.FRUIT),
    ("olive oil", Role.FAT),
    ("almonds", Role.FAT),
    ("cheddar cheese", Role.FAT),
    ("avocado", Role.FAT),
    ("dark chocolate", Role.DESSERT),
    ("cookie", Role.DESSERT),
    ("pizza", Role.DISH),
    ("protein bar", Role.SNACK),
    ("whole milk", Role.DRINK),
    ("ketchup", Role.NONE),
    ("water", Role.NONE),
    ("coffee", Role.NONE),
])
def test_roles_come_from_the_food_itself(name, role):
    assert role_of(food(name)) is role


# -- the day ---------------------------------------------------------------------------------


def test_the_day_has_the_shape_the_person_described():
    draft = draft_plan(DayShape(meals=3, snacks=1, dessert=True), AMPLE, TARGETS, may_add=False)
    assert [s.label for s in draft.slots] == ["Breakfast", "Snack", "Lunch", "Dinner", "Dessert"]
    two = draft_plan(DayShape(meals=2, snacks=2), AMPLE, TARGETS, may_add=False)
    assert [s.label for s in two.slots] == ["Morning snack", "Lunch", "Afternoon snack", "Dinner"]
    five = draft_plan(DayShape(meals=5, snacks=2, dessert=True), AMPLE, TARGETS, may_add=False)
    assert len(five.slots) == 8


def test_ample_foods_land_on_the_protocol():
    draft = draft_plan(DayShape(meals=3, snacks=1, dessert=True), AMPLE, TARGETS, may_add=False)
    kcal, protein, fat, produce = totals(draft.slots)
    assert abs(kcal - TARGETS.kcal) <= 0.10 * TARGETS.kcal, kcal
    assert protein >= TARGETS.protein_floor, protein
    assert fat >= 0.75 * TARGETS.fat, fat
    assert produce >= 0.8 * TARGETS.produce, produce
    assert draft.added == []
    # Breakfast is a breakfast: its protein and starch are morning foods.
    breakfast = draft.slots[0]
    assert {p.food.name for p in breakfast.portions} & {"egg", "greek yogurt"}
    assert {p.food.name for p in breakfast.portions} & {"oatmeal", "whole wheat bread"}
    # The dessert is the person's dessert.
    assert draft.slots[-1].portions[0].food.name == "dark chocolate"


def test_meals_rotate_through_the_persons_foods():
    draft = draft_plan(DayShape(meals=3), AMPLE, TARGETS, may_add=False)
    lunch, dinner = draft.slots[1], draft.slots[2]
    proteins = [p.food.name for slot in (lunch, dinner) for p in slot.portions if p.food.role is Role.PROTEIN]
    assert len(set(proteins)) == len(proteins), proteins


def test_portions_are_whole_pieces_or_five_grams():
    draft = draft_plan(DayShape(meals=3, snacks=1, dessert=True), AMPLE, TARGETS, may_add=False)
    for slot in draft.slots:
        for portion in slot.portions:
            if portion.pieces is not None:
                assert portion.grams == pytest.approx(portion.pieces * portion.food.serving)
            else:
                assert portion.grams % 5 == pytest.approx(0)
                assert portion.grams >= 5


def test_the_same_request_drafts_the_same_plan():
    shape = DayShape(meals=4, snacks=2, dessert=True)
    first = draft_plan(shape, AMPLE, TARGETS, may_add=True, staples=STAPLES)
    second = draft_plan(shape, AMPLE, TARGETS, may_add=True, staples=STAPLES)
    assert _names(first) == _names(second)
    assert [[p.grams for p in s.portions] for s in first.slots] == [[p.grams for p in s.portions] for s in second.slots]


# -- short lists, additions ------------------------------------------------------------------


def test_short_protein_is_filled_only_when_additions_are_allowed():
    few = [food(n) for n in ("white rice", "broccoli", "banana", "olive oil")]
    alone = draft_plan(DayShape(meals=3, snacks=1), few, TARGETS, may_add=False)
    assert alone.added == []
    assert totals(alone.slots)[1] < TARGETS.protein_floor  # the check line will say so
    helped = draft_plan(DayShape(meals=3, snacks=1), few, TARGETS, may_add=True, staples=STAPLES)
    assert "greek yogurt" in helped.added
    assert totals(helped.slots)[1] >= TARGETS.protein_floor


def test_low_fat_foods_get_a_fat_when_one_is_available():
    lean = [food(n) for n in ("chicken breast", "white rice", "broccoli", "blueberries", "greek yogurt")]
    draft = draft_plan(DayShape(meals=3), lean, TARGETS, may_add=True, staples=STAPLES)
    assert "olive oil" in draft.added
    assert totals(draft.slots)[2] >= 0.75 * TARGETS.fat
    # A fat on a plate goes with a main meal, never as a snack of oil.
    for slot in draft.slots:
        for portion in slot.portions:
            if portion.food.name == "olive oil":
                assert slot.kind == "meal"


def test_no_starch_still_drafts_and_says_what_it_could():
    no_starch = [food(n) for n in ("chicken breast", "salmon", "broccoli", "green beans", "apple", "almonds")]
    draft = draft_plan(DayShape(meals=3), no_starch, TARGETS, may_add=False)
    assert draft.slots
    assert all(slot.portions for slot in draft.slots)
    assert totals(draft.slots)[0] < TARGETS.kcal  # under, honestly: nothing invented


def test_dessert_without_a_dessert_food():
    plain = [food(n) for n in ("chicken breast", "white rice", "broccoli")]
    dropped = draft_plan(DayShape(meals=3, dessert=True), plain, TARGETS, may_add=False)
    assert all(slot.kind != "dessert" for slot in dropped.slots)
    assert any("dessert" in note for note in dropped.notes)
    added = draft_plan(DayShape(meals=3, dessert=True), plain, TARGETS, may_add=True, staples=STAPLES)
    assert added.slots[-1].kind == "dessert"
    assert "dark chocolate" in added.added


def test_a_dish_is_a_whole_meal_once():
    with_pizza = [food(n) for n in ("pizza", "chicken breast", "white rice", "broccoli")]
    draft = draft_plan(DayShape(meals=3), with_pizza, TARGETS, may_add=False)
    pizza_meals = [s for s in draft.slots if any(p.food.name == "pizza" for p in s.portions)]
    assert len(pizza_meals) == 1
    assert not pizza_meals[0].breakfast


def test_condiments_and_water_are_not_placed():
    listed = [food(n) for n in ("chicken breast", "white rice", "broccoli", "ketchup", "water")]
    draft = draft_plan(DayShape(meals=3), listed, TARGETS, may_add=False)
    placed = {p.food.name for s in draft.slots for p in s.portions}
    assert "ketchup" not in placed
    assert "water" not in placed
    assert {"ketchup", "water"} <= set(draft.unused)


def test_nothing_named_with_additions_builds_a_day_from_staples():
    draft = draft_plan(DayShape(meals=3, snacks=1), [], TARGETS, may_add=True, staples=STAPLES)
    assert draft.slots
    assert all(slot.portions for slot in draft.slots)
    assert draft.added
    kcal, protein, fat, _ = totals(draft.slots)
    assert protein >= TARGETS.protein_floor
    assert fat >= 0.75 * TARGETS.fat
    assert abs(kcal - TARGETS.kcal) <= 0.10 * TARGETS.kcal


def test_requests_out_of_bounds_are_refused():
    with pytest.raises(DraftRefusedError):
        draft_plan(DayShape(meals=3), [], TARGETS, may_add=False)
    with pytest.raises(DraftRefusedError):
        draft_plan(DayShape(meals=6), AMPLE, TARGETS, may_add=False)
    with pytest.raises(DraftRefusedError):
        draft_plan(DayShape(meals=3, snacks=3), AMPLE, TARGETS, may_add=False)


def test_staples_never_enter_without_permission():
    few = [food(n) for n in ("white rice", "broccoli")]
    draft = draft_plan(DayShape(meals=3, snacks=1, dessert=True), few, TARGETS, may_add=False, staples=STAPLES)
    placed = {p.food.name for s in draft.slots for p in s.portions}
    assert placed <= {"white rice", "broccoli"}
    assert draft.added == []
