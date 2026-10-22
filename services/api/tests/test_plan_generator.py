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


# -- the 2026-10-22 audit -------------------------------------------------------------------


def test_whole_pieces_do_not_carry_the_day_off_the_protocol():
    # Pieces were rounded after the calorie balance and nothing took up the difference: this
    # day drafted 2,344 against 1,800. Pieces now round toward the aim, and the foods measured by
    # weight settle what is left.
    foods = [food(n) for n in ("apple", "egg", "bagel", "whole wheat bread", "chicken breast")]
    draft = draft_plan(DayShape(meals=4, snacks=1), foods, TARGETS, may_add=False)
    kcal, protein, _, _ = totals(draft.slots)
    assert abs(kcal - TARGETS.kcal) <= 0.05 * TARGETS.kcal, kcal
    assert protein >= TARGETS.protein_floor
    for slot in draft.slots:
        for portion in slot.portions:
            if portion.food.counted:
                assert portion.grams / portion.food.serving == round(portion.grams / portion.food.serving)


def test_a_food_the_plan_did_not_place_is_never_reported_as_used():
    # The protein pass took a food from the pool and only then saw the gap had closed: the food
    # was recorded as placed (or as a staple added) while the plan never held it, and a food
    # the person named vanished from "not placed".
    from api.meals.generator import DraftSlot, Portion, _balance_protein, _Pool

    salmon, chicken = food("salmon"), food("chicken breast")
    pool = _Pool([salmon, chicken], {})
    fruit = food("banana")
    slots = [
        DraftSlot(label="Morning snack", kind="snack", portions=[Portion(fruit, 118.0)]),
        DraftSlot(label="Afternoon snack", kind="snack", portions=[Portion(fruit, 118.0)]),
    ]
    # A floor the first portion it places covers.
    targets = PlanTargets(kcal=1800.0, protein_floor=12.0, protein_target=12.0, fat=54.0, produce=5.0)
    _balance_protein(slots, pool, targets)
    placed = {p.food.name for s in slots for p in s.portions}
    assert placed == {"banana", "salmon"}
    assert pool.unused_names() == ["chicken breast"]


@pytest.mark.parametrize(("name", "kcal", "macros", "role"), [
    ("sugar snap peas", 42, (2.8, 7.6, 0.2), Role.VEGETABLE),
    ("honey glazed ham", 140, (18.0, 6.0, 5.0), Role.PROTEIN),
    ("spaghetti with meat sauce", 150, (7.0, 20.0, 4.5), Role.STARCH),
    ("chips and salsa", 450, (6.0, 60.0, 21.0), Role.SNACK),
    ("mac and cheese", 164, (6.6, 18.0, 7.4), Role.DISH),
    ("ranch dressing", 430, (1.0, 6.0, 45.0), Role.NONE),
    ("ketchup and mustard", 90, (1.0, 20.0, 1.0), Role.NONE),
    ("cheddar cheese", 403, (25.0, 1.3, 33.0), Role.FAT),
])
def test_a_food_is_its_head_noun_not_a_word_in_it(name, kcal, macros, role):
    from api.nutrition.schemas import NutrientProfile

    protein, carbs, fat = macros
    profile = NutrientProfile(kcal=kcal, protein=protein, carbs=carbs, fat=fat, fiber=0)
    produce = 1.0 if name == "sugar snap peas" else 0.0
    assert role_of(PlanFood(name=name, per_100g=profile, produce_per_100g=produce)) is role


def test_foods_that_fill_no_meal_are_refused_never_an_empty_day():
    foods = [food(n) for n in ("ketchup", "water")] if get_dictionary().lookup("ketchup") else []
    from api.nutrition.schemas import NutrientProfile

    foods = foods or [PlanFood(name="ketchup", per_100g=NutrientProfile(kcal=100, protein=1, carbs=25, fat=0, fiber=0))]
    with pytest.raises(DraftRefusedError):
        draft_plan(DayShape(meals=3), foods, TARGETS, may_add=False)


def test_a_protein_shortfall_under_a_gram_is_never_zero_grams():
    from api.meals.plan import _check_line

    line = _check_line(1800.0, 119.7, 1800.0, 120.0, kcal_within=True, protein_ok=False)
    assert line == "Protein 1 g under the band."
