"""Deterministic protocol engine — PRO Training Solutions Nutrition IP v2.0.

Implements the proprietary nutrient-goal formula (PRO Training Solutions LLC /
Francesco Provinzano; CONFIDENTIAL trade secret — see docs/PROTOCOL_LOGIC.md).
``IntakeProfile -> ProtocolTargets``, pure, no I/O.

Pipeline (IP §2-3):
  1. Hamwi ideal bodyweight, adjusted 40% toward actual weight.
  2. Maintenance calories = ibw_kg × activity factor (Low 25 / Mod 27.6 / High 30 / Very High 32).
  3. Calorie target = maintenance × (1 - deficit%), rounded to 5, then never below the floor.
  4. Protein: 2.0 g/kg IBW (ideal) and 1.6 g/kg IBW (min) — the optimal band.
  5. Fat = 27% of the calorie target ÷ 9; carbs = the remainder (never negative).
  6. Fiber 11/14 g per 1000 kcal of MAINTENANCE; fruit/veg = maintenance ÷ 400; water = 0.5 oz/lb.

The IP takes ActivityLevel and a coach-selected deficit% as inputs. Vo-Cal has no coach
and infers activity (decision #36), so ``_activity_level`` maps occupation+training to the
IP's four levels and ``_reduce_pct`` picks the deficit from the goal, gentled by the life
factors (stress / appetite meds / kids / age) the intake already collects.

AGENTS.md non-negotiable #6 / decision #10: this is the deterministic half — the LLM only
phrases the "why" (see ``why.py``); it never invents, rounds, or overrides a number here.

FORMULA-PLUGGABLE (decision #35): every coefficient lives in ``ProtocolTunables`` below.
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
    """Pounds -> kilograms (exact, not rounded — rounding happens at the targets).

    Kept (with ``devine_ibw_kg``) because the recalibration path (checkin/recommend.py)
    imports them; the IP generate-path below uses Hamwi IBW instead.
    """
    return weight_lb / _LB_PER_KG


def devine_ibw_kg(sex: str, height_in: float) -> float:
    """Devine ideal body weight in kg. RETAINED for the recalibration path only.

    The generate path uses Hamwi IBW (``hamwi_ibw_lb``) per the v2.0 IP; this Devine
    estimate stays so checkin/recommend.py keeps working unchanged (its weekly-titration
    tree is out of scope for the v2.0 swap and is aligned to IP §3.3 separately).
    """
    base = 50.0 if sex == "male" else 45.5
    return base + 2.3 * max(0.0, height_in - 60.0)


def hamwi_ibw_lb(sex: str, height_in: float, weight_lb: float) -> float:
    """Ideal bodyweight in lb (IP §2.1): Hamwi base, adjusted 40% toward actual weight.

    Male base 106 lb + 6 lb/in over 60″; Female 100 lb + 5 lb/in over 60″. Heights at/under
    60″ use the base. Unrounded; the caller rounds to a whole pound before downstream use.
    """
    base = (106.0 + 6.0 * max(height_in - 60.0, 0.0)) if sex == "male" else (
        100.0 + 5.0 * max(height_in - 60.0, 0.0)
    )
    return base + (weight_lb - base) * 0.4


# -----------------------------------------------------------------------------
# Tunables — the entire IP as DATA. Swap this object to swap the model (decision #35).
# -----------------------------------------------------------------------------


@dataclass(frozen=True)
class ProtocolTunables:
    """Every coefficient/threshold the engine consumes — the PRO IP v2.0 as data.

    Defaults below are the documented v2.0 values (docs/PROTOCOL_LOGIC.md). Replace this
    object (``DEFAULT_TUNABLES`` or a per-call argument) and the engine produces a
    different protocol with no code change.
    """

    # Activity factor — kcal per kg of ideal bodyweight (IP §2.2).
    activity_perkg: dict[str, float] = field(
        default_factory=lambda: {"Low": 25.0, "Moderate": 27.6, "High": 30.0, "Very High": 32.0}
    )

    # Deficit % by goal. The IP is fat-loss (coach picks 0-25%); we auto-pick a base per goal.
    # GAIN is an app extension beyond the IP: a small surplus (negative deficit).
    base_reduce_pct: dict[Goal, float] = field(
        default_factory=lambda: {Goal.CUT: 20.0, Goal.MAINTAIN: 0.0, Goal.GAIN: -10.0}
    )
    # Life-factor nudges to the CUT deficit (positive = bigger deficit, negative = gentler).
    # High stress / appetite-raising meds / kids / older age -> gentler, more livable cut.
    stress_reduce_shift: dict[StressLevel, float] = field(
        default_factory=lambda: {StressLevel.LOW: 2.5, StressLevel.MODERATE: 0.0, StressLevel.HIGH: -5.0}
    )
    med_reduce_shift: dict[MedEffect, float] = field(
        default_factory=lambda: {
            MedEffect.NONE: 0.0,
            MedEffect.HUNGER_INCREASING: -5.0,
            MedEffect.HUNGER_SUPPRESSING: 5.0,
        }
    )
    kids_reduce_shift: float = -5.0
    older_age_threshold: int = 50
    older_age_reduce_shift: float = -5.0
    cut_reduce_floor: float = 10.0  # a cut always keeps at least this deficit
    reduce_pct_max: float = 25.0  # IP clamp

    # Activity inference (decision #36) — occupation + training points -> the IP's 4 levels.
    occupation_points: dict[Occupation, int] = field(
        default_factory=lambda: {Occupation.DESK: 0, Occupation.ON_FEET: 1, Occupation.MANUAL: 2}
    )
    training_points: dict[TrainingLoad, int] = field(
        default_factory=lambda: {
            TrainingLoad.NONE: 0,
            TrainingLoad.LIGHT: 1,
            TrainingLoad.MODERATE: 2,
            TrainingLoad.HEAVY: 3,
        }
    )

    # Calorie floors (IP §3.1; App Review health posture).
    calorie_floor_male: int = 1500
    calorie_floor_female: int = 1200

    # Protein g/kg of IDEAL bodyweight (IP §2.4): ideal (target) and min (band floor).
    protein_ideal_gkg: float = 2.0
    protein_min_gkg: float = 1.6

    # Fat as a fraction of the calorie target (IP §3.2).
    fat_pct: float = 0.27

    # Fiber g per 1000 kcal of MAINTENANCE calories (IP §2.6).
    fiber_min_per_1000: float = 11.0
    fiber_ideal_per_1000: float = 14.0

    # Fruit/veg: one serving per this many maintenance kcal (IP §2.5).
    fruit_veg_kcal_per_serving: float = 400.0
    # Water: ounces per pound of CURRENT bodyweight (IP §2.7).
    water_oz_per_lb: float = 0.5

    # Meal structure default when the user states no preference.
    default_meals_per_day: int = 3
    min_meals_per_day: int = 2
    max_meals_per_day: int = 6


# The active model. Swap THIS to drop in a revised IP (decision #35).
DEFAULT_TUNABLES = ProtocolTunables()


# -----------------------------------------------------------------------------
# Engine — pure functions. Each computation emits a structured "fact" so the protocol
# is fully explainable (PROTOCOL_LOGIC.md §7) and the deterministic why.py layer can
# phrase it without ever re-deriving a number.
# -----------------------------------------------------------------------------


@dataclass(frozen=True)
class ComputationFacts:
    """Structured trace of the whole computation — inputs the why.py layer reads VERBATIM."""

    ibw_lb: float
    ibw_kg: float
    activity_level: str
    activity_perkg: float
    calorie_goal: int  # maintenance, before deficit
    reduce_pct: float
    target_pre_floor: int
    calorie_floor: int
    floored: bool
    # True when protein had to be trimmed so protein + fat fit the calorie target (IP §3.2
    # guardrail) — surfaced by why.py so carbs=0 isn't misread as "whatever's left".
    protein_capped: bool
    protein_ideal_gkg: float
    protein_min_gkg: float
    fat_pct: float
    fiber_min: int
    fiber_ideal: int


@dataclass(frozen=True)
class ProtocolComputation:
    """Engine output: the serializable targets plus the structured facts."""

    targets: ProtocolTargets
    facts: ComputationFacts


def _activity_level(profile: IntakeProfile, tunables: ProtocolTunables) -> str:
    """Infer the IP's ActivityLevel from occupation + training (decision #36)."""
    points = tunables.occupation_points[profile.work] + tunables.training_points[profile.train]
    if points <= 1:
        return "Low"
    if points == 2:
        return "Moderate"
    if points <= 4:
        return "High"
    return "Very High"


