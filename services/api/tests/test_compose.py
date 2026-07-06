"""Composed-meal grammar — the container double-count fix (product spec 2026-07).

"I had a sandwich with bread, turkey, ham, and cheese" is ONE sandwich made of those
things — never a generic sandwich PLUS the ingredients. The container becomes a
zero-calorie display grouping whenever the user described its contents; it keeps its
generic estimate only when it stands alone (a vague log is still a successful log).
"""

from __future__ import annotations

import pytest

from api.nutrition.resolver import Resolver
from api.parser.compose import analyze, is_component, is_container
from api.parser.router import resolve_with_composition
from api.parser.schemas import ParsedItem, Unit


def _item(name, amount=None, unit=None, brand=None):
    return ParsedItem(name=name, amount=amount, unit=unit, brand=brand, confidence=0.9)


async def _resolve(items):
    meal, _composition = await resolve_with_composition(Resolver(), items)
    return meal


# -- lexicon sanity -------------------------------------------------------------


def test_container_detection():
    for name in ("sandwich", "turkey sandwich", "wrap", "burrito", "burger", "salad",
                 "burrito bowl", "omelet", "smoothie", "yogurt bowl", "avocado toast",
                 "breakfast plate", "quesadilla", "nachos"):
        assert is_container(name), name
    for name in ("pizza", "pasta", "oatmeal", "ramen", "curry", "chicken breast",
                 "potato chips", "white bread", "ground turkey"):
        assert not is_container(name), name


def test_component_detection():
    for name in ("white bread", "healthy life low carb bread", "turkey", "krakus ham",
                 "provolone cheese", "lettuce", "mayo", "white rice", "black beans",
                 "sour cream", "banana", "protein powder", "greek yogurt", "eggs"):
        assert is_component(name), name
    for name in ("potato chips", "soda", "cookie", "apple", "turkey sandwich"):
        assert not is_component(name), name


# -- the suppression verdict -----------------------------------------------------


def test_container_with_two_components_suppressed():
    comp = analyze([("sandwich", None), ("turkey", 2.5), ("provolone cheese", 2.0)])
    assert comp.suppressed_indices == frozenset({0})
    assert comp.suppressed_names == ("sandwich",)


def test_container_with_one_quantified_component_suppressed():
    # An explicit amount signals ingredient-level precision — that beats a generic estimate.
    comp = analyze([("turkey sandwich", None), ("turkey", 2.5)])
    assert comp.suppressed_indices == frozenset({0})


def test_container_alone_keeps_generic_estimate():
    assert analyze([("turkey sandwich", None)]).suppressed_indices == frozenset()


def test_container_with_side_not_suppressed():
    # "a sandwich and chips" — chips are a SIDE, not a sandwich component.
    comp = analyze([("sandwich", None), ("potato chips", None)])
    assert comp.suppressed_indices == frozenset()


def test_container_with_one_unquantified_component_not_suppressed():
    # "a sandwich and cheese"? One vague component isn't enough evidence of composition.
    assert analyze([("sandwich", None), ("cheese", None)]).suppressed_indices == frozenset()


def test_pizza_never_suppressed():
    # Pizza is the quantified calorie CARRIER ("two slices") — suppression would zero the meal.
    comp = analyze([("pepperoni pizza", 2.0), ("pepperoni", None), ("cheese", None)])
    assert comp.suppressed_indices == frozenset()


# -- the spec's regression matrix, through the REAL resolver ---------------------


async def test_sandwich_total_is_ingredient_sum_only():
    # THE field bug: 450-kcal generic sandwich stacked on the described ingredients.
    meal = await _resolve([
        _item("sandwich"),
        _item("low carb bread", 2, Unit.SLICE, brand="Healthy Life"),
        _item("turkey", 2.5, Unit.OZ),
        _item("ham", 1.5, Unit.OZ, brand="Krakus"),
        _item("provolone cheese", 2, Unit.OZ),
    ])
    sandwich = meal.items[0]
    assert sandwich.macros.kcal == 0  # display grouping, not a calorie line
    assert sandwich.grams == 0
    ingredient_sum = sum(i.macros.kcal for i in meal.items[1:])
    assert meal.totals.kcal == pytest.approx(ingredient_sum, abs=0.5)
    assert 250 <= meal.totals.kcal <= 520  # sane deli-sandwich territory, not 900+


async def test_vague_sandwich_alone_keeps_generic_calories():
    meal = await _resolve([_item("turkey sandwich")])
    assert meal.totals.kcal > 300  # the honest generic estimate survives


async def test_burger_alone_is_not_zero_calories():
    # Opposite failure mode found during this fix: the container entries were zeroed in
    # the dictionary, so a vague "I had a burger" logged 0 kcal (bug-6 rule violation).
    meal = await _resolve([_item("burger")])
    assert meal.totals.kcal > 200


