"""Request/response schemas for the meals domain (log / list / delete).

A ``LogMealRequest`` is the user's confirmed meal — the final items after any
edits in the voice-log UI. The server recomputes totals (never trusts client
math, AGENTS.md #6), diffs confirmed-vs-parsed into append-only corrections, and
returns the durable ``MealLog``.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field

from ..nutrition.schemas import Macros, ResolutionSource
from ..parser.schemas import MealType, State, Unit


class ConfirmedItem(BaseModel):
    """One item as the user confirmed it (possibly edited from the parse).

    ``grams``/``macros``/``source`` are advisory: the server re-resolves every item from
    its identity at confirm and overwrites them with deterministic values — the client's
    numbers are never trusted into durable totals (Non-Negotiable #6, RT-02). ``variant``
    must round-trip from the parse result so re-resolution picks the chosen variant (e.g.
    fat-free cheddar) instead of regressing to the family default.
    """

    name: str = Field(min_length=1)
    amount: float | None = Field(default=None, gt=0)
    unit: Unit | None = None
    state: State = State.UNSPECIFIED
    fat_ratio: str | None = None
    variant: str | None = None
    brand: str | None = None
    prep_method: str | None = None
    grams: float = Field(ge=0)
    macros: Macros
    confidence: float = Field(ge=0.0, le=1.0)
    source: ResolutionSource = ResolutionSource.DICTIONARY


class LogMealRequest(BaseModel):
    # Client-generated id makes confirm idempotent across outbox/offline retries.
    client_meal_id: str = Field(min_length=1, max_length=128)
    parse_id: UUID | None = Field(
        default=None, description="Provenance for corrections; null when logging a 'usual'"
    )
    name: str | None = None
    meal_type: MealType = MealType.UNSPECIFIED
    items: list[ConfirmedItem] = Field(min_length=1, max_length=50)
    logged_at: datetime | None = Field(default=None, description="Defaults to server now (UTC)")
    save_as_usual: bool = False


class MealLog(BaseModel):
    id: UUID
    name: str | None
    meal_type: MealType
    items: list[ConfirmedItem]
    totals: Macros
    confidence: float
    logged_at: datetime
    corrections_count: int = 0


class DayMeals(BaseModel):
    date: str
    meals: list[MealLog]
    totals: Macros


class WaterLogRequest(BaseModel):
    """Append an amount of water to the day's tally (shows up in /today.consumed.water)."""

    # Client-generated id makes water logging idempotent across outbox/offline retries,
    # the same contract as client_meal_id — water is a dashboard pillar (decision #28)
    # and a replayed POST must not double-count it (RT-13).
    client_water_id: str = Field(min_length=1, max_length=128)
    amount_oz: float = Field(gt=0, le=512, description="Ounces of water for this entry")
    logged_at: datetime | None = Field(default=None, description="Defaults to server now (UTC)")


class WaterLog(BaseModel):
    id: UUID
    amount_oz: float
    logged_at: datetime
    # Already logged? (idempotent replay returns the existing entry.)
    deduped: bool = False
