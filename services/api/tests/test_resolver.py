"""B4: resolution + macro calculation — property tests + golden macro assertions.

Acceptance: canonical four resolve with correct grams and macros within ±5% of
hand-checked values; conversion math is monotone and round-trips.
"""

from __future__ import annotations

import pytest

from api.nutrition.dictionary import get_dictionary
from api.nutrition.fdc_client import FdcClient
from api.nutrition.resolver import (
    GRAMS_PER_OZ,
    UNRESOLVED_IDENTITY,
    Resolver,
    apply_state_factor,
    classify_specificity,
    persistable_identity,
    stored_identities,
    to_grams,
)
from api.nutrition.schemas import AmountSpecificity, MatchKind, ResolutionSource
from api.parser.confidence import item_confidence
from api.parser.llm import FakeParserClient, parse_transcript
from api.parser.schemas import ParsedItem, State, Unit

FAKE = FakeParserClient()


class _FakeEstimator:
    """Deterministic stand-in for the AI estimator so the offline suite can exercise the
    flagged-estimate fallback without a network call. New shape (2026-07): a per-100g
    food identity + serving grams; the resolver does the portion math locally."""

    async def estimate(self, item):
        from api.nutrition.estimator import EstimatedFood
        from api.nutrition.schemas import NutrientProfile

        return EstimatedFood(
            per_100g=NutrientProfile(
                kcal=190.909, protein=8.1818, carbs=1.8181, fat=16.3636, fiber=0.0
            ),  # 110 g serving -> 210 kcal, matching the pre-2026-07 expectations
            serving_grams=110.0,
        )


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


def test_missing_volume_conversion_is_physical_volume_at_density():
    # No cup conversion → a cup is 240 ml at the food's density (default 1 g/ml), never
    # amount × serving ("two cups of spaghetti bolognese" was two 350 g plates, 2026-09-23).
    assert to_grams(_item("mystery", 1, Unit.CUP), {}, 80.0) == 240.0
    assert to_grams(_item("mystery", 2, Unit.TBSP), {}, 100.0) == 30.0
    assert to_grams(_item("syrupy", 1, Unit.TSP), {"ml": 1.3}, 100.0) == pytest.approx(6.5)


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
    assert grams / GRAMS_PER_OZ == pytest.approx(8, abs=0.01)


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
    # Unspecified state prices in the entry's basis state — COOKED (USDA pan-broiled):
    # 4 oz cooked 93/7 ≈ 215 kcal / 30 P. The old 170/24 golden was the raw label
    # value, baked in while the seed carried raw numbers mislabeled as cooked.
    assert m.kcal == pytest.approx(215, abs=215 * 0.05)
    assert m.protein == pytest.approx(30, abs=30 * 0.06)
    assert m.fat == pytest.approx(10, abs=10 * 0.1)
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
    # Through the REAL parse path (composition pass included): the bowl is a display
    # grouping — zeroed BY THE COMPOSITION PASS, not by a zeroed dictionary entry
    # (the entry now carries generic calories so a vague "a bowl" alone isn't 0 kcal).
    from api.parser.router import resolve_with_composition

    meal, _, _ = await parse_transcript(FAKE, "Chipotle bowl, double chicken, white rice, mild salsa, light cheese")
    resolved, composition = await resolve_with_composition(Resolver(), meal.items)
    by_name = {r.item.name: r for r in resolved.items}
    # double chicken = 2 servings; light cheese = 0.5 serving
    assert by_name["chicken"].grams == pytest.approx(113.4 * 2, abs=2)
    assert by_name["cheese"].grams == pytest.approx(28.0 * 0.5, abs=1)
    # container suppressed to zero nutrition (components carry the meal)
    assert "burrito bowl" in composition.suppressed_names
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
    assert r.grams == 110.0
    assert r.macros.kcal == pytest.approx(210.0, abs=0.5)
    # Low but nonzero confidence: the meal flags for review rather than trusting the guess.
    assert 0.0 < item_confidence(r) < 0.6


async def test_estimator_decline_falls_back_to_unresolved():
    r = await Resolver(estimator=_Decliner()).resolve_item(_item(_UNKNOWN))
    assert r.source == ResolutionSource.UNRESOLVED
    assert r.macros.kcal == 0.0


class _CountingEstimator:
    """Counts estimate() calls so the memo test can prove a duplicate resolve is free."""

    def __init__(self) -> None:
        self.calls = 0

    async def estimate(self, item):
        self.calls += 1
        return await _FakeEstimator().estimate(item)


