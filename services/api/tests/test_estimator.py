"""Branded/unknown food resolution — the accuracy failure class (field reports 2026-07).

The reported failures, each pinned here:
  - "Chobani 30g protein zero added sugar vanilla yogurt drink" (220 kcal / 30 g protein)
    priced as generic whole-milk "yogurt" (3 g protein) — brand-blind resolution.
  - Same drink voiced 4 ways -> 4 different answers — no durable estimate cache.
  - "2 light baby bell cheeses" (50 kcal / 5 g each) -> wrong macros — the estimator
    dropped the brand and ran unvalidated.
  - Espresso / labeled products -> needless pop-ups and size nags.

The contract now: branded items resolve AI-first (informed label read, validated,
cached, deterministic portions); brand-less foods keep the deterministic path; no
clarify questions or "unclear food" nags on labeled products; useful questions
("2 slices of cheese") still fire on vague brandless foods.
"""

from __future__ import annotations

import pytest

from api.db import FakeDatabase
from api.nutrition.estimator import (
    CachedEstimator,
    EstimatedFood,
    estimate_cache_key,
    validate_estimate,
)
from api.nutrition.resolver import Resolver
from api.nutrition.schemas import NutrientProfile
from api.parser.schemas import ParsedItem, Unit

# The two reported products, as the AI would describe their identity (label-true).
CHOBANI_DRINK = EstimatedFood(
    # 220 kcal / 30 g protein per 296 ml bottle -> per-100g label math.
    per_100g=NutrientProfile(kcal=74.3, protein=10.1, carbs=6.1, fat=1.0, fiber=1.0),
    serving_grams=296.0,
    unit_conversions={"ml": 1.0},
    kcal_per_serving=220.0,
)
BABYBEL_LIGHT = EstimatedFood(
    # 50 kcal / 5 g protein per 21 g piece.
    per_100g=NutrientProfile(kcal=238.0, protein=23.8, carbs=0.0, fat=14.3, fiber=0.0),
    serving_grams=21.0,
    unit_conversions={"piece": 21.0},
    kcal_per_serving=50.0,
)


class FakeEstimator:
    """Deterministic estimator double; counts calls (cache assertions)."""

    def __init__(self, foods: dict[str, EstimatedFood]) -> None:
        self.foods = foods
        self.calls = 0

    async def estimate(self, item: ParsedItem) -> EstimatedFood | None:
        self.calls += 1
        for needle, food in self.foods.items():
            if needle in f"{item.brand or ''} {item.name}".lower():
                return food
        return None


def _chobani(name: str = "30g protein zero added sugar vanilla yogurt drink") -> ParsedItem:
    return ParsedItem(name=name, brand="Chobani", confidence=0.95)


def _fake() -> FakeEstimator:
    return FakeEstimator({"chobani": CHOBANI_DRINK, "babybel": BABYBEL_LIGHT})


# -- the Chobani failure: brand-first, label-accurate ------------------------------


async def test_branded_drink_prices_from_label_not_generic():
    r = await Resolver(estimator=_fake()).resolve_item(_chobani())
    assert r.is_estimate
    assert r.grams == 296.0  # one bottle (the AI's serving), not a generic yogurt cup
    assert r.macros.kcal == pytest.approx(220, abs=5)
    assert r.macros.protein == pytest.approx(30, abs=1)  # NOT 3 g


async def test_brand_beats_generic_alias_match():
    # Even when the LLM over-normalizes the name to a bare dictionary alias ("yogurt"),
    # the brand routes resolution to the informed estimate — never whole-milk yogurt.
    r = await Resolver(estimator=_fake()).resolve_item(_chobani(name="yogurt"))
    assert r.is_estimate
    assert r.macros.protein == pytest.approx(30, abs=1)


async def test_branded_estimate_scores_as_informed_read():
    r = await Resolver(estimator=_fake()).resolve_item(_chobani())
    assert r.match_score >= 0.75  # label read, not a blind guess (blind stays 0.35)


async def test_no_estimator_falls_through_to_deterministic_path():
    # Offline / no key: branded items resolve exactly as before (dictionary alias).
    r = await Resolver().resolve_item(ParsedItem(name="ham", brand="Krakus", confidence=0.9))
    assert r.source.value == "dictionary"
    assert r.macros.kcal > 0


# -- the Babybel failure: brand context + unit math --------------------------------


