"""Certainty engine — the spec's testing matrix, offline and deterministic.

Items are constructed as the recorded parser WOULD emit them (no LLM), resolved through
the real dictionary-only Resolver, then scored. The user-visible contract under test:

  1. A vague log still scores (log-first — the scorer never blocks or raises).
  2. More detail → HIGHER score (monotone ladders — the "37% -> 61%" promise).
  3. Negations are respected (never coach on what the user excluded).
  4. Category-aware tips; max 3; calm copy (banned-word sweep).
  5. Caps keep treacherous meals honest (coffee w/o size, "dinner" alone).
"""

from __future__ import annotations

import pytest

from api.nutrition.resolver import Resolver
from api.parser.certainty import (
    Certainty,
    build_certainty,
    detect_category,
    item_from_resolved,
    item_from_stored,
    weekly_focus,
)
from api.parser.confidence import meal_confidence
from api.parser.schemas import ParsedItem, Unit

# The spec's shame-language ban — no output copy may contain these.
_BANNED = ("bad", "poor", "invalid", "failed", "insufficient", "incomplete", "error", "wrong")


def _item(name: str, amount=None, unit=None, brand=None, prep=None) -> ParsedItem:
    return ParsedItem(
        name=name, amount=amount, unit=unit, brand=brand, prep_method=prep, confidence=0.9
    )


async def score(transcript: str, items: list[ParsedItem]) -> Certainty:
    resolved = await Resolver().resolve_meal(items)
    conf = meal_confidence(resolved.items) if items else 0.0
    return build_certainty([item_from_resolved(r) for r in resolved.items], conf, transcript)


def _assert_calm(c: Certainty) -> None:
    for text in [c.display_label, *c.assumptions, *c.tips]:
        low = text.lower()
        for banned in _BANNED:
            assert banned not in low, f"banned word {banned!r} in {text!r}"


# -- 1. Vague logs still score; never fake precision --------------------------


async def test_vague_dinner_scores_low_but_logs():
    c = await score("i ate dinner", [])
    assert c.category == "generic_meal"
    assert 20 <= c.score <= 45
    assert c.label == "rough_estimate"
    assert c.should_show_coaching
    assert "unclear_food" in c.missing_details
    _assert_calm(c)


async def test_score_bounds_never_zero_never_hundred():
    low = await score("i ate dinner", [])
    high = await score(
        "i had 180 grams of grilled chicken breast, one cup of white rice, and broccoli",
        [
            _item("chicken breast", 180, Unit.G, prep="grilled"),
            _item("white rice", 1, Unit.CUP),
            _item("broccoli", 85, Unit.G),
        ],
    )
    assert 5 <= low.score < high.score <= 99


# -- 2. The pasta ladder: detail monotonically raises the score ---------------


async def test_pasta_ladder_is_monotone():
    bare = await score("i had pasta", [_item("pasta")])
    sauced = await score(
        "i had pasta with marinara", [_item("pasta"), _item("marinara sauce")]
    )
    detailed = await score(
        "i had two cups of pasta with marinara and parmesan",
        [_item("pasta", 2, Unit.CUP), _item("marinara sauce"), _item("parmesan cheese")],
    )
    assert bare.score < sauced.score < detailed.score, (
        bare.score, sauced.score, detailed.score
    )
    assert bare.category == "pasta_noodles"
    # Bare pasta: the playbook's gaps are all flagged.
    assert "portion_size" in bare.missing_details
    assert "sauce_or_dressing" in bare.missing_details
    # Sauce mentioned → no longer coached on it.
    assert "sauce_or_dressing" not in sauced.missing_details
    # Portion + sauce + cheese covered → cap lifts; good estimate territory.
    assert detailed.score >= 70
    assert not any("sauce" in t for t in detailed.tips)
    for c in (bare, sauced, detailed):
        _assert_calm(c)
        assert len(c.tips) <= 3


async def test_bare_pasta_lands_in_rough_to_limited_band():
    c = await score("i had a bowl of pasta", [_item("pasta")])
    assert 35 <= c.score <= 69  # spec's rough/limited band; capped until sauce+portion
    assert c.should_show_coaching


# -- 3. Negations: never coach on what the user excluded ----------------------


async def test_black_coffee_suppresses_milk_and_sweetener():
    c = await score("i had a black coffee", [_item("coffee")])
    assert c.category == "coffee_tea"
    assert "milk_or_creamer" not in c.missing_details
    assert "sweetener_or_syrup" not in c.missing_details
    assert not any("milk" in t for t in c.tips)
    # Size still unknown → still capped below high confidence.
    assert "drink_size" in c.missing_details
    assert c.score <= 69


async def test_no_milk_no_sugar_treated_like_black():
    c = await score("i had coffee, no milk, no sugar", [_item("coffee")])
    assert "milk_or_creamer" not in c.missing_details
    assert "sweetener_or_syrup" not in c.missing_details


