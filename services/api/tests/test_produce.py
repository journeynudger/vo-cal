"""E0: produce-serving food-group lookups in the food dictionary.

Produce is a home-dashboard pillar (decision #28). Fruits/vegetables carry a
``produce_servings`` field crediting servings per standard serving; everything
else credits zero. Matching reuses the resolver's lookup path (canonical/alias)
so the Today aggregation can total produce deterministically.
"""

from __future__ import annotations

import pytest

from api.nutrition.dictionary import get_dictionary

DICT = get_dictionary()


def test_vegetable_entry_carries_produce_servings():
    broccoli = DICT.lookup("broccoli").entry
    assert broccoli.produce_servings == 1.0


def test_fruit_entry_carries_produce_servings():
    banana = DICT.lookup("banana").entry
    assert banana.produce_servings == 1.0


def test_non_produce_entry_has_zero_produce_servings():
    # Default when the seed omits the field.
    assert DICT.lookup("chicken breast").entry.produce_servings == 0.0
    assert DICT.lookup("white rice").entry.produce_servings == 0.0
    assert DICT.lookup("olive oil").entry.produce_servings == 0.0


def test_produce_servings_for_one_standard_serving():
    # One serving of broccoli (serving_grams) credits exactly its produce_servings.
    grams = DICT.lookup("broccoli").entry.serving_grams
    assert DICT.produce_servings_for("broccoli", grams) == pytest.approx(1.0)


def test_produce_servings_scale_linearly_with_grams():
    entry = DICT.lookup("broccoli").entry
    half = DICT.produce_servings_for("broccoli", entry.serving_grams / 2)
    double = DICT.produce_servings_for("broccoli", entry.serving_grams * 2)
    assert half == pytest.approx(0.5)
    assert double == pytest.approx(2.0)


def test_produce_servings_via_alias():
    # "steamed broccoli" is an alias of broccoli; produce still resolves.
    grams = DICT.lookup("broccoli").entry.serving_grams
    assert DICT.produce_servings_for("steamed broccoli", grams) == pytest.approx(1.0)


def test_non_produce_food_credits_zero_produce():
    grams = DICT.lookup("chicken breast").entry.serving_grams
    assert DICT.produce_servings_for("chicken breast", grams) == 0.0


def test_unresolved_food_credits_zero_produce():
    # A miss (not in the dictionary) never guesses produce.
    assert DICT.produce_servings_for("spanakopita", 200.0) == 0.0


def test_partial_serving_vegetable_credits_fraction():
    # Onion's standard serving is a smaller garnish portion (produce_servings 0.7).
    onion = DICT.lookup("onion").entry
    assert onion.produce_servings == pytest.approx(0.7)
    assert DICT.produce_servings_for("onion", onion.serving_grams) == pytest.approx(0.7)


def test_zero_grams_credits_zero():
    assert DICT.produce_servings_for("broccoli", 0.0) == 0.0