async def test_babybel_two_pieces_price_correctly():
    item = ParsedItem(name="light cheese", brand="Babybel", amount=2, unit=Unit.PIECE, confidence=0.9)
    r = await Resolver(estimator=_fake()).resolve_item(item)
    assert r.grams == 42.0  # 2 × 21 g piece — deterministic local unit math
    assert r.macros.kcal == pytest.approx(100, abs=3)  # 2 × 50
    assert r.macros.protein == pytest.approx(10, abs=1)  # 2 × 5


# -- determinism: same food -> same numbers, one paid call ever --------------------


async def test_cache_makes_repeat_logs_identical_and_single_paid_call():
    db, inner = FakeDatabase(), _fake()
    cached = CachedEstimator(db, inner)
    # Fresh Resolver per parse (per-request memo does NOT carry across mornings).
    first = await Resolver(estimator=cached).resolve_item(_chobani())
    second = await Resolver(estimator=cached).resolve_item(_chobani())
    assert inner.calls == 1  # second morning came from the durable cache
    assert first.macros == second.macros


async def test_cache_key_is_identity_normalized():
    a = estimate_cache_key(_chobani())
    b = estimate_cache_key(_chobani())
    assert a == b
    assert a.startswith("est:")
    assert "chobani" in a


async def test_corrupt_cache_row_is_miss_not_crash():
    db = FakeDatabase()
    db.tables.setdefault("usda_cache", []).append(
        {"query_key": estimate_cache_key(_chobani()), "profile": {"garbage": True}}
    )
    r = await Resolver(estimator=CachedEstimator(db, _fake())).resolve_item(_chobani())
    assert r.macros.protein == pytest.approx(30, abs=1)  # recovered via live estimate


# -- plausibility fences: implausible answers are declined, never logged ------------


def _reply(kcal=74.3, protein=10.1, carbs=6.1, fat=1.0, serving=296.0, kcal_per_serving=220.0):
    return {
        "per_100g": {"kcal": kcal, "protein": protein, "carbs": carbs, "fat": fat, "fiber": 1.0},
        "serving_grams": serving,
        "kcal_per_serving": kcal_per_serving,
    }


def test_validate_accepts_label_true_reply():
    assert validate_estimate(_reply()) is not None


@pytest.mark.parametrize(
    "bad",
    [
        _reply(kcal=700),  # Atwater: 700 kcal vs 4/4/9≈74 — hallucinated magnitude
        _reply(serving=0.2),  # absurd serving
        _reply(serving=5000),
        _reply(kcal=1200),  # denser than pure fat
        _reply(protein=-5),  # negative macro
        {"serving_grams": 100},  # malformed: no profile
    ],
)
def test_validate_rejects_implausible(bad):
    assert validate_estimate(bad) is None


# -- selectivity: no pop-ups on labeled products; useful questions kept -------------


async def test_no_clarify_questions_for_branded_label_read():
    from api.parser.clarify import ClarifyEngine
    from api.parser.schemas import Importance, MissingDetail

    candidate = MissingDetail(
        field="items[0].amount", importance=Importance.HIGH, question="How much?"
    )
    engine = ClarifyEngine(Resolver(estimator=_fake()))
    decision = await engine.decide([_chobani()], [candidate])
    assert decision.questions == []  # the label IS the answer


async def test_vague_brandless_cheese_still_asks():
    # The useful pop-up the user wants KEPT: bare "cheddar" has a material variant axis.
    from api.parser.clarify import ClarifyEngine

    decision = await ClarifyEngine(Resolver(estimator=_fake())).decide(
        [ParsedItem(name="cheddar", confidence=0.9)], []
    )
    assert any(q.field.endswith(".variant") for q in decision.questions)


async def test_certainty_does_not_nag_branded_estimate():
    from api.parser.certainty import build_certainty, item_from_resolved
    from api.parser.confidence import meal_confidence

    resolved = await Resolver(estimator=_fake()).resolve_item(_chobani())
    conf = meal_confidence([resolved])
    c = build_certainty(
        [item_from_resolved(resolved)],
        conf,
        "chobani 30 grams of protein zero added sugar vanilla yogurt drink",
    )
    assert "unclear_food" not in c.missing_details
    assert c.score >= 60  # an informed label read is not "rough estimate" territory