def _reduce_pct(profile: IntakeProfile, tunables: ProtocolTunables) -> float:
    """Pick the deficit % (the IP's coach-selected input) from goal, gentled by life factors.

    Only a CUT is modulated; MAINTAIN is 0% and GAIN a fixed small surplus. The cut deficit
    is nudged gentler by high stress / appetite meds / kids / older age, stepped to 5% (the
    IP works in 5% increments) and clamped to [cut floor, 25%].
    """
    base = tunables.base_reduce_pct[profile.goal]
    if profile.goal is not Goal.CUT:
        return base
    shift = (
        tunables.stress_reduce_shift[profile.stress]
        + tunables.med_reduce_shift[profile.med]
        + (tunables.kids_reduce_shift if profile.kids else 0.0)
        + (tunables.older_age_reduce_shift if profile.age >= tunables.older_age_threshold else 0.0)
    )
    stepped = round((base + shift) / 5.0) * 5.0
    return max(tunables.cut_reduce_floor, min(tunables.reduce_pct_max, stepped))


def compute_targets(
    sex: str,
    height_in: float,
    weight_lb: float,
    activity_level: str,
    reduce_pct: float,
    *,
    version: int = 1,
    meals_per_day: int = 3,
    tunables: ProtocolTunables = DEFAULT_TUNABLES,
) -> ProtocolComputation:
    """Pure PRO IP v2.0 formula: explicit ActivityLevel + deficit% -> targets (+ facts).

    Kept separate from ``compute_protocol`` so it can be tested directly against the IP's
    worked example (Male/70″/200/Moderate/20% → 1805 kcal etc.) without the activity/deficit
    inference in between.
    """
    # Step 1-2: Hamwi IBW (whole lb) -> maintenance calories (nearest 5).
    ibw_lb = round(hamwi_ibw_lb(sex, height_in, weight_lb))
    ibw_kg = lb_to_kg(ibw_lb)
    perkg = tunables.activity_perkg[activity_level]
    calorie_goal = round(ibw_kg * perkg / 5.0) * 5

    # Step 3 + 6: deficit, then the safety floor (IP §3.1).
    target_pre_floor = round(calorie_goal * (1.0 - reduce_pct / 100.0) / 5.0) * 5
    floor = tunables.calorie_floor_male if sex == "male" else tunables.calorie_floor_female
    floored = target_pre_floor < floor
    kcal = max(target_pre_floor, floor)

    # Step 4: protein band off IDEAL bodyweight.
    protein_ideal = round(ibw_kg * tunables.protein_ideal_gkg)
    protein_min = round(ibw_kg * tunables.protein_min_gkg)

    # Step 7: fat = % of calories; carbs = remainder. Guardrail (IP §3.2): if protein+fat
    # overrun the budget (small floored targets), cap protein so carbs never go negative.
    fat = round(kcal * tunables.fat_pct / _KCAL_PER_G_FAT)
    protein_budget_max = max(0, (kcal - fat * _KCAL_PER_G_FAT) // _KCAL_PER_G_PROTEIN)
    protein = min(protein_ideal, protein_budget_max)
    protein_capped = protein < protein_ideal
    if protein_capped:
        protein_min = protein  # band collapses to the value the budget allows
        protein_max = protein
    else:
        protein_max = protein_ideal  # ideal is the top of the optimal band; target sits there
    carbs = max(0, round((kcal - protein * _KCAL_PER_G_PROTEIN - fat * _KCAL_PER_G_FAT) / _KCAL_PER_G_CARB))

    # Step 5: fiber/fruit-veg off MAINTENANCE calories; water off CURRENT weight.
    fiber_min = round(calorie_goal / 1000.0 * tunables.fiber_min_per_1000)
    fiber_ideal = round(calorie_goal / 1000.0 * tunables.fiber_ideal_per_1000)
    fruit_veg = round(calorie_goal / tunables.fruit_veg_kcal_per_serving)
    water_oz = round(weight_lb * tunables.water_oz_per_lb)
    meals = max(tunables.min_meals_per_day, min(tunables.max_meals_per_day, meals_per_day))

    targets = ProtocolTargets(
        version=version,
        kcal=kcal,
        protein=protein,
        protein_min=protein_min,
        protein_max=protein_max,
        carbs=carbs,
        fat=fat,
        fiber=fiber_ideal,  # dashboard shows the ideal target; the min lives in facts/why
        water_oz=water_oz,
        produce_servings=fruit_veg,
        meals_per_day=meals,
        whys={},  # filled by the why layer in the router before serialization
    )
    facts = ComputationFacts(
        ibw_lb=float(ibw_lb),
        ibw_kg=round(ibw_kg, 2),
        activity_level=activity_level,
        activity_perkg=perkg,
        calorie_goal=calorie_goal,
        reduce_pct=reduce_pct,
        target_pre_floor=target_pre_floor,
        calorie_floor=floor,
        floored=floored,
        protein_capped=protein_capped,
        protein_ideal_gkg=tunables.protein_ideal_gkg,
        protein_min_gkg=tunables.protein_min_gkg,
        fat_pct=tunables.fat_pct,
        fiber_min=fiber_min,
        fiber_ideal=fiber_ideal,
    )
    return ProtocolComputation(targets=targets, facts=facts)


def compute_protocol(
    profile: IntakeProfile,
    *,
    version: int = 1,
    tunables: ProtocolTunables = DEFAULT_TUNABLES,
) -> ProtocolComputation:
    """Pure computation: IntakeProfile -> ProtocolTargets (+ facts).

    Infers the IP's two coach inputs (ActivityLevel from occupation+training, deficit% from
    goal + life factors), then applies the v2.0 formula. No I/O, no randomness — the same
    profile always yields the same numbers.
    """
    activity = _activity_level(profile, tunables)
    reduce_pct = _reduce_pct(profile, tunables)
    meals = profile.meals_per_day or tunables.default_meals_per_day
    return compute_targets(
        profile.sex.value,
        profile.height_in,
        profile.weight_lb,
        activity,
        reduce_pct,
        version=version,
        meals_per_day=meals,
        tunables=tunables,
    )
