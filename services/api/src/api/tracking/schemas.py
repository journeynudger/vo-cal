"""How the person wants to follow their nutrition (decisions 57 and 58).

One typed value, chosen by the person and versioned, drives three projections: which intake
questions are asked, what the reveal and Today print, and which nudges may speak. The mode
names are the person's own sentences from the sales calls, never a brand or a coach's rung
(the Rams review, docs/design/personalized-tracker-spec.md R1 and R5).
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Literal

from pydantic import BaseModel, Field


class TrackingMode(str, Enum):
    """The five ways. ``FIVE`` is the method's five (calories, protein, produce, fiber,
    water), today's dashboard, and the default for every account that never chose."""

    HABITS = "habits"
    CALORIES = "calories"
    FIVE = "five"
    MACROS = "macros"
    MEAL_PLAN = "meal_plan"


class FocusMetric(str, Enum):
    """A tile the person adds beyond the mode's own (decision 30, realized). Sugar and sodium
    exist only where the nutrient model carries them (P3); a tile with nothing known for a
    food says so instead of printing 0."""

    PROTEIN = "protein"
    FIBER = "fiber"
    WATER = "water"
    PRODUCE = "produce"
    CARBS = "carbs"
    FAT = "fat"
    SUGAR = "sugar"
    SODIUM = "sodium"


class NudgeLevel(str, Enum):
    """How much the app says (decision 66): the engine's three delivery levels, asked in the
    person's own sentences ("Only when I'm slipping", "Coach me along the way", "Nothing. I'll
    check in myself."). Stored here, where the engine reads it; the phone keeps a cache."""

    ESSENTIAL = "essential"
    STANDARD = "standard"
    OFF = "off"


class Friction(str, Enum):
    """What makes tracking hard for the person (decision 66). Each value moves exactly one
    thing (projection.py experience_for); none is ever named back as a kind of person."""

    FORGETTING = "forgetting"
    PORTIONS = "portions"
    EATING_OUT = "eating_out"
    TIME = "time"


class Experience(BaseModel):
    """What the level and the frictions change, said once by the server (projection.py) so the
    phone arranges and never decides. Additive on the preference response."""

    nudge_level: NudgeLevel | None = None
    # The ladder's invitations are the maker speaking first about the person's setup; only
    # "Coach me along the way" asked for that voice. None (never asked) keeps today's behaviour.
    offers_invitations: bool = True
    # "I forget": one local reminder in the evening when a meal is still unlogged.
    evening_reminder: bool = False
    # "Portions and amounts": the amount checks fire at the variant bar instead of the standard.
    amount_checks: Literal["standard", "eager"] = "standard"
    # "Eating out": the bar's hint names the photo path.
    bar_hint: Literal["default", "photo"] = "default"
    # "It takes too long": "Save as a usual" on by default until three usuals exist.
    seed_usuals: bool = False


class PreferenceSource(str, Enum):
    """Who moved the preference. ``DEFAULT`` is never stored: it is what GET returns for an
    account with no row (version 0), so the client can tell "never chosen" from "chose five"."""

    DEFAULT = "default"
    CHOSEN = "chosen"
    INVITED = "invited"
    DECLINED = "declined"
    COACH = "coach"


class TrackingPreference(BaseModel):
    """The latest version, or the default when none exists."""

    mode: TrackingMode
    focus_metrics: list[FocusMetric] = Field(default_factory=list)
    # Offer keys the person asked never to see again: a mode value ("calories") or a focus
    # metric ("focus:protein"). See ``offer_key``.
    declined_offers: list[str] = Field(default_factory=list)
    source: PreferenceSource
    version: int = Field(ge=0)
    created_at: datetime | None = None
    # What "Also show" may offer for this mode (tracking/projection.py offerable_focus); the
    # router fills it so the client never carries the modes' own-metrics table. Additive.
    offerable_focus: list[FocusMetric] = Field(default_factory=list)
    # Decision 66: how much the app says (None = never asked) and what gets in the way, and
    # what the two change (the router fills ``experience`` from projection.py). Additive.
    nudge_level: NudgeLevel | None = None
    frictions: list[Friction] = Field(default_factory=list)
    experience: Experience | None = None


class TrackingUpdate(BaseModel):
    """PUT /tracking: append the next version. Fields left None keep the latest value, so a
    client can change one thing without restating the rest. ``decline_offer`` records a
    "Don't offer this again" (the offer key joins ``declined_offers``; the source is then
    ``declined`` unless the caller says otherwise)."""

    mode: TrackingMode | None = None
    focus_metrics: list[FocusMetric] | None = None
    decline_offer: str | None = Field(default=None, max_length=40)
    source: PreferenceSource = PreferenceSource.CHOSEN
    # Decision 66. None keeps the latest value; an empty frictions list is an answer ("none").
    nudge_level: NudgeLevel | None = None
    frictions: list[Friction] | None = Field(default=None, max_length=8)


def offer_key(*, mode: TrackingMode | None = None, focus: FocusMetric | None = None) -> str:
    """The one spelling of an offer, shared by invitations and declines."""
    if mode is not None:
        return mode.value
    if focus is not None:
        return f"focus:{focus.value}"
    raise ValueError("an offer names a mode or a focus metric")
