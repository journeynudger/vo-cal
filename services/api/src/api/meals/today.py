"""Today aggregation (Phase E0): targets vs. consumed vs. remaining.

Deterministic, pure helpers (AGENTS.md #6 — code calculates, the LLM never
touches these numbers). The router wires the day window, reads the active
protocol's targets through the Database seam, sums the day's meal_logs + water,
and totals produce servings from the dictionary; everything numeric is here so
it is unit-testable in isolation.

Dashboard pillars (decision #28): calories · protein · produce · fiber · water.
Carbs and fat are still computed and returned (meal detail uses them) but are
not the home-dashboard headline.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field

from ..nutrition.dictionary import FoodDictionary, get_dictionary

# Pre-onboarding fallback target (decision #35 documented starting model).
# Until a real protocol exists, Today must still render — so it falls back to a
# documented stub so the dashboard is usable from the very first log, before the
# Phase F intake/protocol engine has written a protocols row. These are NOT a
# recommendation: they are neutral placeholders, flagged via ``is_stub`` so the
# UI can show "set up your protocol" rather than imply a real plan.
STUB_TARGETS: dict[str, float] = {
    "kcal": 2000.0,
    "protein": 120.0,
    "carbs": 200.0,
    "fat": 60.0,
    "fiber": 28.0,  # 14 g per 1000 kcal (PROTOCOL_LOGIC §4) at the stub kcal
    "produce": 5.0,  # servings/day
    "water": 100.0,  # oz/day (≈ half a 200-lb bodyweight)
}

# Keys the dashboard tracks, in display order. Carbs/fat ride along (meal detail)
# but are not home-dashboard pillars (decision #28).
TARGET_KEYS: tuple[str, ...] = ("kcal", "protein", "carbs", "fat", "fiber", "produce", "water")


class Targets(BaseModel):
    """Daily targets for the tracked dashboard fields."""

    kcal: float = 0.0
    protein: float = 0.0
    carbs: float = 0.0
    fat: float = 0.0
    fiber: float = 0.0
    produce: float = 0.0  # servings/day
    water: float = 0.0  # oz/day


class Consumed(BaseModel):
    """What the day's logs add up to (macros + produce servings + water oz)."""

    kcal: float = 0.0
    protein: float = 0.0
    carbs: float = 0.0
    fat: float = 0.0
    fiber: float = 0.0
    produce: float = 0.0  # servings
    water: float = 0.0  # oz


class Remaining(BaseModel):
    """Target − consumed per field. May go negative (over target) — never clamped;
    the dashboard decides how to render an overage (decision #28: no nagging)."""

    kcal: float = 0.0
    protein: float = 0.0
    carbs: float = 0.0
    fat: float = 0.0
    fiber: float = 0.0
    produce: float = 0.0
    water: float = 0.0


def targets_from_protocol(row: dict[str, Any] | None) -> tuple[Targets, bool]:
    """Build ``Targets`` from an active-protocol row, or the documented stub.

    ``row`` is the raw protocols row (its ``targets`` jsonb is free-form: the
    Phase F engine owns its shape). We read the seven dashboard keys leniently —
    missing keys fall back to the stub value for that key, so a partial protocol
    never zeroes a pillar. Returns ``(targets, is_stub)``; ``is_stub`` is True
    only when there is no active protocol at all (pre-onboarding).
    """
    if row is None:
        return Targets(**STUB_TARGETS), True
    raw = row.get("targets") or {}
    merged = {key: _num(raw.get(key), STUB_TARGETS[key]) for key in TARGET_KEYS}
    return Targets(**merged), False


def consumed_from_day(
    meals: list[dict[str, Any]],
    water_oz: float,
    dictionary: FoodDictionary | None = None,
) -> Consumed:
    """Sum a day's confirmed meals into consumed macros + produce servings.

    Each meal row carries ``totals`` (server-recomputed macros) and ``items``
    (the confirmed items, each with a resolved ``name`` + ``grams``). Macros sum
    from ``totals``; produce sums by matching every item's name in the dictionary
    and crediting its produce_servings scaled by grams (today.dictionary path).
    """
    dictionary = dictionary or get_dictionary()
    kcal = protein = carbs = fat = fiber = produce = 0.0
    for meal in meals:
        totals = meal.get("totals") or {}
        kcal += _num(totals.get("kcal"), 0.0)
        protein += _num(totals.get("protein"), 0.0)
        carbs += _num(totals.get("carbs"), 0.0)
        fat += _num(totals.get("fat"), 0.0)
        fiber += _num(totals.get("fiber"), 0.0)
        for item in meal.get("items") or []:
            name = item.get("name")
            grams = _num(item.get("grams"), 0.0)
            if name and grams > 0:
                produce += dictionary.produce_servings_for(name, grams)
    return Consumed(
        kcal=round(kcal, 1),
        protein=round(protein, 1),
        carbs=round(carbs, 1),
        fat=round(fat, 1),
        fiber=round(fiber, 1),
        produce=round(produce, 1),
        water=round(water_oz, 1),
    )


def remaining_of(targets: Targets, consumed: Consumed) -> Remaining:
    """Field-wise target − consumed (rounded to 1 dp; may be negative)."""
    return Remaining(
        kcal=round(targets.kcal - consumed.kcal, 1),
        protein=round(targets.protein - consumed.protein, 1),
        carbs=round(targets.carbs - consumed.carbs, 1),
        fat=round(targets.fat - consumed.fat, 1),
        fiber=round(targets.fiber - consumed.fiber, 1),
        produce=round(targets.produce - consumed.produce, 1),
        water=round(targets.water - consumed.water, 1),
    )


def _num(value: Any, default: float) -> float:
    """Coerce a possibly-missing/None numeric (jsonb) to float, else the default."""
    if value is None:
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


class TodayMeal(BaseModel):
    """One logged meal as the Today screen lists it (compact, not the full log)."""

    id: str
    name: str | None = None
    meal_type: str
    logged_at: str
    totals: dict[str, float] = Field(default_factory=dict)


class TodayResponse(BaseModel):
    date: str
    targets: Targets
    consumed: Consumed
    remaining: Remaining
    meals: list[TodayMeal]
    avg_confidence: float = 0.0
    # True when no active protocol exists yet → STUB_TARGETS are in play.
    targets_are_stub: bool = False
