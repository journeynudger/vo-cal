"""How the person wants to follow their nutrition (decisions 57 and 58).

One typed value, chosen by the person and versioned, drives three projections: which intake
questions are asked, what the reveal and Today print, and which nudges may speak. The mode
names are the person's own sentences from the sales calls, never a brand or a coach's rung
(the Rams review, docs/design/personalized-tracker-spec.md R1 and R5).
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum

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

    FIBER = "fiber"
    WATER = "water"
    PRODUCE = "produce"
    CARBS = "carbs"
    FAT = "fat"
    SUGAR = "sugar"
    SODIUM = "sodium"


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
    declined_modes: list[TrackingMode] = Field(default_factory=list)
    source: PreferenceSource
    version: int = Field(ge=0)
    created_at: datetime | None = None


class TrackingUpdate(BaseModel):
    """PUT /tracking: append the next version. Fields left None keep the latest value, so a
    client can change one thing without restating the rest. ``decline_mode`` records a
    "Don't offer this again" (it joins ``declined_modes``; the source is then ``declined``
    unless the caller says otherwise)."""

    mode: TrackingMode | None = None
    focus_metrics: list[FocusMetric] | None = None
    decline_mode: TrackingMode | None = None
    source: PreferenceSource = PreferenceSource.CHOSEN