async def test_espresso_is_self_defining_no_size_or_milk_nag():
    from api.parser.certainty import build_certainty, item_from_resolved
    from api.parser.confidence import meal_confidence

    resolved = await Resolver().resolve_item(ParsedItem(name="espresso", confidence=0.95))
    assert resolved.source.value == "dictionary"  # coffee alias — ~2 kcal, deterministic
    c = build_certainty(
        [item_from_resolved(resolved)], meal_confidence([resolved]), "i had an espresso"
    )
    assert "drink_size" not in c.missing_details
    assert "milk_or_creamer" not in c.missing_details
    assert not any("size" in t for t in c.tips)


# -- web-grounded estimation: sources, fallback chain, cache round-trip -------------


def _sourced(food: EstimatedFood, *urls: str) -> EstimatedFood:
    from api.nutrition.estimator import FoodSource

    return EstimatedFood(
        per_100g=food.per_100g,
        serving_grams=food.serving_grams,
        unit_conversions=food.unit_conversions,
        sources=tuple(FoodSource(url=u, title="t") for u in urls),
        kcal_per_serving=food.kcal_per_serving,
    )


class _SourcedEstimator:
    async def estimate(self, item):
        return _sourced(CHOBANI_DRINK, "https://www.chobani.com/x", "https://usda.gov/y")


async def test_sources_flow_to_parse_result_item():
    from api.parser.router import _result_item

    r = await Resolver(estimator=_SourcedEstimator()).resolve_item(_chobani())
    assert r.match_score == 0.85  # web-grounded outranks knowledge-only
    out = _result_item(r)
    assert out.sources is not None
    assert [s.url for s in out.sources] == ["https://www.chobani.com/x", "https://usda.gov/y"]


async def test_sources_survive_the_durable_cache():
    db = FakeDatabase()
    cached = CachedEstimator(db, _SourcedEstimator())
    first = await cached.estimate(_chobani())
    second = await cached.estimate(_chobani())  # from cache
    assert [s.url for s in second.sources] == [s.url for s in first.sources]
    assert len(second.sources) == 2


async def test_grounded_failure_falls_back_to_knowledge():
    from api.nutrition.estimator import WebGroundedEstimator

    class _Boom:
        async def messages_create(self, **kw):
            raise RuntimeError("no web for you")

    web = WebGroundedEstimator("key", fallback=_fake())
    web._client = type("C", (), {"messages": type("M", (), {"create": _Boom().messages_create})()})()
    est = await web.estimate(_chobani())
    assert est is not None  # knowledge fallback answered
    assert est.sources == ()  # honestly unsourced
    assert est.per_100g.protein == pytest.approx(10.1)


def test_extract_sources_dedupes_and_caps():
    from api.nutrition.estimator import _extract_sources

    class _R:
        def __init__(self, url, title="t"):
            self.url, self.title = url, title

    class _Block:
        type = "web_search_tool_result"

        def __init__(self, results):
            self.content = results

    class _ErrBlock:
        type = "web_search_tool_result"
        content = object()  # error object, not a list

    blocks = [
        _ErrBlock(),
        _Block([_R("https://a.com"), _R("https://a.com"), _R("https://b.com")]),
        _Block([_R("https://c.com"), _R("https://d.com"), _R("https://e.com")]),
    ]
    out = _extract_sources(blocks)
    assert [s.url for s in out] == ["https://a.com", "https://b.com", "https://c.com", "https://d.com"]


# -- FDC plausibility gate: garbage USDA rows must not price meals ------------------


class _BadFdc:
    """The 'idaho potato' field bug verbatim: 7 kcal/100g WITH 17.5 g carbs."""

    async def resolve(self, term):
        from api.nutrition.fdc_client import FdcResult

        return FdcResult(
            fdc_id=1,
            description="idaho potato",
            profile=NutrientProfile(kcal=7.0, protein=2.05, carbs=17.55, fat=0.0, fiber=1.0),
        )


class _GoodFdc:
    async def resolve(self, term):
        from api.nutrition.fdc_client import FdcResult

        return FdcResult(
            fdc_id=2,
            description="baked potato",
            profile=NutrientProfile(kcal=93.0, protein=2.5, carbs=21.4, fat=0.1, fiber=2.2),
        )


async def test_implausible_fdc_row_falls_through_to_estimator():
    potato = EstimatedFood(
        per_100g=NutrientProfile(kcal=93.0, protein=2.5, carbs=21.4, fat=0.1, fiber=2.2),
        serving_grams=173.0,
    )
    r = await Resolver(
        fdc=_BadFdc(), estimator=FakeEstimator({"idaho potato": potato})
    ).resolve_item(ParsedItem(name="idaho potato", amount=200, unit=Unit.G, confidence=0.9))
    assert r.is_estimate  # the 7-kcal FDC row was rejected
    assert r.macros.kcal == pytest.approx(186, abs=3)  # 200 g at real potato density