async def test_resolve_item_is_memoized_within_a_resolver():
    # The clarify engine re-resolves items resolve_meal already resolved. With a live
    # estimator that was a SECOND paid, nondeterministic LLM call per unknown item per
    # parse. A Resolver is request-scoped, so it memoizes: the estimator is hit once and
    # the second resolve returns the identical ResolvedItem.
    est = _CountingEstimator()
    resolver = Resolver(estimator=est)
    first = await resolver.resolve_item(_item(_UNKNOWN))
    second = await resolver.resolve_item(_item(_UNKNOWN))
    assert est.calls == 1  # not 2 — the duplicate resolve was served from the memo
    assert first == second


async def test_ground_turkey_variant_answer_is_honored_as_fat_ratio():
    # RT-50 class: a variant answer for a ground meat ("99/1") is the fat-ratio axis in
    # disguise. It must resolve to that ratio, never be silently dropped to the ~85/15
    # default (which would read as "never answered" and re-ask forever).
    default = await Resolver().resolve_item(_item("ground turkey"))
    answered = await Resolver().resolve_item(
        ParsedItem(name="ground turkey", variant="99/1", confidence=0.9)
    )
    assert answered.macros.kcal != default.macros.kcal
    assert answered.resolved_fat_ratio == "99/1"


# -- bug 6: common fruits / fruit bowls must never resolve to 0 in the preview ----

@pytest.mark.parametrize(
    "name",
    ["grapefruit", "raspberries", "blackberries", "watermelon", "fruit bowl", "orange slices"],
)
async def test_common_fruits_resolve_nonzero(name):
    # Before adding these to the dictionary they resolved UNRESOLVED → 0 kcal (the bug). They
    # must now resolve deterministically (dictionary, no estimator needed) with real calories.
    resolved = await Resolver().resolve_item(_item(name))
    assert resolved.source == ResolutionSource.DICTIONARY, f"{name} should hit the dictionary"
    assert resolved.macros.kcal > 0, f"{name} must not be 0 kcal"


# -- count-unit safety + resolution routing (field bugs 2026-07) ---------------
# "2 pieces of turkey bacon" -> FDC 2 x 100 g = 736 kcal (build 18); "iced matcha"
# -> 100 g of matcha POWDER (418 kcal). FDC is per-100g with no serving/per-piece
# data, so counts and null amounts route to the estimator; the one-serving floor
# lives in to_grams itself so no resolution path can multiply count x serving.


class _FakeFdc:
    """Duck-typed FdcClient stand-in: always 'finds' a per-100g profile."""

    def __init__(self):
        from api.nutrition.fdc_client import FdcResult
        from api.nutrition.schemas import NutrientProfile

        self.calls = 0
        self._result = FdcResult(
            fdc_id=1,
            description="Bison bacon, cooked",
            profile=NutrientProfile(kcal=368, protein=29.5, carbs=4.24, fat=25.87, fiber=0.0),
        )

    async def resolve(self, term, **_):
        self.calls += 1
        return self._result


class _SlicedEstimator:
    """Estimator that knows a per-slice weight (the accurate count path)."""

    async def estimate(self, item):
        from api.nutrition.estimator import EstimatedFood
        from api.nutrition.schemas import NutrientProfile

        return EstimatedFood(
            per_100g=NutrientProfile(kcal=250, protein=20, carbs=2, fat=17.5, fiber=0.0),
            serving_grams=30.0,
            unit_conversions={"piece": 10.0, "slice": 10.0},
        )


def test_count_unit_without_conversion_is_one_serving_never_count_times_serving():
    assert to_grams(_item("bison bacon", 2, Unit.PIECE), {}, 100.0) == 100.0
    assert to_grams(_item("bison bacon", 3, Unit.SLICE), {}, 100.0) == 100.0
    assert to_grams(_item("mystery powder", 2, Unit.SCOOP), {}, 31.0) == 31.0


def test_count_unit_with_conversion_scales_by_count():
    assert to_grams(_item("bison bacon", 2, Unit.SLICE), {"slice": 10.0}, 100.0) == 20.0


async def test_count_stated_item_prefers_estimator_over_fdc():
    # Probe must be suffix-proof: "bison bacon" now legitimately suffix-matches the
    # curated bacon entry (2026-08-20), so a truly-unknown name carries this test.
    fdc = _FakeFdc()
    r = await Resolver(fdc=fdc, estimator=_SlicedEstimator()).resolve_item(
        _item(_UNKNOWN, 2, Unit.PIECE)
    )
    assert r.source is ResolutionSource.ESTIMATED
    assert r.grams == 20.0
    assert r.macros.kcal == pytest.approx(50.0)
    assert fdc.calls == 0


