"""Meal confidence weighting (RT-17).

An UNRESOLVED ingredient has zero macros because resolution FAILED, not because it's a
zero-calorie garnish. It must drag meal confidence down (the totals are incomplete), not be
dismissed with a tiny floor weight that leaves the meal looking cleanly resolved.
"""

from __future__ import annotations

from api.nutrition.resolver import Resolver
from api.parser.confidence import item_confidence, meal_confidence
from api.parser.schemas import ParsedItem, State, Unit


def _item(name: str, **over) -> ParsedItem:
    base = {
        "name": name, "amount": None, "unit": None,
        "state": State.UNSPECIFIED, "fat_ratio": None, "confidence": 0.95,
    }
    base.update(over)
    return ParsedItem(**base)


async def test_unresolved_item_drags_meal_confidence_down():
    r = Resolver()
    steak = await r.resolve_item(_item("ground beef", amount=200, unit=Unit.G, fat_ratio="80/20"))
    mystery = await r.resolve_item(_item("zzqqx mystery glop", amount=100, unit=Unit.G))
    assert mystery.match_score == 0.0  # genuinely unresolved
    assert item_confidence(steak) > 0.5
    # The unknown gap pulls the meal well below the clean item's own confidence; if it were
    # treated as a zero-calorie garnish the meal would sit ≈ the steak's confidence.
    assert meal_confidence([steak, mystery]) < 0.6 * item_confidence(steak)


async def test_resolved_zero_cal_garnish_does_not_tank_confidence():
    # A genuinely resolved item still dominates; this guards against over-correcting (the fix
    # only re-weights UNRESOLVED zero-macro items, not clean ones).
    r = Resolver()
    steak = await r.resolve_item(_item("ground beef", amount=200, unit=Unit.G, fat_ratio="80/20"))
    assert meal_confidence([steak]) == item_confidence(steak)
