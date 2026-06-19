"""Deterministic protocol engine — IntakeProfile -> ProtocolTargets, pure, no I/O.

Implements the SUPERSEDING model from ``docs/PROTOCOL_LOGIC.md`` (decision #35):
**target calories = cal/kg of IDEAL body weight**, NOT Mifflin-St Jeor TDEE. The
fat-loss band is 24-29 cal/kg IBW; *where* in the band a user lands is set by the
deep human intake (stress, training load, kids, meds, occupation, age) — never by
the user. Protein scales with bodyweight (~1.8 g/kg), water is half bodyweight in
oz, fiber is 14 g per 1000 kcal, produce is a fixed servings/day target. Carbs and
fat are computed (fat floor, carbs as the remainder) even though they are off the
home dashboard (decision #28) — they are stored and used for opt-in micro-tracking.

AGENTS.md non-negotiable #6 / decision #10: this is the deterministic half. The LLM
phrases the "why" from structured facts this engine emits (see ``why.py``); it never
invents, rounds, or overrides a number computed here.

FORMULA-PLUGGABLE (decision #35): every threshold/coefficient lives in the
``ProtocolTunables`` dataclass below — NOT hardcoded in the functions. The 24-29
band and the scaling rules are the documented *starting* model; when Francesco's
real Notion decision-tree (NDA) arrives, it drops in by replacing ``DEFAULT_TUNABLES``
(or passing a different ``tunables`` argument) with zero changes to the logic here.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .schemas import (
    Goal,
    IntakeProfile,
    MedEffect,
    Occupation,
    ProtocolTargets,
    StressLevel,
    TrainingLoad,
)

# Conversions kept as named constants so the formula reads in domain units.
_LB_PER_KG = 2.2046226218
_KCAL_PER_G_PROTEIN = 4
_KCAL_PER_G_CARB = 4
_KCAL_PER_G_FAT = 9


def lb_to_kg(weight_lb: float) -> float:
    """Pounds -> kilograms (exact, not rounded — rounding happens at the targets)."""
    return weight_lb / _LB_PER_KG


# -----------------------------------------------------------------------------
# Tunables — the entire decision tree as DATA. Swap this object to swap the model.
# -----------------------------------------------------------------------------


@dataclass(frozen=True)
class CalPerKgBand:
    """A cal/kg-of-IBW band for one goal, with placement clamps.

    ``low`` is the most aggressive end (least calories), ``high`` the gentlest.
    The engine starts at the band midpoint and shifts within [low, high] by the
    intake factors; the request is *clamped* to the band and the clamp recorded.
    """

    low: float
    high: float

    @property
    def midpoint(self) -> float:
        return (self.low + self.high) / 2.0


@dataclass(frozen=True)
class ProtocolTunables:
    """Every coefficient/threshold the engine consumes — Francesco's tree as data.

    Replace this object (``DEFAULT_TUNABLES`` or a per-call argument) and the engine
    produces a different protocol without a code change. The defaults below are the
    documented starting model from PROTOCOL_LOGIC.md (the 24-29 fat-loss band etc.).

    Sign convention for the placement shifts: POSITIVE shifts move *up* the band
    (gentler — more calories, smaller deficit); NEGATIVE shifts move *down* (more
    aggressive). A high-stress single parent -> gentler (positive); low appetite /
    hunger-suppressing meds -> more aggressive (negative). Matches decision #35.
    """

    # cal/kg-of-IBW band per goal. Fat loss 24-29 is the documented starting band.
    bands: dict[Goal, CalPerKgBand] = field(
        default_factory=lambda: {
            Goal.CUT: CalPerKgBand(low=24.0, high=29.0),
            Goal.MAINTAIN: CalPerKgBand(low=29.0, high=34.0),
            Goal.GAIN: CalPerKgBand(low=34.0, high=39.0),
        }
    )

    # Placement shifts within the band, keyed by intake answer. These ARE the
    # "understanding the person" coefficients from decision #35.
    stress_shift: dict[StressLevel, float] = field(
        default_factory=lambda: {
            StressLevel.LOW: -1.0,
            StressLevel.MODERATE: 0.0,
            StressLevel.HIGH: 2.0,  # high stress -> lighter deficit (gentler)
        }
    )
    med_shift: dict[MedEffect, float] = field(
        default_factory=lambda: {
            MedEffect.NONE: 0.0,
            MedEffect.HUNGER_INCREASING: 1.5,  # raises hunger -> gentler
            MedEffect.HUNGER_SUPPRESSING: -1.5,  # suppresses hunger -> more aggressive
        }
    )
    training_shift: dict[TrainingLoad, float] = field(
        default_factory=lambda: {
            TrainingLoad.NONE: -0.5,
            TrainingLoad.LIGHT: 0.0,
            TrainingLoad.MODERATE: 0.5,
            TrainingLoad.HEAVY: 1.0,  # heavy training needs fuel -> gentler
        }
    )
    occupation_shift: dict[Occupation, float] = field(
        default_factory=lambda: {
            Occupation.DESK: 0.0,
            Occupation.ON_FEET: 0.5,
            Occupation.MANUAL: 1.0,  # higher daily burn -> gentler deficit appropriate
        }
    )
    kids_shift: float = 1.0  # caregiving load -> lighter deficit (decision #35: single parent)
    older_age_threshold: int = 50
    older_age_shift: float = 1.0  # age slows recovery -> gentler

    # Absolute calorie floors (PROTOCOL_LOGIC.md §3 rail; App Review health posture).
    calorie_floor_male: int = 1600
    calorie_floor_female: int = 1400

    # Protein g/kg of bodyweight, keyed on goal (PROTOCOL_LOGIC.md §4 starting model;
    # the trained/novice split + BMI-adjusted basis land when the real tree arrives).
    protein_gkg: dict[Goal, float] = field(
        default_factory=lambda: {
            Goal.CUT: 2.0,  # high end — muscle retention in a deficit
            Goal.MAINTAIN: 1.6,
            Goal.GAIN: 1.6,
        }
    )

    # Fat floor g/kg of bodyweight (hormonal-health minimum). Lower on a cut.
    fat_floor_gkg_cut: float = 0.6
    fat_floor_gkg_other: float = 0.8

    # Fiber: grams per 1000 kcal of target intake.
    fiber_g_per_1000_kcal: float = 14.0

    # Water: ounces per pound of bodyweight (half bodyweight in oz).
    water_oz_per_lb: float = 0.5

    # Produce: servings/day target (fixed in the starting model).
    produce_servings: int = 5

    # Meal structure default when the user states no preference.
    default_meals_per_day: int = 3
    min_meals_per_day: int = 2
    max_meals_per_day: int = 6


# The active model. Swap THIS to drop in Francesco's real Notion tree (decision #35).
DEFAULT_TUNABLES = ProtocolTunables()


# -----------------------------------------------------------------------------
# Engine — pure functions. Each stage emits a structured "fact" so the protocol
# is fully explainable (PROTOCOL_LOGIC.md §7) and the deterministic why.py layer
# can phrase it without ever re-deriving a number.
# -----------------------------------------------------------------------------


@dataclass(frozen=True)
class PlacementFact:
    """How the cal/kg figure was placed within (and clamped to) the band."""

    goal: Goal
    band_low: float
    band_high: float
    midpoint: float
    raw_cal_per_kg: float  # midpoint + all shifts, BEFORE clamping
    cal_per_kg: float  # the value actually used (clamped into [low, high])
    clamped: bool
    contributions: dict[str, float]  # per-factor shift, for the "why"


@dataclass(frozen=True)
class ComputationFacts:
    """Structured trace of the whole computation — inputs the why.py layer reads.

    These facts are the audit/explainability artifact (PROTOCOL_LOGIC.md §7). The
    why layer interpolates numbers from here VERBATIM; it never recomputes.
    """

    ibw_kg: float
    bodyweight_kg: float
    placement: PlacementFact
    target_kcal_pre_floor: float
    calorie_floor: int
    floored: bool
    protein_gkg: float
    fat_floor_gkg: float
    fiber_g_per_1000_kcal: float
    water_oz_per_lb: float


@dataclass(frozen=True)
class ProtocolComputation:
    """Engine output: the serializable targets plus the structured facts."""

    targets: ProtocolTargets
    facts: ComputationFacts


def devine_ibw_kg(sex: str, height_in: float) -> float:
    """Ideal body weight in kg (Devine formula).

    Male:   50.0 kg + 2.3 kg for every inch over 60.
    Female: 45.5 kg + 2.3 kg for every inch over 60.

    Heights at/under 60 in use the base; we never go negative. Body composition
    refines IBW later (decision #35) — Devine is the documented starting estimate.
    """
    base = 50.0 if sex == "male" else 45.5
    over_60 = max(0.0, height_in - 60.0)
    return base + 2.3 * over_60


def _place_in_band(profile: IntakeProfile, tunables: ProtocolTunables) -> PlacementFact:
    """Place cal/kg within the goal band by the human intake, then clamp.

    Start at the midpoint; add each factor's shift (positive = gentler). The
    contributions dict feeds the "why" so a user can see exactly which life facts
    moved their deficit. Clamping to [low, high] is a hard rail recorded as a fact.
    """
    band = tunables.bands[profile.goal]
    contributions: dict[str, float] = {
        "stress": tunables.stress_shift[profile.stress],
        "training": tunables.training_shift[profile.train],
        "occupation": tunables.occupation_shift[profile.work],
        "medication": tunables.med_shift[profile.med],
        "kids": tunables.kids_shift if profile.kids else 0.0,
        "age": tunables.older_age_shift if profile.age >= tunables.older_age_threshold else 0.0,
    }
    raw = band.midpoint + sum(contributions.values())
    clamped_value = max(band.low, min(band.high, raw))
    return PlacementFact(
        goal=profile.goal,
        band_low=band.low,
        band_high=band.high,
        midpoint=band.midpoint,
        raw_cal_per_kg=round(raw, 4),
        cal_per_kg=round(clamped_value, 4),
        clamped=raw != clamped_value,
        contributions={k: round(v, 4) for k, v in contributions.items()},
    )


def _calorie_floor(sex: str, tunables: ProtocolTunables) -> int:
    return tunables.calorie_floor_male if sex == "male" else tunables.calorie_floor_female


def compute_protocol(
    profile: IntakeProfile,
    *,
    version: int = 1,
    tunables: ProtocolTunables = DEFAULT_TUNABLES,
) -> ProtocolComputation:
    """Pure computation: IntakeProfile -> ProtocolTargets (+ structured facts).

    No I/O, no randomness — the same profile always yields the same numbers. The
    router persists the result; the why.py layer phrases ``facts``. Rounding policy
    lives here so every surface (iOS, dashboard, audit) sees identical integers.
    """
    ibw = devine_ibw_kg(profile.sex.value, profile.height_in)
    bw_kg = lb_to_kg(profile.weight_lb)

    placement = _place_in_band(profile, tunables)

    # Stage 1: calories = cal/kg of IDEAL body weight (the SUPERSEDING model).
    pre_floor = ibw * placement.cal_per_kg
    floor = _calorie_floor(profile.sex.value, tunables)
    floored = pre_floor < floor
    kcal = round(max(pre_floor, float(floor)))

    # Stage 2: protein scales with BODYweight (not IBW); rounded to a whole gram.
    protein_gkg = tunables.protein_gkg[profile.goal]
    protein = round(protein_gkg * bw_kg)

    # Stage 3: fat at its floor (g/kg bodyweight). Carbs take the remainder, so fat
    # stays at the floor in the starting model (it may rise above the floor only by
    # taking from carbs in a later tree — never from protein; PROTOCOL_LOGIC.md §4).
    fat_floor_gkg = (
        tunables.fat_floor_gkg_cut if profile.goal == Goal.CUT else tunables.fat_floor_gkg_other
    )
    fat = round(fat_floor_gkg * bw_kg)

    # Stage 4: carbs = remainder after protein + fat. Computed from the ROUNDED
    # protein/fat/kcal so the stored macros reconcile to the displayed integers.
    # Clamp at 0: a non-negative remainder is the starting-model guarantee (the
    # real tree re-applies the rate rail instead — PROTOCOL_LOGIC.md §4).
    carbs_kcal = kcal - protein * _KCAL_PER_G_PROTEIN - fat * _KCAL_PER_G_FAT
    carbs = max(0, round(carbs_kcal / _KCAL_PER_G_CARB))

    # Stage 5: fiber ∝ calories (14 g / 1000 kcal); produce + water from bodyweight.
    fiber = round(tunables.fiber_g_per_1000_kcal * kcal / 1000.0)
    water_oz = round(tunables.water_oz_per_lb * profile.weight_lb)
    produce = tunables.produce_servings

    meals_per_day = _meals_per_day(profile, tunables)

    targets = ProtocolTargets(
        version=version,
        kcal=kcal,
        protein=protein,
        carbs=carbs,
        fat=fat,
        fiber=fiber,
        water_oz=water_oz,
        produce_servings=produce,
        meals_per_day=meals_per_day,
        whys={},  # filled by the why layer in the router before serialization
    )
    facts = ComputationFacts(
        ibw_kg=round(ibw, 2),
        bodyweight_kg=round(bw_kg, 2),
        placement=placement,
        target_kcal_pre_floor=round(pre_floor, 2),
        calorie_floor=floor,
        floored=floored,
        protein_gkg=protein_gkg,
        fat_floor_gkg=fat_floor_gkg,
        fiber_g_per_1000_kcal=tunables.fiber_g_per_1000_kcal,
        water_oz_per_lb=tunables.water_oz_per_lb,
    )
    return ProtocolComputation(targets=targets, facts=facts)


def _meals_per_day(profile: IntakeProfile, tunables: ProtocolTunables) -> int:
    """Resolve meals/day from the stated preference, clamped to a sane range.

    Meal structure is a scaffold, never a rule (PROTOCOL_LOGIC.md §5); we only
    ensure the stored count is sensible so the dashboard can divide targets.
    """
    requested = profile.meals_per_day or tunables.default_meals_per_day
    return max(tunables.min_meals_per_day, min(tunables.max_meals_per_day, requested))
