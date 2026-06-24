"""Monthly recalibration decision tree (Phase G, decision #37 / PROTOCOL_LOGIC §recalibration).

Francesco recalibrates by formula, not feeling ("same thing, different result =
insanity"). This module encodes that as a deterministic tree producing a
structured ``Recommendation``; the phrasing layer (later) writes the pitch from
these facts and may not alter the numbers (AGENTS.md #6, PROTOCOL_LOGIC §7).

The three documented branches:

1. **Lost weight → recalibrate to adjusted IBW.** New weight shifts ideal body
   weight, which shifts calories/protein/water/fiber. Often framed *optional*
   (the user is progressing; don't fix what isn't broken).
2. **No progress + compliant → knock cal/kg down one point.** Within the
   24–29 cal/kg IBW fat-loss band (decision #35). One point only — never a leap.
3. **No progress + NOT compliant → "why no progress?" diagnostics.** Surface the
   honest levers (movement, logging accuracy) rather than cutting calories on a
   user who isn't actually executing. The guiding-toward-truth move is the
   candidate secret sauce; cutting calories here would be the wrong lever.

Rails (engine-side, mirrors PROTOCOL_LOGIC §3 posture): the cal/kg allocation is
clamped to the documented fat-loss band so a recalibration can never walk a user
below a safe floor. Clamps are recorded as structured facts, never hidden.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

# Fat-loss allocation band, cal per kg of IDEAL body weight (decision #35,
# PROTOCOL_LOGIC superseding update). Recalibration moves WITHIN this band.
_CAL_PER_KG_MIN = 24.0
_CAL_PER_KG_MAX = 29.0

# A "no progress" verdict: weight change is within this band of zero (kg over the
# recalibration window). Outside it is loss (negative) or gain (positive).
_NO_PROGRESS_KG = 0.3

# Adherence (0..1 self-reported / observed) at/above which a user counts as
# "compliant" — the gate between the cut-calories branch and the diagnostics branch.
_COMPLIANT_ADHERENCE = 0.8

# One "point" down = 1 cal/kg IBW (Francesco's "knock it down one point").
_ONE_POINT = 1.0

# Water ≈ half bodyweight in ounces; fiber ≈ 14 g per 1000 kcal (PROTOCOL_LOGIC §4).
_WATER_OZ_PER_KG = 0.5 * 2.2046226218  # half of (kg→lb): oz of water per kg bodyweight
_FIBER_G_PER_1000_KCAL = 14.0


class RecommendationKind(str, Enum):
    """Which branch of the recalibration tree fired. Stable ids — stored + asserted."""

    RECALIBRATE_IBW = "recalibrate_ibw"
    REDUCE_ALLOCATION = "reduce_allocation"
    DIAGNOSTICS = "diagnostics"
    HOLD = "hold"


@dataclass(frozen=True)
class RecalInputs:
    """Inputs to one monthly recalibration. All deterministic; the caller
    assembles these from durable rows (current protocol + latest check-in)."""

    current_weight_kg: float
    starting_weight_kg: float
    ideal_body_weight_kg: float
    current_cal_per_kg: float
    adherence: float  # 0..1, observed/self-reported over the window
    logging_accuracy: float | None = None  # 0..1, e.g. days-logged / days
    avg_steps: int | None = None
    # Absolute calorie floor (sex-derived, PROTOCOL_LOGIC §3 / App Review health posture).
    # Recalibration must never cut a user below this, even when cal/kg is in-band but IBW is
    # small. Defaults to the male floor; build_recal_inputs sets it from intake sex.
    calorie_floor: int = 1600

    @property
    def weight_change_kg(self) -> float:
        """Signed: negative = lost weight, positive = gained."""
        return round(self.current_weight_kg - self.starting_weight_kg, 2)


@dataclass(frozen=True)
class RecalTargets:
    """The five dashboard targets after recalibration (PROTOCOL_LOGIC §4 scaling)."""

    cal_per_kg: float
    target_kcal: int
    protein_g: int
    water_oz: int
    fiber_g: int


@dataclass(frozen=True)
class Recommendation:
    """Structured recalibration output. ``optional`` mirrors Francesco's "pitch,
    often optional" framing; ``clamps`` records any rail that bound the request;
    ``diagnostics`` carries the honest levers for the no-progress-not-compliant case."""

    kind: RecommendationKind
    optional: bool
    headline: str
    rationale: str
    targets: RecalTargets | None = None
    diagnostics: list[str] = field(default_factory=list)
    clamps: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "kind": self.kind.value,
            "optional": self.optional,
            "headline": self.headline,
            "rationale": self.rationale,
            "targets": _targets_dict(self.targets),
            "diagnostics": list(self.diagnostics),
            "clamps": list(self.clamps),
        }


def _targets_dict(targets: RecalTargets | None) -> dict | None:
    if targets is None:
        return None
    return {
        "cal_per_kg": targets.cal_per_kg,
        "target_kcal": targets.target_kcal,
        "protein_g": targets.protein_g,
        "water_oz": targets.water_oz,
        "fiber_g": targets.fiber_g,
    }


def _clamp_cal_per_kg(value: float) -> tuple[float, str | None]:
    """Clamp the allocation to the documented fat-loss band; report if it bound."""
    if value < _CAL_PER_KG_MIN:
        return _CAL_PER_KG_MIN, (
            f"cal/kg request {value:g} clamped up to floor {_CAL_PER_KG_MIN:g} "
            "(fat-loss band, PROTOCOL_LOGIC §3)"
        )
    if value > _CAL_PER_KG_MAX:
        return _CAL_PER_KG_MAX, (
            f"cal/kg request {value:g} clamped down to ceiling {_CAL_PER_KG_MAX:g} "
            "(fat-loss band)"
        )
    return value, None


def _build_targets(
    *,
    ideal_body_weight_kg: float,
    bodyweight_kg: float,
    cal_per_kg: float,
    protein_g_per_kg: float,
    calorie_floor: int,
) -> tuple[RecalTargets, list[str]]:
    """Compute the five dashboard targets from a clamped cal/kg + IBW + bodyweight.

    Calories key off IDEAL bodyweight (decision #35); protein/water scale off
    CURRENT bodyweight; fiber scales off the resulting calorie target.
    """
    clamped, clamp_note = _clamp_cal_per_kg(cal_per_kg)
    raw_kcal = round(clamped * ideal_body_weight_kg)
    # Absolute floor: cal/kg can be in-band yet still land below the protective minimum for a
    # short user (small IBW). Never cut below it (PROTOCOL_LOGIC §3, App Review health posture).
    target_kcal = max(raw_kcal, calorie_floor)
    protein_g = round(protein_g_per_kg * bodyweight_kg)
    water_oz = round(_WATER_OZ_PER_KG * bodyweight_kg)
    fiber_g = round(_FIBER_G_PER_1000_KCAL * target_kcal / 1000.0)
    targets = RecalTargets(
        cal_per_kg=clamped,
        target_kcal=target_kcal,
        protein_g=protein_g,
        water_oz=water_oz,
        fiber_g=fiber_g,
    )
    notes = [clamp_note] if clamp_note else []
    if target_kcal > raw_kcal:
        notes.append(
            f"target {raw_kcal} kcal raised to the {calorie_floor} kcal floor (PROTOCOL_LOGIC §3)"
        )
    return targets, notes


def build_recal_inputs(
    *,
    intake_profile,
    active_kcal: int,
    current_weight_kg: float,
    adherence_self: int,
) -> RecalInputs:
    """Assemble RecalInputs from durable rows (G wiring). Pure (no DB) so it's testable.

    - starting weight = the intake bodyweight (decision 2026-06-24: intake weight is the
      baseline; it's always present once intake is persisted).
    - IBW = Devine from intake sex/height.
    - current cal/kg = active protocol kcal / IBW (recovers the allocation from the persisted
      target without storing cal/kg separately).
    - adherence: the 1..5 self-rating mapped to 0..1 (5 -> 1.0; the 0.8 compliant gate is hit
      at 4+).
    """
    # Local import avoids a module-load cycle (engine imports nothing from checkin).
    from ..protocols.engine import devine_ibw_kg, lb_to_kg  # noqa: PLC0415

    ibw_kg = devine_ibw_kg(intake_profile.sex.value, intake_profile.height_in)
    # Sex-derived absolute floor (PROTOCOL_LOGIC §3; mirrors protocols.engine 1600/1400).
    floor = 1400 if intake_profile.sex.value == "female" else 1600
    return RecalInputs(
        current_weight_kg=current_weight_kg,
        starting_weight_kg=lb_to_kg(intake_profile.weight_lb),
        ideal_body_weight_kg=ibw_kg,
        current_cal_per_kg=(active_kcal / ibw_kg) if ibw_kg else 0.0,
        adherence=max(0.0, min(1.0, adherence_self / 5.0)),
        calorie_floor=floor,
    )


def recommend(inputs: RecalInputs, *, protein_g_per_kg: float = 2.0) -> Recommendation:
    """Run the monthly recalibration tree and return one structured recommendation.

    ``protein_g_per_kg`` is passed in (the protocol engine owns the protein table,
    PROTOCOL_LOGIC §4); recalibration only re-applies it to the (possibly new)
    bodyweight basis. Defaulted so the engine is testable standalone.
    """
    change = inputs.weight_change_kg

    # Branch 1: lost weight → recalibrate to adjusted IBW (often optional).
    if change <= -_NO_PROGRESS_KG:
        targets, clamps = _build_targets(
            ideal_body_weight_kg=inputs.ideal_body_weight_kg,
            bodyweight_kg=inputs.current_weight_kg,
            cal_per_kg=inputs.current_cal_per_kg,
            protein_g_per_kg=protein_g_per_kg,
            calorie_floor=inputs.calorie_floor,
        )
        return Recommendation(
            kind=RecommendationKind.RECALIBRATE_IBW,
            optional=True,
            headline=f"Down {abs(change):g} kg — let's recalibrate to where you are now.",
            rationale=(
                "Your bodyweight moved, so calories, protein, water, and fiber shift "
                "with it. This is a tune-up, not a cut — totally optional if you'd "
                "rather hold the current numbers."
            ),
            targets=targets,
            clamps=clamps,
        )

    # Branch 2: meaningful GAIN → hold, never cut. A gain is not a stall; cutting here (with a
    # "you did the work" framing) would be both wrong and a trust violation. We hold and look at
    # the week rather than reflexively trimming calories.
    if change >= _NO_PROGRESS_KG:
        return Recommendation(
            kind=RecommendationKind.HOLD,
            optional=True,
            headline=f"Up {change:g} kg — let's hold and look at the week, not cut.",
            rationale=(
                "One month up isn't a trend, and a gain isn't a signal to slash calories. "
                "Hold the current plan, tighten consistency, and re-measure next month."
            ),
        )

    # Genuinely flat (within ±threshold of zero). Compliance decides cut vs. diagnose.
    compliant = inputs.adherence >= _COMPLIANT_ADHERENCE

    # Branch 3: flat + compliant → knock cal/kg down one point.
    if compliant:
        targets, clamps = _build_targets(
            ideal_body_weight_kg=inputs.ideal_body_weight_kg,
            bodyweight_kg=inputs.current_weight_kg,
            cal_per_kg=inputs.current_cal_per_kg - _ONE_POINT,
            protein_g_per_kg=protein_g_per_kg,
            calorie_floor=inputs.calorie_floor,
        )
        return Recommendation(
            kind=RecommendationKind.REDUCE_ALLOCATION,
            optional=False,
            headline="Scale held and you did the work — time to nudge calories down a point.",
            rationale=(
                "Same input, same result means the math needs to move. We knock the "
                "allocation down one point and re-measure next month — never a leap."
            ),
            targets=targets,
            clamps=clamps,
        )

    # Branch 4: flat + NOT compliant → honest diagnostics, NOT a cut.
    return Recommendation(
        kind=RecommendationKind.DIAGNOSTICS,
        optional=False,
        headline="Before we change anything — let's look at what actually happened.",
        rationale=(
            "Cutting calories on a month that wasn't fully executed fixes the "
            "wrong thing. Two honest questions first: how much did you really "
            "move, and how accurate was the logging?"
        ),
        diagnostics=_diagnostics(inputs),
    )


def _diagnostics(inputs: RecalInputs) -> list[str]:
    """Honest levers for the no-progress-not-compliant case (movement, logging)."""
    out: list[str] = []
    if inputs.logging_accuracy is not None and inputs.logging_accuracy < _COMPLIANT_ADHERENCE:
        pct = round(inputs.logging_accuracy * 100)
        out.append(f"Logging covered about {pct}% of days — accuracy first, numbers second.")
    else:
        out.append("How accurate was the logging — every bite, every day?")
    if inputs.avg_steps is not None:
        out.append(f"Movement averaged ~{inputs.avg_steps:,} steps/day — is that the real week?")
    else:
        out.append("How much did you actually move this month?")
    return out