async def test_null_amount_item_prefers_estimator_over_fdc():
    fdc = _FakeFdc()
    r = await Resolver(fdc=fdc, estimator=_SlicedEstimator()).resolve_item(_item("iced matcha"))
    assert r.source is ResolutionSource.ESTIMATED
    assert r.grams == 30.0
    assert fdc.calls == 0


async def test_mass_stated_suffix_food_prices_from_the_curated_head_not_fdc():
    # 2026-09-23: the curated head wins for EVERY amount kind. The 2026-08-20 exception
    # (USDA search first for a stated mass, so "50 g bison bacon" could find USDA's bison
    # row) is the mechanism that priced "200 g cosmic crisp apple" as USDA's apple-crisp
    # DESSERT (322 kcal) while "a cosmic crisp apple" priced the curated apple: the food
    # depended on the unit. The prefix is visible as priced_as and a name edit re-identifies.
    fdc = _FakeFdc()
    r = await Resolver(fdc=fdc, estimator=_SlicedEstimator()).resolve_item(
        _item("bison bacon", 50, Unit.G)
    )
    assert r.source is ResolutionSource.DICTIONARY
    assert r.match_kind is MatchKind.SUFFIX
    assert r.identity.priced_as == "bacon"
    assert r.grams == 50.0
    assert fdc.calls == 0


async def test_null_amount_without_estimator_is_unresolved_not_per_100g():
    # THE 234-kcal Big Mac shape (field bug 2026-07-19): a bare mention ("a Big Mac")
    # that misses the dictionary must NEVER price as 100 g of the FDC per-100g row —
    # that ships the per-100g calories as the whole item at a confident-looking badge.
    fdc = _FakeFdc()
    r = await Resolver(fdc=fdc, estimator=None).resolve_item(_item("big mac"))
    assert r.source is ResolutionSource.UNRESOLVED
    assert r.macros.kcal == 0.0
    # Identity may consult FDC (it never reads the amount), but a per-100g identity without
    # portion data prices a stated MASS only — never a bare mention (price() refuses).


async def test_count_stated_without_estimator_is_unresolved_not_a_100g_guess():
    # FDC can't price a count (per-100g rows, no piece weights). The old behavior
    # floored at a 100 g "serving" — the same silent guess that logged "a Big Mac"
    # as its per-100g row (234 kcal, field bug 2026-07-19). Honest floor is now
    # unresolved: zero macros + the missing-detail flow, never an invented portion.
    r = await Resolver(fdc=_FakeFdc(), estimator=None).resolve_item(
        _item(_UNKNOWN, 2, Unit.PIECE)
    )
    assert r.source is ResolutionSource.UNRESOLVED
    assert r.macros.kcal == 0.0


async def test_estimator_decline_on_count_item_is_not_retried():
    class _CountingDecliner:
        def __init__(self):
            self.calls = 0

        async def estimate(self, item):
            self.calls += 1

    d = _CountingDecliner()
    r = await Resolver(fdc=_FakeFdc(), estimator=d).resolve_item(
        _item(_UNKNOWN, 2, Unit.PIECE)
    )
    assert r.source is ResolutionSource.UNRESOLVED  # count can't be priced honestly
    assert d.calls == 1  # the decline was not paid for twice


# -- curated-brand preemption + suffix scoring (field reports 2026-08-20) -----


class _CountingEstimator(_FakeEstimator):
    def __init__(self):
        self.calls = 0

    async def estimate(self, item):
        self.calls += 1
        return await super().estimate(item)


@pytest.mark.asyncio
async def test_curated_brand_preempts_the_estimator():
    # Fairlife is curated: the milk must resolve from the dictionary without paying
    # the estimator (2026-08-20: the AI route returned sibling products — shakes).
    est = _CountingEstimator()
    item = ParsedItem(
        name="2% milk", brand="Fairlife", amount=1, unit=Unit.CUP,
        state=State.UNSPECIFIED, fat_ratio=None, confidence=0.9,
    )
    r = await Resolver(estimator=est).resolve_item(item)
    assert est.calls == 0
    assert r.source is ResolutionSource.DICTIONARY
    assert not r.is_estimate
    assert r.macros.kcal == pytest.approx(121, rel=0.05)  # 247 g x 49 kcal/100g