async def test_plausible_fdc_row_still_used():
    r = await Resolver(fdc=_GoodFdc(), estimator=_fake()).resolve_item(
        ParsedItem(name="idaho potato", amount=200, unit=Unit.G, confidence=0.9)
    )
    assert r.source.value == "fdc"
    assert r.macros.kcal == pytest.approx(186, abs=3)


# -- count-unit portion safety: "3 pieces of turkey bacon" must not balloon ---------


def _turkey_bacon_bad() -> EstimatedFood:
    # The failure shape: a valid density but serving_grams=100 (a "serving", ~7 slices)
    # and NO per-piece conversion — the exact input that made 3 pieces resolve to 1104.
    return EstimatedFood(
        per_100g=NutrientProfile(kcal=226.0, protein=22.0, carbs=2.0, fat=14.0, fiber=0.0),
        serving_grams=100.0,
        unit_conversions={},
    )


def _turkey_bacon_good() -> EstimatedFood:
    return EstimatedFood(
        per_100g=NutrientProfile(kcal=226.0, protein=22.0, carbs=2.0, fat=14.0, fiber=0.0),
        serving_grams=42.0,
        unit_conversions={"piece": 14.0, "slice": 14.0},
    )


async def test_count_unit_without_piece_weight_does_not_balloon():
    est = FakeEstimator({"bison bacon": _turkey_bacon_bad()})
    r = await Resolver(estimator=est).resolve_item(
        ParsedItem(name="bison bacon", amount=3, unit=Unit.PIECE, confidence=0.9)
    )
    # NOT 3 × 100 g = 300 g (~678 kcal). Capped at one serving (100 g) and flagged inferred.
    assert r.grams == 100.0
    assert r.macros.kcal < 300  # sane for a bacon portion, not a 3× blowup
    assert r.amount_specificity.value == "inferred_serving"


async def test_count_unit_with_piece_weight_prices_accurately():
    est = FakeEstimator({"bison bacon": _turkey_bacon_good()})
    r = await Resolver(estimator=est).resolve_item(
        ParsedItem(name="bison bacon", amount=3, unit=Unit.PIECE, confidence=0.9)
    )
    assert r.grams == 42.0  # 3 × 14 g — the accurate path when the estimator gives per-piece
    assert r.macros.kcal < 150


def test_validate_drops_implausible_per_piece_weight():
    # A "piece" heavier than 300 g is the model confusing a serving for a piece — dropped,
    # so the count-unit safety net engages instead of pricing 3 × 900 g.
    data = {
        "per_100g": {"kcal": 226.0, "protein": 22.0, "carbs": 2.0, "fat": 14.0, "fiber": 0.0},
        "serving_grams": 100.0,
        "kcal_per_serving": 226.0,
        "unit_conversions": {"piece": 900.0, "slice": 12.0},
    }
    est = validate_estimate(data)
    assert est is not None
    assert "piece" not in est.unit_conversions  # 900 g/piece dropped
    assert est.unit_conversions["slice"] == 12.0  # sane one kept


# -- serving-basis integrity: the 234-kcal Big Mac class (field bug 2026-07-19) -----
# "a Big Mac" logged at 234 kcal — its per-100g row shipped as the whole sandwich.
# The estimator lane of that class: a reply that pairs per-serving calories with a
# per-100g weight (or echoes the 100 g basis as the serving) must never be cached.


def _big_mac_reply(serving=215.0, kcal_per_serving=580.0):
    # Label-true Big Mac: ~270 kcal/100g, ~215 g sandwich, ~580 kcal per sandwich.
    return {
        "per_100g": {"kcal": 270.0, "protein": 11.6, "carbs": 20.9, "fat": 15.8, "fiber": 1.6},
        "serving_grams": serving,
        "kcal_per_serving": kcal_per_serving,
    }


def test_validate_accepts_label_true_big_mac():
    est = validate_estimate(_big_mac_reply())
    assert est is not None
    assert est.serving_grams == 215.0
    assert est.kcal_per_serving == 580.0