async def test_burger_no_cheese_not_coached_on_cheese():
    c = await score("i had a burger with no cheese", [_item("burger")])
    assert c.category == "sandwich_wrap_burger"
    assert "cheese_or_toppings" not in c.missing_details
    assert not any("cheese" in t for t in c.tips)


# -- 4. Category detection across the matrix ----------------------------------


@pytest.mark.parametrize(
    ("transcript", "names", "expected"),
    [
        ("i had a caesar salad", ["salad"], "salad"),
        ("i had two slices of pizza", ["pizza"], "pizza"),
        ("i had a chipotle bowl", ["burrito bowl"], "taco_burrito_mexican"),
        ("i had grapefruit, grapes, and orange slices", ["grapefruit", "grapes", "orange"], "fruit_bowl"),
        ("i had a protein shake", ["protein shake"], "smoothie_shake"),
        ("i had a latte", ["latte"], "coffee_tea"),
        ("i had oatmeal with banana", ["oatmeal", "banana"], "oatmeal_cereal"),
        ("i had two scrambled eggs", ["egg"], "eggs"),
        ("i had chips and salsa", ["potato chips", "salsa"], "chips_crackers"),
        ("i had chicken with rice and broccoli", ["chicken breast", "white rice", "broccoli"], "protein_with_sides"),
        ("i had a glass of wine", ["wine"], "alcohol"),
    ],
)
async def test_category_detection(transcript, names, expected):
    c = await score(transcript, [_item(n) for n in names])
    assert c.category == expected, f"{transcript!r} -> {c.category}"


# -- 5. Detail signals move the score the right way ---------------------------


async def test_hedging_lowers_score():
    plain = await score(
        "i had a cup of rice and chicken", [_item("white rice", 1, Unit.CUP), _item("chicken breast")]
    )
    hedged = await score(
        "i think i had about a cup of rice and some chicken",
        [_item("white rice", 1, Unit.CUP), _item("chicken breast")],
    )
    assert hedged.score < plain.score


async def test_stated_grams_beat_vague_amounts():
    vague = await score("i had chicken", [_item("chicken breast")])
    weighed = await score("i had 180 grams of chicken", [_item("chicken breast", 180, Unit.G)])
    assert weighed.score > vague.score
    assert "protein_amount" not in weighed.missing_details


async def test_brand_helps_packaged_snacks():
    unbranded = await score("i had a protein bar", [_item("protein bar")])
    branded = await score(
        "i had a quest protein bar", [_item("protein bar", brand="Quest")]
    )
    assert branded.score > unbranded.score
    assert "brand_or_restaurant" not in branded.missing_details
    assert "brand_or_restaurant" in unbranded.missing_details


async def test_fruit_bowl_with_named_fruits_covers_ingredients():
    c = await score(
        "i had grapefruit, grapes, and orange slices",
        [_item("grapefruit"), _item("grapes"), _item("orange")],
    )
    assert "main_ingredients" not in c.missing_details
    assert "bowl_or_plate_size" in c.missing_details  # amounts still unstated


# -- 6. Coaching gate ----------------------------------------------------------


async def test_high_scores_do_not_coach():
    c = await score(
        "i had 180 grams of grilled chicken breast with 200 grams of white rice and marinara",
        [
            _item("chicken breast", 180, Unit.G, prep="grilled"),
            _item("white rice", 200, Unit.G),
            _item("marinara sauce", 2, Unit.TBSP),
        ],
    )
    assert c.score >= 75
    assert not c.should_show_coaching


async def test_estimated_items_flagged_honestly():
    # An unresolved food (not in dictionary, no estimator offline) is called out calmly.
    c = await score("i had spanakopita", [_item("spanakopita")])
    assert "unclear_food" in c.missing_details
    _assert_calm(c)


# -- 7. Weekly aggregation helper ----------------------------------------------


def test_weekly_focus_picks_most_common_detail():
    detail, tip = weekly_focus(
        [["portion_size", "sauce_or_dressing"], ["portion_size"], ["portion_size", "cheese_or_toppings"]]
    )
    assert detail == "portion_size"
    assert tip is not None
    assert "two cups" in tip


def test_weekly_focus_empty_is_none():
    assert weekly_focus([]) == (None, None)


def test_stored_item_adapter_round_trip():
    stored = {
        "name": "pasta", "amount": None, "unit": None, "brand": None, "prep_method": None,
        "is_estimate": False, "source": "dictionary", "macros": {"kcal": 220.0},
    }
    item = item_from_stored(stored)
    assert item.name == "pasta"
    assert item.kcal == 220.0
    assert not item.unresolved
    c = build_certainty([item], 0.55, "i had pasta")
    assert c.category == "pasta_noodles"


def test_detect_category_no_items_uses_transcript():
    assert detect_category([], "i ate dinner") == "generic_meal"
    assert detect_category([], "mystery stuff") == "unknown"
