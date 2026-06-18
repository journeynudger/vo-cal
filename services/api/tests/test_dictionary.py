"""B1: internal food dictionary — lookup, aliases, fat-ratio family, modifiers.

Acceptance: all four canonical examples resolve fully from the dictionary
without touching USDA.
"""

from __future__ import annotations

import pytest

from api.nutrition.dictionary import (
    SERVING_MODIFIERS,
    FoodDictionary,
    apply_modifier,
    get_dictionary,
)
from api.nutrition.schemas import MatchKind

DICT = get_dictionary()


def test_seed_has_curated_volume():
    assert 150 <= len(DICT) <= 300


def test_exact_canonical_hit():
    m = DICT.lookup("jasmine rice")
    assert m is not None
    assert m.kind is MatchKind.CANONICAL
    assert m.entry.canonical_name == "jasmine rice"


def test_alias_hit():
    m = DICT.lookup("grilled chicken breast")
    assert m is not None
    assert m.kind is MatchKind.ALIAS
    assert m.entry.canonical_name == "chicken breast"


def test_alias_normalizes_case_and_punctuation():
    assert DICT.lookup("  Jasmine Rice.  ") is not None
    assert DICT.lookup("MAYO") is not None


def test_miss_returns_none():
    assert DICT.lookup("spanakopita") is None


# -- canonical fixture foods all resolve from the dictionary -----------------


@pytest.mark.parametrize(
    "name",
    [
        "ground beef",
        "jasmine rice",
        "white rice",
        "chicken",
        "cheese",
        "cheddar cheese",
        "mayo",
        "salsa",
        "burrito bowl",
        "burger",
        "egg",
        "toast",
        "olive oil",
    ],
)
def test_canonical_fixture_foods_resolve(name):
    assert DICT.lookup(name) is not None


# -- fat-ratio parameterized ground meat -------------------------------------


def test_exact_fat_ratio_anchor():
    m = DICT.lookup("ground beef", fat_ratio="93/7")
    assert m.kind is MatchKind.PARAMETERIZED
    assert m.resolved_fat_ratio == "93/7"
    # 4oz (113.4g) cooked 93/7 ≈ 170 kcal / 24 P / 8 F
    macros = m.entry.profile.for_grams(113.4)
    assert macros.kcal == pytest.approx(170, abs=8)
    assert macros.protein == pytest.approx(24, abs=2)
    assert macros.fat == pytest.approx(8, abs=2)


def test_bare_beef_name_with_ratio_uses_family():
    m = DICT.lookup("beef", fat_ratio="80/20")
    assert m.kind is MatchKind.PARAMETERIZED
    assert m.resolved_fat_ratio == "80/20"


def test_interpolated_fat_ratio_between_anchors():
    # 88/12 is not a curated anchor → interpolated between 85/15 and 90/10
    m = DICT.lookup("ground beef", fat_ratio="88/12")
    assert m.kind is MatchKind.PARAMETERIZED
    leaner = DICT.lookup("ground beef", fat_ratio="90/10").entry.profile
    fattier = DICT.lookup("ground beef", fat_ratio="85/15").entry.profile
    # interpolated fat sits strictly between the two anchors
    assert fattier.fat > m.entry.profile.fat > leaner.fat


def test_unknown_ratio_falls_to_family_default():
    m = DICT.lookup("ground beef", fat_ratio=None)
    assert m.kind is MatchKind.FAMILY_DEFAULT
    assert m.entry.canonical_name == "ground beef"


def test_extreme_ratio_clamps_to_nearest_anchor():
    m = DICT.lookup("ground beef", fat_ratio="50/50")  # below leanest anchor
    assert m.kind is MatchKind.PARAMETERIZED
    fattiest = DICT.lookup("ground beef", fat_ratio="70/30").entry.profile
    assert m.entry.profile.fat == pytest.approx(fattiest.fat)


# -- modifier math -----------------------------------------------------------


def test_modifier_table_matches_contract():
    assert SERVING_MODIFIERS["double"] == 2.0
    assert SERVING_MODIFIERS["triple"] == 3.0
    assert SERVING_MODIFIERS["light"] == 0.5
    assert SERVING_MODIFIERS["extra"] == 1.5
    assert SERVING_MODIFIERS["half"] == 0.5


def test_apply_modifier():
    assert apply_modifier("double") == 2.0
    assert apply_modifier("light") == 0.5
    assert apply_modifier("extra") == 1.5
    assert apply_modifier("unknown") == 1.0  # unrecognized → 1×


def test_unit_conversions_present_for_countable_foods():
    egg = DICT.lookup("egg").entry
    assert egg.unit_conversions["piece"] == 50.0
    rice = DICT.lookup("jasmine rice").entry
    assert rice.unit_conversions["cup"] == 158.0


def test_raw_cooked_factor_on_meats_and_grains():
    assert DICT.lookup("chicken breast").entry.raw_cooked_factor is not None
    assert DICT.lookup("jasmine rice").entry.raw_cooked_factor is not None
    # ready-to-eat foods have no factor
    assert DICT.lookup("mayo").entry.raw_cooked_factor is None


def test_jasmine_rice_macros():
    rice = DICT.lookup("jasmine rice").entry
    macros = rice.profile.for_grams(200)
    assert macros.kcal == pytest.approx(260, abs=10)
    assert macros.carbs == pytest.approx(56, abs=3)
    assert macros.protein == pytest.approx(5, abs=1.5)


def test_singleton_is_stable():
    assert get_dictionary() is get_dictionary()


def test_from_seed_loads_independently():
    fresh = FoodDictionary.from_seed()
    assert len(fresh) == len(DICT)