@pytest.mark.parametrize(
    "bad",
    [
        # Mixed basis: the label's per-sandwich calories with the per-100g weight —
        # would price the sandwich at 270 kcal instead of 580.
        _big_mac_reply(serving=100.0, kcal_per_serving=580.0),
        # Inverted mix: whole-sandwich weight with per-100g calories.
        _big_mac_reply(serving=215.0, kcal_per_serving=270.0),
        # Nonsense per-serving calories.
        _big_mac_reply(kcal_per_serving=0.0),
        _big_mac_reply(kcal_per_serving=-5.0),
        # Legacy shape without the redundancy is no longer a valid reply.
        {k: v for k, v in _big_mac_reply().items() if k != "kcal_per_serving"},
    ],
)
def test_validate_rejects_mixed_serving_basis(bad):
    assert validate_estimate(bad) is None


async def test_grounded_serving_of_exactly_100g_declines_to_knowledge():
    # A grounded reply built solely from an aggregator's per-100g table is
    # self-consistent (kcal_per_serving == per-100g kcal), so only the exact-100.0
    # tell catches it. It must fall through to the knowledge estimator, not cache.
    import json as _json

    from api.nutrition.estimator import WebGroundedEstimator

    echo = {
        "per_100g": {"kcal": 234.0, "protein": 12.8, "carbs": 21.0, "fat": 11.6, "fiber": 1.5},
        "serving_grams": 100.0,
        "kcal_per_serving": 234.0,
        "unit_conversions": {},
    }

    class _TextBlock:
        type = "text"

        def __init__(self, text):
            self.text = text

    class _Resp:
        def __init__(self):
            self.content = [_TextBlock(_json.dumps(echo))]

    async def _fake_create(**kw):
        return _Resp()

    knowledge = FakeEstimator({"big mac": _big_mac_food()})
    web = WebGroundedEstimator("key", fallback=knowledge)
    web._client = type("C", (), {"messages": type("M", (), {"create": staticmethod(_fake_create)})()})()
    est = await web.estimate(ParsedItem(name="big mac", confidence=0.95))
    assert est is not None
    assert est.serving_grams == 215.0  # the knowledge identity, not the 100 g echo
    assert knowledge.calls == 1


def _big_mac_food() -> EstimatedFood:
    return EstimatedFood(
        per_100g=NutrientProfile(kcal=270.0, protein=11.6, carbs=20.9, fat=15.8, fiber=1.6),
        serving_grams=215.0,
        unit_conversions={},
        kcal_per_serving=580.0,
    )


async def test_bare_big_mac_resolves_to_whole_sandwich_not_per_100g():
    # THE regression: "I had a Big Mac" (no amount, no brand from the parser) must
    # price as one whole sandwich, never as 100 g of big mac.
    r = await Resolver(estimator=FakeEstimator({"big mac": _big_mac_food()})).resolve_item(
        ParsedItem(name="big mac", confidence=0.95)
    )
    assert r.is_estimate
    assert r.grams == 215.0
    assert r.macros.kcal == pytest.approx(580, abs=5)  # NOT 234


# -- cache versioning: stale rows re-estimate instead of serving forever ------------


async def test_stale_version_cache_row_is_re_estimated():
    from api.nutrition.estimator import ESTIMATOR_VERSION

    db = FakeDatabase()
    key = estimate_cache_key(_chobani())
    # A row from an OLD estimator version with (deliberately) wrong numbers.
    db.tables.setdefault("usda_cache", []).append(
        {
            "query_key": key,
            "fdc_id": None,
            "profile": {
                "estimator_version": ESTIMATOR_VERSION - 1,
                "per_100g": {"kcal": 74.3, "protein": 3.0, "carbs": 6.1, "fat": 1.0, "fiber": 1.0},
                "serving_grams": 296.0,
                "unit_conversions": {},
            },
        }
    )
    cached = CachedEstimator(db, _fake())
    est = await cached.estimate(_chobani())
    assert est.per_100g.protein == pytest.approx(10.1)  # fresh estimate, NOT the stale 3.0
    # The stale row was upserted in place (still exactly one row for the key).
    assert sum(1 for r in db.tables["usda_cache"] if r["query_key"] == key) == 1


async def test_current_version_cache_row_is_served():
    db = FakeDatabase()
    inner = _fake()
    cached = CachedEstimator(db, inner)
    await cached.estimate(_chobani())  # writes a current-version row
    assert inner.calls == 1
    await cached.estimate(_chobani())  # served from cache — no second call
    assert inner.calls == 1