async def test_burger_with_components_is_ingredient_sum():
    meal = await _resolve([
        _item("burger"), _item("hamburger bun", 1), _item("ground beef", 4, Unit.OZ),
        _item("cheddar cheese", 1, Unit.OZ), _item("ketchup", 1, Unit.TBSP),
    ])
    assert meal.items[0].macros.kcal == 0
    assert meal.totals.kcal == pytest.approx(sum(i.macros.kcal for i in meal.items[1:]), abs=0.5)


async def test_burrito_bowl_with_components_is_ingredient_sum():
    meal = await _resolve([
        _item("burrito bowl", brand="Chipotle"), _item("chicken breast", 4, Unit.OZ),
        _item("white rice", 1, Unit.CUP), _item("black beans", 0.5, Unit.CUP),
        _item("cheese", 1, Unit.OZ), _item("sour cream", 2, Unit.TBSP),
    ])
    assert meal.items[0].macros.kcal == 0
    assert meal.totals.kcal > 400  # the components carry the meal


async def test_salad_with_components_is_ingredient_sum():
    meal = await _resolve([
        _item("salad"), _item("chicken breast", 4, Unit.OZ), _item("avocado", 0.5),
        _item("feta cheese", 1, Unit.OZ), _item("ranch dressing", 2, Unit.TBSP),
    ])
    assert meal.items[0].macros.kcal == 0
    assert meal.totals.kcal > 300


async def test_smoothie_with_components_is_ingredient_sum():
    meal = await _resolve([
        _item("smoothie"), _item("banana", 1), _item("protein powder", 1, Unit.SCOOP),
        _item("peanut butter", 1, Unit.TBSP), _item("almond milk", 1, Unit.CUP),
    ])
    assert meal.items[0].macros.kcal == 0
    assert meal.totals.kcal > 250


async def test_pasta_base_is_never_suppressed():
    # Pasta is a calorie-bearing BASE, not an empty structure.
    meal = await _resolve([
        _item("pasta", 2, Unit.CUP), _item("marinara sauce"), _item("parmesan cheese", 2, Unit.TBSP),
    ])
    assert meal.items[0].macros.kcal > 200


# -- deli-context meat classification ---------------------------------------------


async def test_bare_turkey_resolves_to_deli_not_ground():
    # "2.5 oz turkey" in a sandwich must NOT hit the ground-turkey family (which fires
    # the lean-percentage question). Bare meat words join the family only with a ratio.
    r = await Resolver().resolve_item(_item("turkey", 2.5, Unit.OZ))
    assert r.source.value == "dictionary"
    assert r.match_kind.value in ("canonical", "alias")  # turkey breast (deli), not FAMILY_DEFAULT
    assert 60 <= r.macros.kcal <= 130  # deli-turkey territory for 2.5 oz, not a patty


async def test_ratio_turkey_still_hits_ground_family():
    r = await Resolver().resolve_item(
        ParsedItem(name="turkey", amount=4, unit=Unit.OZ, fat_ratio="93/7", confidence=0.9)
    )
    assert r.match_kind.value == "parameterized"


async def test_ground_turkey_still_asks_fat_content():
    from api.parser.clarify import ClarifyEngine

    decision = await ClarifyEngine().decide([_item("ground turkey", 4, Unit.OZ)], [])
    assert any(q.field.endswith(".fat_ratio") for q in decision.questions)


async def test_deli_turkey_never_asks_fat_content():
    from api.parser.clarify import ClarifyEngine

    decision = await ClarifyEngine().decide(
        [_item("sandwich"), _item("turkey", 2.5, Unit.OZ), _item("provolone cheese", 2, Unit.OZ)], []
    )
    assert not any(q.field.endswith(".fat_ratio") for q in decision.questions)


async def test_llm_proposed_fat_ratio_candidate_skipped_for_deli_turkey():
    # Even when the LLM PROPOSES the lean-% check for sandwich turkey, the engine must
    # refuse it: the item resolves canonically (deli), so the ratio axis doesn't exist.
    from api.parser.clarify import ClarifyEngine
    from api.parser.schemas import Importance, MissingDetail

    candidate = MissingDetail(
        field="items[0].fat_ratio", importance=Importance.HIGH,
        question="What was the fat ratio of the turkey?",
    )
    decision = await ClarifyEngine().decide([_item("turkey", 2.5, Unit.OZ)], [candidate])
    assert not any(q.field.endswith(".fat_ratio") for q in decision.questions)


async def test_llm_proposed_fat_ratio_still_fires_for_ground_meat():
    from api.parser.clarify import ClarifyEngine
    from api.parser.schemas import Importance, MissingDetail

    candidate = MissingDetail(
        field="items[0].fat_ratio", importance=Importance.HIGH,
        question="What was the fat ratio of the beef?",
    )
    decision = await ClarifyEngine().decide([_item("ground beef", 4, Unit.OZ)], [candidate])
    assert any(q.field.endswith(".fat_ratio") for q in decision.questions)


async def test_low_carb_bread_resolves_low_calorie():
    r = await Resolver().resolve_item(_item("low carb bread", 2, Unit.SLICE))
    assert r.source.value == "dictionary"
    assert r.macros.kcal < 120  # 2 slices of low-carb bread ~80, never generic 150+
