"""Deterministic "why" layer — plain-English explanation per target, no LLM.

PROTOCOL_LOGIC.md §7 and decision #10: every target has a "why" slot. The eventual
enhancement is an AI that *phrases* these from the structured facts it cannot override.
This module is the deterministic FALLBACK that must ALWAYS work: it reads the engine's
``ComputationFacts`` and emits one or two plain-English sentences per target, with the
numbers interpolated VERBATIM from engine fields — it never re-derives a number.

Per §7/§8: a missing AI "why" never blocks protocol generation, so this fallback ships
the protocol with the facts rendered plainly. The strings reference the actual inputs
(activity level, deficit) so the user sees *why this number, for me*.
"""

from __future__ import annotations

from .engine import ComputationFacts
from .schemas import Goal, IntakeProfile, ProtocolTargets

_GOAL_PHRASE: dict[Goal, str] = {
    Goal.CUT: "fat loss",
    Goal.MAINTAIN: "maintenance",
    Goal.GAIN: "gaining",
}


def _kcal_why(profile: IntakeProfile, facts: ComputationFacts, kcal: int) -> str:
    goal = _GOAL_PHRASE[profile.goal]
    # "calories", grouped, and the activity level in lowercase mid-sentence: the person's words,
    # not the engine's labels and units (the 2026-10-16 audit, C9).
    base = (
        f"Your {kcal:,} calories start from {facts.calorie_goal:,} at maintenance: "
        f"{facts.activity_perkg:g} per kg of your {facts.ibw_kg:g} kg ideal weight, at "
        f"{facts.activity_level.lower()} activity"
    )
    if facts.reduce_pct > 0:
        base += f", less a {facts.reduce_pct:g}% deficit for {goal}."
    elif facts.reduce_pct < 0:
        base += f", plus a {abs(facts.reduce_pct):g}% surplus for {goal}."
    else:
        base += ", held there: your goal is to maintain."
    # The floor is a safety rail the UI may not hide (PROTOCOL_LOGIC.md §3.1).
    if facts.floored:
        base += (
            f" It is held at the {facts.calorie_floor:,} calorie floor. We never set calories "
            f"below that, regardless of the math."
        )
    return base


def _protein_why(profile: IntakeProfile, facts: ComputationFacts, protein: int) -> str:
    cut = profile.goal == Goal.CUT
    if facts.protein_capped:
        return (
            f"Protein is {protein} g, capped to fit your calorie budget. Your ideal weight points "
            f"higher (about {facts.protein_ideal_gkg:g} g per kg), but that plus fat would run past "
            f"your calories, so we trimmed protein to fit"
        ) + (" while you cut." if cut else " as you train.")
    why = (
        f"Protein is {protein} g: {facts.protein_ideal_gkg:g} g per kg of your ideal weight "
        f"({facts.ibw_kg:g} kg), with {facts.protein_min_g} g the minimum to protect muscle"
    )
    return why + (" while you cut." if cut else " as you train.")


def _fat_why(facts: ComputationFacts, fat: int) -> str:
    base = f"Fat is {fat} g, about {round(facts.fat_pct * 100)}% of your calories"
    return base + ("." if facts.protein_capped else "; the rest of your calories go to carbs.")


def _carbs_why(facts: ComputationFacts, targets: ProtocolTargets) -> str:
    if facts.protein_capped:
        return (
            f"Carbs are {targets.carbs} g. At your {targets.kcal:,} calories, protein and fat "
            f"already use the full target, so there's no room left for carbs. They are off Today "
            f"unless you add them."
        )
    return (
        f"Carbs come out to {targets.carbs} g: whatever calories are left after protein and fat. "
        f"They are off Today unless you add them."
    )


def _fiber_why(facts: ComputationFacts, fiber: int) -> str:
    return (
        f"Fiber is {fiber} g ideal ({facts.fiber_min} g minimum): {facts.fiber_ideal:g} g for "
        f"every 1000 calories of maintenance, the amount tied to better digestion and fullness."
    )


def _water_why(profile: IntakeProfile, water_oz: int) -> str:
    return (
        f"Water is {water_oz} oz, about half your bodyweight "
        f"({profile.weight_lb:g} lb) in ounces."
    )


def _produce_why(produce_servings: int) -> str:
    return (
        f"Aim for {produce_servings} servings of fruits and vegetables a day, the simplest "
        f"lever for fiber, micronutrients, and fullness."
    )


def _meals_why(meals_per_day: int) -> str:
    return (
        f"{meals_per_day} meals a day spreads the protein out; a guide, not a rule. Log when "
        f"you eat."
    )


def build_whys(
    profile: IntakeProfile, facts: ComputationFacts, targets: ProtocolTargets
) -> dict[str, str]:
    """Deterministic "why" string per target, keyed to match the iOS ``whys`` dict."""
    return {
        "kcal": _kcal_why(profile, facts, targets.kcal),
        "protein": _protein_why(profile, facts, targets.protein),
        "carbs": _carbs_why(facts, targets),
        "fat": _fat_why(facts, targets.fat),
        "fiber": _fiber_why(facts, targets.fiber),
        "water": _water_why(profile, targets.water_oz),
        "produce": _produce_why(targets.produce_servings),
        "meals": _meals_why(targets.meals_per_day),
        "sugar": _sugar_why(targets),
        "sodium": _sodium_why(targets),
    }


def _sugar_why(targets: ProtocolTargets) -> str:
    if targets.sugar_g_max is None:
        return ""
    return (
        f"Keep added sugar under {targets.sugar_g_max} g a day: a tenth of your calories, the "
        f"common public-health line rather than the method's number. Shown only if you add it."
    )


def _sodium_why(targets: ProtocolTargets) -> str:
    if targets.sodium_mg_max is None:
        return ""
    return (
        f"Keep sodium under {targets.sodium_mg_max:,} mg a day, the common public-health line. "
        f"Shown only if you add it, and only for foods that state it."
    )
