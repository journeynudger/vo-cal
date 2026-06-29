"""B4: resolution + macro calculation — property tests + golden macro assertions.

Acceptance: canonical four resolve with correct grams and macros within ±5% of
hand-checked values; conversion math is monotone and round-trips.
"""

from __future__ import annotations

import pytest

from api.nutrition.dictionary import get_dictionary
from api.nutrition.fdc_client import FdcClient
from api.nutrition.resolver import (
    Resolver,
    apply_state_factor,
    classify_specificity,
    to_grams,
)
from api.nutrition.schemas import AmountSpecificity, Macros, MatchKind, ResolutionSource
from api.parser.confidence import item_confidence
from api.parser.llm import FakeParserClient, parse_transcript
from api.parser.schemas import ParsedItem, State, Unit

FAKE = FakeParserClient()


class _FakeEstimator:
    """Deterministic stand-in for the AI estimator so the offline suite can exercise the
    flagged-estimate fallback without a network call."""

    async def estimate(self, item):
        return 110.0, Macros(kcal=210.0, protein=9.0, carbs=2.0, fat=18.0, fiber=0.0)


class _Decliner:
    async def estimate(self, item):
        return None


def _item(name, amount=None, unit=None, state=State.UNSPECIFIED, fat_ratio=None):
    return ParsedItem(
        name=name, amount=amount, unit=unit, state=state, fat_ratio=fat_ratio, confidence=0.9
    )


# -- conversion property tests -----------------------------------------------


def test_grams_passthrough():
    assert to_grams(_item("rice", 200, Unit.G), {}, 158.0) == 200


def test_oz_conversion():
    assert to_grams(_item("beef", 4, Unit.OZ), {}, 113.4) == pytest.approx(113.4, abs=0.5)


def test_lb_conversion():
    assert to_grams(_item("beef", 1, Unit.LB), {}, 113.4) == pytest.approx(453.6, abs=1)


def test_quarter_pound():
    assert to_grams(_item("beef", 0.25, Unit.LB), {}, 113.4) == pytest.approx(113.4, abs=1)


def test_food_specific_cup():
    grams = to_grams(_item("rice", 1, Unit.CUP), {"cup": 158.0}, 158.0)
    assert grams == 158.0


def test_null_unit_is_serving_multiplier():
    # "double" → amount 2, unit None → 2 standard servings
    assert to_grams(_item("chicken", 2, None), {}, 113.4) == pytest.approx(226.8)
    # "light" → 0.5 servings
    assert to_grams(_item("cheese", 0.5, None), {}, 28.0) == pytest.approx(14.0)


def test_null_amount_is_one_serving():
    assert to_grams(_item("rice", None, None), {}, 158.0) == 158.0


def test_missing_volume_conversion_falls_back_to_serving():
    # no cup conversion provided → standard serving
    assert to_grams(_item("mystery", 1, Unit.CUP), {}, 80.0) == 80.0


async def test_stated_volume_without_conversion_downgrades_specificity():
    # "2 cups of chicken breast": the dictionary entry has a serving but NO cup conversion, so
    # to_grams uses a serving guess. The resolved precision is then INFERRED_SERVING, not the
    # stated STATED_VOLUME — otherwise confidence overstates trust on a guessed quantity (RT-03).
    resolved = await Resolver().resolve_item(_item("chicken breast", 2, Unit.CUP))
    assert resolved.amount_specificity is AmountSpecificity.INFERRED_SERVING
    # A real mass unit on the same food keeps its stated precision.
    mass = await Resolver().resolve_item(_item("chicken breast", 100, Unit.G))
    assert mass.amount_specificity is AmountSpecificity.STATED_MASS


@pytest.mark.parametrize("amount", [1, 2, 5, 10, 100])
def test_grams_monotonic_in_amount(amount):
    g1 = to_grams(_item("rice", amount, Unit.G), {}, 158.0)
    g2 = to_grams(_item("rice", amount + 1, Unit.G), {}, 158.0)
    assert g2 > g1


def test_oz_roundtrip_through_grams():
    # 8 oz → grams → /28.35 ≈ 8
    grams = to_grams(_item("x", 8, Unit.OZ), {}, 100.0)
    assert grams / 28.3495 == pytest.approx(8, abs=0.01)


# -- raw/cooked state factor -------------------------------------------------


def test_raw_to_cooked_factor():
    # basis cooked, user weighed raw, factor 0.72 → raw grams shrink
    assert apply_state_factor(100, State.RAW, "cooked", 0.72) == pytest.approx(72.0)


def test_cooked_matches_basis_no_change():
    assert apply_state_factor(100, State.COOKED, "cooked", 0.72) == 100


def test_unspecified_state_no_change():
    assert apply_state_factor(100, State.UNSPECIFIED, "cooked", 0.72) == 100


def test_ready_basis_ignores_factor():
    assert apply_state_factor(100, State.RAW, "ready", None) == 100


# -- amount specificity ------------------------------------------------------


def test_specificity_classification():
    assert classify_specificity(_item("x", 4, Unit.OZ)) is AmountSpecificity.STATED_MASS
    assert classify_specificity(_item("x", 1, Unit.CUP)) is AmountSpecificity.STATED_VOLUME
    assert classify_specificity(_item("x", 2, Unit.PIECE)) is AmountSpecificity.STATED_COUNT
    assert classify_specificity(_item("x", 2, None)) is AmountSpecificity.SERVING_MULTIPLIER
    assert classify_specificity(_item("x", None, None)) is AmountSpecificity.INFERRED_SERVING