class _CountingYogurtEstimator:
    """A plausible branded label read (95 kcal/100 g, inside the curated head's band)."""

    def __init__(self):
        self.calls = 0

    async def estimate(self, item):
        from api.nutrition.estimator import EstimatedFood
        from api.nutrition.schemas import NutrientProfile

        self.calls += 1
        return EstimatedFood(
            per_100g=NutrientProfile(kcal=95, protein=9.0, carbs=10.0, fat=2.5, fiber=0.0),
            serving_grams=150.0,
        )


@pytest.mark.asyncio
async def test_uncurated_brand_stays_ai_first():
    # The 2026-07 Chobani fix is untouched: an uncurated brand goes to the estimator
    # even though a generic dictionary name would match. (Since 2026-09-23 the read must
    # also sit inside the curated head's sanity band — a plausible label read does.)
    est = _CountingYogurtEstimator()
    item = ParsedItem(
        name="greek yogurt", brand="Chobani", amount=1, unit=Unit.CUP,
        state=State.UNSPECIFIED, fat_ratio=None, confidence=0.9,
    )
    r = await Resolver(estimator=est).resolve_item(item)
    assert est.calls == 1
    assert r.is_estimate


@pytest.mark.asyncio
async def test_suffix_match_scores_below_alias_and_prices_the_pinned_variant():
    r = await Resolver().resolve_item(_item("kitkat creamer"))
    assert r.match_kind is MatchKind.SUFFIX
    assert r.match_score == pytest.approx(0.8)
    # One standard serving (15 g) of the flavored variant: ~35 kcal, never unresolved.
    assert r.macros.kcal == pytest.approx(35, rel=0.15)
    assert r.resolved_variant == "flavored"


@pytest.mark.asyncio
async def test_count_stated_suffix_food_resolves_without_paying_the_estimator():
    # "2 pieces of bison bacon": the curated bacon entry (suffix rescue) prices it
    # deterministically — the estimator is never consulted (cost discipline 2026-08-20).
    est = _CountingEstimator()
    r = await Resolver(estimator=est).resolve_item(_item("bison bacon", 2, Unit.PIECE))
    assert est.calls == 0
    assert r.source is ResolutionSource.DICTIONARY
    assert r.match_kind is MatchKind.SUFFIX


# -- identity is independent of the amount (2026-09-23, the apple incident class) -----
# "200 g cosmic crisp apple" priced USDA's apple-crisp dessert; "a cosmic crisp apple"
# priced the curated apple. WHICH food is being priced must never depend on how much of
# it was stated, and an amount edit must re-price the identity the user already saw.


async def test_identity_never_depends_on_the_amount():
    fdc = _FakeFdc()
    resolver = Resolver(fdc=fdc, estimator=_SlicedEstimator())
    by_mass = await resolver.resolve_item(_item("cosmic crisp apple", 200, Unit.G))
    by_mention = await resolver.resolve_item(_item("cosmic crisp apple"))
    by_count = await resolver.resolve_item(_item("cosmic crisp apple", 1, Unit.PIECE))
    assert by_mass.identity == by_mention.identity == by_count.identity
    assert by_mass.identity.key == "dictionary:apple"
    assert by_mass.identity.priced_as == "apple"
    assert by_mass.macros.kcal == pytest.approx(104, abs=1)  # 200 g at 52 kcal/100 g
    assert by_mention.grams == 182.0  # one standard apple
    assert fdc.calls == 0


async def test_unknown_food_identifies_once_for_every_amount_kind():
    # A long-tail food has ONE owner (the estimator carries portion data): the same
    # per-100g whether said with grams, a count, or nothing. FDC is not consulted.
    fdc = _FakeFdc()
    resolver = Resolver(fdc=fdc, estimator=_SlicedEstimator())
    mass = await resolver.resolve_item(_item(_UNKNOWN, 200, Unit.G))
    count = await resolver.resolve_item(_item(_UNKNOWN, 2, Unit.PIECE))
    bare = await resolver.resolve_item(_item(_UNKNOWN))
    assert mass.identity == count.identity == bare.identity
    assert mass.source is ResolutionSource.ESTIMATED
    assert mass.grams == 200.0
    assert count.grams == 20.0
    assert bare.grams == 30.0
    assert fdc.calls == 0


