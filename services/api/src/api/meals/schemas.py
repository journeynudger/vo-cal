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

from ..nutrition.schemas import FoodIdentity, Macros, ResolutionSource
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
    # Web sources for a grounded estimate (additive/optional; provenance in meal_logs).
    sources: list[dict] | None = None
    source: ResolutionSource = ResolutionSource.DICTIONARY
    # AI estimate (food not in our DB): macros are a flagged best-guess, shown as an estimate.
    is_estimate: bool = False
    # The user typed these macros/grams on the edit screen. When True the server TRUSTS them
    # verbatim (skips re-resolution) — the one path where client numbers are authoritative,
    # because a manual correction is the user's own ground truth.
    manual: bool = False
    # WHAT was priced (nutrition/schemas.py FoodIdentity), SERVER-STAMPED at confirm from the
    # owning parse row and persisted in meal_logs so a post-log amount edit re-prices the same
    # food. As sent by a client it is IGNORED: it carries per-100g numbers and the client never
    # authors trustworthy macros (Non-Negotiable #6). None for manual items and groupings.
    identity: FoodIdentity | None = None
    # Provenance + idempotency marker for the append flow: the parse this item arrived
    # from when it was appended to an existing meal (None for original confirm items).
    # Server-stamped; a replayed append with the same parse finds its items already
    # present and returns unchanged. Soft provenance only — an iOS edit round-trip may
    # strip it (clients don't re-send unknown fields); the durable audit trail is the
    # `item_appended` corrections row, not this marker.
    appended_from_parse: str | None = None


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


class UpdateMealRequest(BaseModel):
    """Edit an already-logged meal: replace its items (and optionally name/type). The server
    re-resolves non-manual items and recomputes totals/confidence, exactly like confirm."""

    name: str | None = None
    meal_type: MealType | None = None
    items: list[ConfirmedItem] = Field(min_length=1, max_length=50)


class AppendToMealRequest(BaseModel):
    """Append a new voice capture's confirmed items to an already-logged meal (the
    "add more" flow). ``parse_id`` is the appended utterance's parse: provenance for
    the audit trail and the idempotency key for replays."""

    parse_id: UUID | None = Field(
        default=None, description="Parse of the appended utterance (provenance + idempotency)"
    )
    items: list[ConfirmedItem] = Field(min_length=1, max_length=50)


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


class SavedMeal(BaseModel):
    """A saved meal template — a "usual" (``GET /meals/usuals``).

    ``items`` are stored ConfirmedItem dumps, so re-logging one is a plain
    ``POST /meals`` with those items and ``parse_id`` null: the server re-resolves
    them and recomputes totals on that path, which is why a template saved months
    ago can never write stale macros (RT-02). ``totals`` here is only the display
    figure for the chip.
    """

    id: UUID
    name: str
    items: list[ConfirmedItem]
    totals: Macros
    created_at: datetime


class WeeklySummary(BaseModel):
    """The check-in's capture-quality overview: consistency AND certainty (spec: never a
    grade, never a fake tracked-% — meals_logged is a plain count until expected-meals
    exist). ``avg_certainty`` is None when no meal this week carries scoreable items."""

    week_start: str  # YYYY-MM-DD (inclusive, user tz)
    week_end: str  # YYYY-MM-DD (inclusive)
    meals_logged: int
    days_logged: int
    avg_kcal: int | None = None  # mean kcal per LOGGED day (None when nothing logged)
    avg_certainty: int | None = None  # 0-100
    most_common_missing_detail: str | None = None
    focus_tip: str | None = None
    # False under sparse data (< 3 meals) — the client shows the gentle
    # "as you log more, we'll show trends here" copy instead of thin stats.
    sufficient_data: bool = False


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