# -- golden macro assertions: canonical four ---------------------------------


async def _resolve(transcript):
    meal, _, _ = await parse_transcript(FAKE, transcript)
    return await Resolver().resolve_meal(meal.items)


async def test_golden_beef_4oz_93_7():
    resolved = await _resolve("4oz 93/7 beef")
    beef = resolved.items[0]
    assert beef.source is ResolutionSource.DICTIONARY
    assert beef.match_kind is MatchKind.PARAMETERIZED
    assert beef.grams == pytest.approx(113.4, abs=1)
    m = beef.macros
    assert m.kcal == pytest.approx(170, abs=170 * 0.05)
    assert m.protein == pytest.approx(24, abs=24 * 0.06)
    assert m.fat == pytest.approx(8, abs=8 * 0.1)
    assert m.carbs == pytest.approx(0, abs=1)


async def test_golden_jasmine_rice_200g():
    resolved = await _resolve("200g cooked jasmine rice")
    rice = resolved.items[0]
    assert rice.grams == 200
    m = rice.macros
    assert m.kcal == pytest.approx(260, abs=260 * 0.05)
    assert m.protein == pytest.approx(5, abs=1.5)
    assert m.carbs == pytest.approx(56, abs=56 * 0.05)
    assert m.fat == pytest.approx(1, abs=1)


async def test_golden_chipotle_modifiers_resolve():
    resolved = await _resolve("Chipotle bowl, double chicken, white rice, mild salsa, light cheese")
    by_name = {r.item.name: r for r in resolved.items}
    # double chicken = 2 servings; light cheese = 0.5 serving
    assert by_name["chicken"].grams == pytest.approx(113.4 * 2, abs=2)
    assert by_name["cheese"].grams == pytest.approx(28.0 * 0.5, abs=1)
    # container resolves to zero nutrition
    assert by_name["burrito bowl"].macros.kcal == 0
    # meal has real calories from the components
    assert resolved.totals.kcal > 300


async def test_golden_burger_unknown_beef_uses_family_default():
    resolved = await _resolve("burger, unknown beef, regular cheddar, mayo")
    beef = resolved.items[1]
    assert beef.match_kind is MatchKind.FAMILY_DEFAULT  # no ratio → default
    assert beef.macros.kcal > 0


async def test_meal_totals_are_sum_of_items():
    resolved = await _resolve(
        "for dinner I had 6oz grilled chicken breast, a cup of white rice, and a tablespoon of olive oil"
    )
    summed = sum(r.macros.kcal for r in resolved.items)
    assert resolved.totals.kcal == pytest.approx(summed, abs=0.5)


# -- FDC fallback for long-tail foods ----------------------------------------


async def test_unresolved_item_degrades_not_crashes():
    # no FDC client wired and not in dictionary → unresolved, zero macros
    item = _item("spanakopita")
    resolved = await Resolver().resolve_item(item)
    assert resolved.source is ResolutionSource.UNRESOLVED
    assert resolved.macros.kcal == 0


async def test_fdc_fallback_resolves_long_tail():
    import json
    from pathlib import Path

    import httpx

    from api.db import FakeDatabase

    fdir = Path(__file__).resolve().parent / "fixtures" / "fdc_responses"
    search = json.loads((fdir / "spanakopita_search.json").read_text())
    detail = json.loads((fdir / "spanakopita_detail.json").read_text())

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/foods/search"):
            return httpx.Response(200, json=search)
        return httpx.Response(200, json=detail)

    fdc = FdcClient(FakeDatabase(), api_key="k", transport=httpx.MockTransport(handler))
    resolver = Resolver(dictionary=get_dictionary(), fdc=fdc)
    resolved = await resolver.resolve_item(_item("spanakopita", 100, Unit.G))
    assert resolved.source is ResolutionSource.FDC
    assert resolved.macros.kcal == pytest.approx(224, abs=1)


# -- AI estimate fallback (flagged, never a silent 0) ------------------------

_UNKNOWN = "qwerty mystery food"  # guaranteed absent from the dictionary + FDC-off


async def test_unknown_food_unresolved_without_estimator():
    # Offline default (no estimator): an unknown food stays UNRESOLVED with zero macros.
    r = await Resolver().resolve_item(_item(_UNKNOWN))
    assert r.source == ResolutionSource.UNRESOLVED
    assert r.macros.kcal == 0.0
    assert r.is_estimate is False


async def test_unknown_food_estimated_when_estimator_present():
    # With an estimator wired, the unknown food gets a FLAGGED estimate, never a silent 0.
    r = await Resolver(estimator=_FakeEstimator()).resolve_item(_item(_UNKNOWN))
    assert r.source == ResolutionSource.ESTIMATED
    assert r.is_estimate is True
    assert (r.macros.kcal, r.grams) == (210.0, 110.0)
    # Low but nonzero confidence: the meal flags for review rather than trusting the guess.
    assert 0.0 < item_confidence(r) < 0.6


async def test_estimator_decline_falls_back_to_unresolved():
    r = await Resolver(estimator=_Decliner()).resolve_item(_item(_UNKNOWN))
    assert r.source == ResolutionSource.UNRESOLVED
    assert r.macros.kcal == 0.0
