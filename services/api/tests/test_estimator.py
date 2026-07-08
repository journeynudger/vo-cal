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
)
BABYBEL_LIGHT = EstimatedFood(
    # 50 kcal / 5 g protein per 21 g piece.
    per_100g=NutrientProfile(kcal=238.0, protein=23.8, carbs=0.0, fat=14.3, fiber=0.0),
    serving_grams=21.0,
    unit_conversions={"piece": 21.0},
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


def _reply(kcal=74.3, protein=10.1, carbs=6.1, fat=1.0, serving=296.0):
    return {
        "per_100g": {"kcal": kcal, "protein": protein, "carbs": carbs, "fat": fat, "fiber": 1.0},
        "serving_grams": serving,
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
