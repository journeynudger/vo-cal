"""Pydantic schemas for the protocols domain — Phase F (intake & protocol).

The intake is the differentiator (pillar ②, decision #35/#36): a deeper, more human
profile than height/weight/age. Activity is *inferred, never asked* (decision #36) —
the engine derives it from occupation + training + obligations, because self-reported
activity is systematically over-rated. So ``IntakeProfile`` carries occupation, training
load, kids, meds, and stress, and the engine (engine.py) turns them into placement
within the cal/kg band.

``ProtocolTargets`` serializes to two shapes from one model:
  - the iOS ``VoCalCore.ProtocolTargets`` JSON (camelCase: ``mealsPerDay``, ``whys``);
  - the ``protocols`` table's ``targets`` jsonb (decision #19, immutable rows).
The home-dashboard five (decision #28) — calories, protein, produce, fiber, water —
plus carbs/fat (computed, off the dashboard, stored for opt-in micro-tracking).
"""

from __future__ import annotations

from enum import Enum

from pydantic import BaseModel, Field


class Sex(str, Enum):
    """Biological sex — drives Devine IBW base and the calorie floor."""

    MALE = "male"
    FEMALE = "female"


class Goal(str, Enum):
    """Goal direction. In practice almost always CUT (PRODUCT_BRIEF), but the band
    table covers all three so maintain/gain drop in without new code."""

    CUT = "cut"
    MAINTAIN = "maintain"
    GAIN = "gain"


class Occupation(str, Enum):
    """Daily-burn proxy. Asked because the standard activity multiplier conflates
    occupation with training (PROTOCOL_LOGIC.md §2)."""

    DESK = "desk"
    ON_FEET = "on_feet"
    MANUAL = "manual"


class TrainingLoad(str, Enum):
    """Structured training load. Inferred-activity inputs, not a self-rating slider
    (decision #36) — paired with occupation so a desk-job lifter is read correctly."""

    NONE = "none"
    LIGHT = "light"
    MODERATE = "moderate"
    HEAVY = "heavy"


class MedEffect(str, Enum):
    """Medication effect on hunger/metabolism — a placement input (decision #35)."""

    NONE = "none"
    HUNGER_INCREASING = "hunger_increasing"
    HUNGER_SUPPRESSING = "hunger_suppressing"


class StressLevel(str, Enum):
    """Life stress — high stress earns a lighter deficit (decision #35)."""

    LOW = "low"
    MODERATE = "moderate"
    HIGH = "high"


class IntakeProfile(BaseModel):
    """The deep human intake the protocol engine consumes.

    No ``activity_level`` field by design (decision #36): the engine infers activity
    from occupation + training + obligations. ``kids`` stands in for caregiving load
    (the "single parent" placement factor); ``meds_per_day``/window inputs are out of
    scope for the starting model.
    """

    age: int = Field(ge=13, le=100)
    sex: Sex
    height_in: float = Field(gt=0, le=96, description="Height in inches")
    weight_lb: float = Field(gt=0, le=1000, description="Current bodyweight in pounds")
    goal: Goal = Goal.CUT
    work: Occupation = Occupation.DESK
    train: TrainingLoad = TrainingLoad.NONE
    kids: bool = False
    med: MedEffect = MedEffect.NONE
    stress: StressLevel = StressLevel.MODERATE
    meals_per_day: int | None = Field(
        default=None, ge=1, le=12, description="Preferred meals/day; engine clamps to a sane range"
    )


class ProtocolTargets(BaseModel):
    """Computed targets — the engine's output and the stored/served shape.

    ``model_dump()`` produces the snake_case JSON the iOS ``VoCalCore.ProtocolTargets``
    decodes via convertFromSnakeCase (meals_per_day/produce_servings/water_oz + whys). The same
    dict is what the store writes to ``protocols.targets`` (and ``protocols.whys``,
    which mirrors ``whys`` for the dedicated jsonb column).

    Every number is an int — protocol targets are whole units a human reads off a
    dashboard. carbs/fat are stored even though they are off the home dashboard
    (decision #28): they power opt-in micro-tracking and the meal-detail screen.
    """

    version: int = Field(ge=1)
    kcal: int = Field(ge=0)
    protein: int = Field(ge=0)
    # Protein optimal band (bounded, not a floor): the green range on the dashboard, centered
    # on ``protein``. Defaulted for back-compat with protocols stored before the band existed.
    protein_min: int = Field(default=0, ge=0)
    protein_max: int = Field(default=0, ge=0)
    carbs: int = Field(ge=0)
    fat: int = Field(ge=0)
    fiber: int = Field(ge=0)
    # Home-dashboard five also include produce + water (decision #28); off the iOS
    # ProtocolTargets struct today but stored so the dashboard reads one source.
    water_oz: int = Field(ge=0)
    produce_servings: int = Field(ge=0)
    meals_per_day: int = Field(ge=1)
    whys: dict[str, str] = Field(default_factory=dict)


class GenerateProtocolRequest(BaseModel):
    """POST /protocols/generate body: the intake answers to compute from."""

    intake: IntakeProfile


class GenerateProtocolResponse(BaseModel):
    """Generated (or active) protocol: the durable row id + version + targets/whys.

    ``protocol_id`` is the ``protocols`` table PK. ``targets`` carries ``whys`` inline
    as well, mirroring how the iOS ``ProtocolTargets`` nests them.
    """

    protocol_id: str
    version: int
    active: bool
    targets: ProtocolTargets
