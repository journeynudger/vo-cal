"""Deterministic "why" layer — plain-English explanation per target, no LLM.

PROTOCOL_LOGIC.md §7 and decision #10: every target has a "why" slot. The eventual
enhancement is an AI that *phrases* these from the structured facts it cannot override.
This module is the deterministic FALLBACK that must ALWAYS work: it reads the engine's
``ComputationFacts`` and emits one or two plain-English sentences per target, with the
numbers interpolated VERBATIM from engine fields — it never re-derives a number.

Per §7/§8: a missing AI "why" never blocks protocol generation, so this fallback ships
the protocol with the facts rendered plainly. The strings reference the actual intake
inputs (stress, training, kids, meds) so the user sees *why this number, for me*.
"""

from __future__ import annotations

from .engine import ComputationFacts, PlacementFact
from .schemas import Goal, IntakeProfile, ProtocolTargets

# Human-readable labels for the placement contributions, so the "why" names the
# life facts that moved the deficit rather than internal enum values.
_PLACEMENT_LABELS: dict[str, str] = {
    "stress": "your stress level",
    "training": "your training load",
    "occupation": "your day-to-day activity at work",
    "medication": "your medication",
    "kids": "caring for kids",
    "age": "your age",
}

_GOAL_PHRASE: dict[Goal, str] = {
    Goal.CUT: "fat loss",
    Goal.MAINTAIN: "maintenance",
    Goal.GAIN: "gaining",
}


def _placement_reasons(placement: PlacementFact) -> list[str]:
    """The intake factors that actually shifted placement, most influential first."""
    nonzero = [
        (name, shift)
        for name, shift in placement.contributions.items()
        if shift != 0.0 and name in _PLACEMENT_LABELS
    ]
    nonzero.sort(key=lambda pair: abs(pair[1]), reverse=True)
    return [_PLACEMENT_LABELS[name] for name, _ in nonzero]


def _kcal_why(profile: IntakeProfile, facts: ComputationFacts, kcal: int) -> str:
    placement = facts.placement
    goal = _GOAL_PHRASE[profile.goal]
    base = (
        f"Your {kcal} kcal target is {placement.cal_per_kg:g} calories per kg of your "
        f"ideal body weight ({facts.ibw_kg:g} kg) for {goal}"
    )
    reasons = _placement_reasons(placement)
    if reasons:
        band = f"{placement.band_low:g}-{placement.band_high:g}"
        base += f", set within the {band} band by {_join(reasons)}"
    base += "."
    # A clamp or a floor is a safety rail the UI may not hide (PROTOCOL_LOGIC.md §3).
    if facts.floored:
        base += (
            f" It is held at the {facts.calorie_floor} kcal floor — we never set calories "
            f"below that, regardless of the math."
        )
    elif placement.clamped:
        edge = "gentler" if placement.raw_cal_per_kg > placement.band_high else "more aggressive"
        base += (
            f" Your inputs pointed even {edge}, but we kept it inside the "
            f"{placement.band_low:g}-{placement.band_high:g} band for safety."
        )
    return base


def _protein_why(profile: IntakeProfile, facts: ComputationFacts, protein: int) -> str:
    why = (
        f"Protein is {protein} g — about {facts.protein_gkg:g} g per kg of your bodyweight "
        f"({facts.bodyweight_kg:g} kg), which protects muscle"
    )
    why += " while you cut." if profile.goal == Goal.CUT else " as you train."
    return why


def _fat_why(facts: ComputationFacts, fat: int) -> str:
    return (
        f"Fat is set to {fat} g, the floor of {facts.fat_floor_gkg:g} g per kg of bodyweight "
        f"that keeps hormones healthy; the rest of your calories go to carbs."
    )


def _carbs_why(carbs: int) -> str:
    return (
        f"Carbs come out to {carbs} g — whatever calories are left after protein and fat. "
        f"They are off your home dashboard by default, but here if you want them."
    )


def _fiber_why(facts: ComputationFacts, fiber: int) -> str:
    return (
        f"Fiber is {fiber} g — {facts.fiber_g_per_1000_kcal:g} g for every 1000 calories you "
        f"eat, the amount tied to better digestion and fullness."
    )


def _water_why(profile: IntakeProfile, water_oz: int) -> str:
    return (
        f"Water is {water_oz} oz — about half your bodyweight "
        f"({profile.weight_lb:g} lb) in ounces."
    )


def _produce_why(produce_servings: int) -> str:
    return (
        f"Aim for {produce_servings} servings of fruits and vegetables a day — the simplest "
        f"lever for fiber, micronutrients, and fullness."
    )


def _meals_why(meals_per_day: int) -> str:
    return (
        f"We scaffold {meals_per_day} meals a day so protein spreads out, but this is a guide, "
        f"not a rule — log when you actually eat."
    )


def build_whys(
    profile: IntakeProfile, facts: ComputationFacts, targets: ProtocolTargets
) -> dict[str, str]:
    """Deterministic "why" string per target, keyed to match the iOS ``whys`` dict.

    Keys mirror the dashboard target names so the iOS layer can look up
    ``whys["kcal"]`` etc. Numbers are interpolated from ``targets``/``facts`` verbatim.
    """
    return {
        "kcal": _kcal_why(profile, facts, targets.kcal),
        "protein": _protein_why(profile, facts, targets.protein),
        "carbs": _carbs_why(targets.carbs),
        "fat": _fat_why(facts, targets.fat),
        "fiber": _fiber_why(facts, targets.fiber),
        "water": _water_why(profile, targets.water_oz),
        "produce": _produce_why(targets.produce_servings),
        "meals": _meals_why(targets.meals_per_day),
    }


def _join(items: list[str]) -> str:
    """Oxford-comma join: ['a'] -> 'a'; ['a','b'] -> 'a and b'; ['a','b','c'] -> 'a, b, and c'."""
    if len(items) == 1:
        return items[0]
    if len(items) == 2:
        return f"{items[0]} and {items[1]}"
    return ", ".join(items[:-1]) + f", and {items[-1]}"
