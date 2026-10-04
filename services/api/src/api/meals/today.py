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

from typing import Any, Literal

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
    "sugar": 50.0,  # g/day, a tenth of the stub's calories (the engine's ceiling rule)
    "sodium": 2300.0,  # mg/day
}

# Keys the dashboard tracks, in display order. Carbs/fat ride along (meal detail)
# but are not home-dashboard pillars (decision #28).
TARGET_KEYS: tuple[str, ...] = (
    "kcal", "protein", "carbs", "fat", "fiber", "produce", "water", "sugar", "sodium",
)

# Stored jsonb key per dashboard key where they differ: the engine persists
# ProtocolTargets.model_dump(), whose water/produce keys carry units. Reading the
# unitless dashboard names against that shape always missed, so every onboarded
# user silently got the STUB water/produce targets while is_stub reported False.
_STORED_KEY: dict[str, str] = {
    "produce": "produce_servings",
    "water": "water_oz",
    "sugar": "sugar_g_max",
    "sodium": "sodium_mg_max",
}
# The engine's sugar ceiling is a tenth of calories as grams; a protocol written before the
# ceiling existed derives it from its own kcal rather than taking the stub's.
_SUGAR_KCAL_FRACTION = 0.10


class Targets(BaseModel):
    """Daily targets for the tracked dashboard fields."""

    kcal: float = 0.0
    protein: float = 0.0
    carbs: float = 0.0
    fat: float = 0.0
    fiber: float = 0.0
    produce: float = 0.0  # servings/day
    water: float = 0.0  # oz/day
    sugar: float = 0.0  # g/day, a ceiling
    sodium: float = 0.0  # mg/day, a ceiling


class Consumed(BaseModel):
    """What the day's logs add up to (macros + produce servings + water oz).

    Sugar and sodium are the sum of the items that stated them; the ``*_unknown_items`` counts
    say how many of the day's foods did not, so a partial total is never shown as the whole."""

    kcal: float = 0.0
    protein: float = 0.0
    carbs: float = 0.0
    fat: float = 0.0
    fiber: float = 0.0
    produce: float = 0.0  # servings
    water: float = 0.0  # oz
    sugar: float = 0.0  # g, known items only
    sodium: float = 0.0  # mg, known items only
    sugar_unknown_items: int = 0
    sodium_unknown_items: int = 0


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
    sugar: float = 0.0
    sodium: float = 0.0


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
    merged = {
        key: _num(raw.get(_STORED_KEY.get(key, key)), STUB_TARGETS[key]) for key in TARGET_KEYS
    }
    if raw.get("sugar_g_max") is None and merged["kcal"] > 0:
        merged["sugar"] = float(round(merged["kcal"] * _SUGAR_KCAL_FRACTION / 4.0))
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
    kcal = protein = carbs = fat = fiber = produce = sugar = sodium = 0.0
    sugar_unknown = sodium_unknown = 0
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
            # Sugar and sodium live on the item (a food states them or it does not); the sum
            # is over the items that knew, the count over the ones that did not.
            macros = item.get("macros") or {}
            item_sugar = macros.get("sugar_g")
            item_sodium = macros.get("sodium_mg")
            if item_sugar is None:
                sugar_unknown += 1
            else:
                sugar += _num(item_sugar, 0.0)
            if item_sodium is None:
                sodium_unknown += 1
            else:
                sodium += _num(item_sodium, 0.0)
    return Consumed(
        kcal=round(kcal, 1),
        protein=round(protein, 1),
        carbs=round(carbs, 1),
        fat=round(fat, 1),
        fiber=round(fiber, 1),
        produce=round(produce, 1),
        water=round(water_oz, 1),
        sugar=round(sugar, 1),
        sodium=round(sodium, 1),
        sugar_unknown_items=sugar_unknown,
        sodium_unknown_items=sodium_unknown,
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
        sugar=round(targets.sugar - consumed.sugar, 1),
        sodium=round(targets.sodium - consumed.sodium, 1),
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


class Panel(BaseModel):
    """One card the server composed for the person's mode (decision 60; meals/dashboard.py).

    The client renders a panel by ``kind`` and skips a kind it does not know, so a new mode or
    metric never needs a client build. Every number here is the server's; the client formats
    and lays out, never calculates (AGENTS.md #6).

    ``direction``: ``land`` completes inside a window (calories 90 to 105 percent of the target,
    protein inside its band); ``reach`` completes at or above the target (water, produce,
    fiber, carbs, fat); ``stay_under`` never completes and turns ``over`` past the target
    (sugar, sodium). ``support`` is the one line under the number; the client may append what
    only the phone knows (Apple Health's burned calories).
    """

    kind: Literal["calories_left", "metric_tile", "habit_tile"]
    metric: str
    title: str
    consumed: float
    target: float
    remaining: float
    unit: str = ""
    direction: Literal["land", "reach", "stay_under"] = "reach"
    complete: bool = False
    over: bool = False
    band_low: float | None = None
    band_high: float | None = None
    support: str = ""
    # The water tile alone can be tapped (POST /meals/water); nothing else has an entry point.
    can_add: bool = False
    # Foods in the day with no value for this nutrient (sugar, sodium); shown, never counted
    # as zero.
    unknown_items: int = 0


class TodayResponse(BaseModel):
    date: str
    targets: Targets
    consumed: Consumed
    remaining: Remaining
    meals: list[TodayMeal]
    avg_confidence: float = 0.0
    # True when no active protocol exists yet → STUB_TARGETS are in play.
    targets_are_stub: bool = False
    # Protein optimal band (bounded goal: too little AND too much are suboptimal). When a
    # protocol predates the band (or it's the stub), both default to the protein target so the
    # dashboard renders a point rather than a misleading range.
    protein_min: float = 0.0
    protein_max: float = 0.0
    # The person's mode and what it prints (tracking/projection.py; decisions 57 to 61). All
    # additive: a build-31 client ignores them and renders the seven fields above. The server
    # composes ``panels``; ``prints_numbers`` is False only in habits mode and governs the rows,
    # the chips and the result as well as the cards (the Rams review, R8).
    mode: str = "five"
    prints_numbers: bool = True
    shows_week_card: bool = True
    panels: list[Panel] = Field(default_factory=list)


def protein_band_from_protocol(row: dict[str, Any] | None, protein_target: float) -> tuple[float, float]:
    """The protein optimal band from the active protocol's stored targets; falls back to the
    target (a zero-width band) when absent — old protocols or the pre-onboarding stub."""
    raw = (row or {}).get("targets") or {}
    low = _num(raw.get("protein_min"), 0.0) or protein_target
    high = _num(raw.get("protein_max"), 0.0) or protein_target
    return low, high
