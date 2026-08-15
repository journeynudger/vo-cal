"""Wire contracts for the weekly budget endpoints.

Snake_case throughout (matches every other router's response shape). Response
fields added later must also be emitted server-side AND optional/custom-decoded
in the Swift mirror — see the ``is_estimate`` gotcha in services/api/AGENTS.md.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

DayState = Literal["past", "today", "future"]


class BudgetDay(BaseModel):
    """One day of the week as the budget screen renders it."""

    date: str  # YYYY-MM-DD in the user's timezone
    weekday: int  # 0 = Monday .. 6 = Sunday
    planned_kcal: float
    # Whole kcal by contract: the engine keeps float math; rounding happens once
    # at the edge (engine._round_days) so the week total stays exact.
    adjusted_target_kcal: int
    consumed_kcal: float
    logged: bool  # at least one live meal_logs row that day (water never counts)
    state: DayState


class WeekBudgetResponse(BaseModel):
    """GET /week/budget (and the PUT /week/plan success payload — same shape)."""

    week_start: str  # Monday, YYYY-MM-DD
    week_end: str  # Sunday, YYYY-MM-DD
    baseline_daily_kcal: float
    weekly_target_kcal: float  # sum of the 7 planned_kcal
    # Positive = under-ate so far (headroom to spend); negative = over-ate.
    carry_kcal: float
    # Sum of remaining adjusted targets minus today's consumed so far.
    remaining_kcal: float
    fully_rebalanced: bool
    leftover_kcal: float  # non-zero only when fully_rebalanced is false
    targets_are_stub: bool  # no active protocol → documented 2000 kcal stub
    days: list[BudgetDay]


class WeekPlanRequest(BaseModel):
    """PUT /week/plan body.

    ``allocations`` may only name today+future dates of the week — past days
    are frozen server-side to their currently effective plan (history doesn't
    move). Values are whole kcal.
    """

    week_start: str  # must be a Monday, YYYY-MM-DD
    tz: str | None = None  # IANA; overrides the profile tz (same as /meals/today)
    allocations: dict[str, int] = Field(default_factory=dict)