async def test_fdc_is_the_fallback_when_the_estimator_declines_and_prices_mass_only():
    fdc = _FakeFdc()
    resolver = Resolver(fdc=fdc, estimator=_Decliner())
    mass = await resolver.resolve_item(_item(_UNKNOWN, 50, Unit.G))
    assert mass.source is ResolutionSource.FDC
    assert mass.identity.serving_grams is None  # per-100g row: no portion data
    assert mass.identity.priced_as == "Bison bacon, cooked"  # the row is named, never hidden
    assert mass.macros.kcal == pytest.approx(184.0)
    # The same identity cannot price a count or a bare mention: honest unresolved, never
    # "assume 100 g" (the 234-kcal Big Mac shape).
    count = await resolver.resolve_item(_item(_UNKNOWN, 2, Unit.PIECE))
    assert count.source is ResolutionSource.UNRESOLVED
    assert count.macros.kcal == 0.0
    assert fdc.calls == 1  # identified once; the second resolve reused the memo


async def test_primed_identity_is_repriced_not_reidentified():
    # The refine/confirm contract: a parse row's persisted identity is primed into a fresh
    # (request-scoped) resolver; an amount edit prices THAT identity and never pays the
    # estimator again. Same numbers per gram, new grams.
    est = _CountingEstimator()
    first = await Resolver(estimator=est).resolve_item(_item(_UNKNOWN))
    assert est.calls == 1
    later = Resolver(estimator=est)
    later.prime(_item(_UNKNOWN, 200, Unit.G), first.identity)
    edited = await later.resolve_item(_item(_UNKNOWN, 200, Unit.G))
    assert est.calls == 1
    assert edited.identity == first.identity
    assert edited.grams == 200.0
    assert edited.macros.kcal == pytest.approx(first.identity.per_100g.kcal * 2, abs=0.2)


async def test_primed_identity_does_not_survive_an_identity_edit():
    # Name/brand/variant/fat-ratio edits are SUPPOSED to change the food: they miss the
    # primed memo and identify fresh.
    est = _CountingEstimator()
    first = await Resolver(estimator=est).resolve_item(_item(_UNKNOWN))
    later = Resolver(estimator=est)
    later.prime(_item(_UNKNOWN), first.identity)
    renamed = await later.resolve_item(_item(_UNKNOWN + " deluxe"))
    assert est.calls == 2
    assert renamed.identity.key != first.identity.key


async def test_clarify_spread_prices_one_identity():
    # Amount/state alternatives the clarify engine prices share the identity memo entry
    # (they differ only in amount/unit/state), so a spread is never two different foods.
    est = _CountingEstimator()
    resolver = Resolver(estimator=est)
    await resolver.resolve_item(_item(_UNKNOWN))
    await resolver.resolve_item(_item(_UNKNOWN, 0.5, None))
    await resolver.resolve_item(_item(_UNKNOWN, 1.5, None))
    await resolver.resolve_item(_item(_UNKNOWN, state=State.COOKED))
    assert est.calls == 1


async def test_persisted_identity_round_trips_through_stored_rows():
    resolved = await Resolver().resolve_item(_item("cosmic crisp apple", 200, Unit.G))
    identity = persistable_identity(resolved.identity)
    assert identity is not None
    rows = [
        {"name": "cosmic crisp apple", "brand": None, "variant": None, "fat_ratio": None,
         "prep_method": None, "identity": identity.model_dump(mode="json")},
        {"name": "legacy row without identity"},
        {"name": "junk ratio", "fat_ratio": "lots", "identity": identity.model_dump(mode="json")},
    ]
    pairs = stored_identities(rows)
    assert [item.name for item, _ in pairs] == ["cosmic crisp apple", "junk ratio"]
    assert pairs[0][1] == identity
    assert pairs[1][0].fat_ratio is None  # a free-form ratio degrades, never raises
    assert persistable_identity(UNRESOLVED_IDENTITY) is None


async def test_branded_fdc_fallback_queries_brand_and_name_in_branded_mode():
    class _RecordingFdc:
        def __init__(self):
            self.calls: list[tuple[str, bool]] = []

        async def resolve(self, term, *, branded=False):
            self.calls.append((term, branded))

    fdc = _RecordingFdc()
    item = ParsedItem(name="qwerty loaf", brand="Acme", confidence=0.9)
    r = await Resolver(fdc=fdc, estimator=_Decliner()).resolve_item(item)
    assert r.source is ResolutionSource.UNRESOLVED
    assert fdc.calls == [("Acme qwerty loaf", True)]
    generic = await Resolver(fdc=fdc).resolve_item(_item(_UNKNOWN, 50, Unit.G))
    assert generic.source is ResolutionSource.UNRESOLVED
    assert fdc.calls[-1] == (_UNKNOWN, False)
