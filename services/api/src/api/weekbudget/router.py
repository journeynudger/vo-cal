"""Weekly budget API: read the adjusted week, replan today+future days.

Orchestration only — the numbers live in the tested engine (engine.py; AGENTS.md
#6). The router resolves the tz-aware "today", assembles durable facts (active
protocol, latest week plan, the week's live meal_logs) and hands them to
``compute_week``; PUT validates a replan and appends a new week_plans version.

The week is Monday..Sunday in the user's timezone. Tz resolution mirrors
/meals/today exactly: the device ``tz`` param wins, else profiles.tz, else UTC —
two endpoints bucketing the same log onto different days is the field bug
(2026-07) that rule exists to prevent.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, HTTPException, Query, status

from ..dependencies import CurrentUser, Db
from ..meals.store import MealsStore
from ..meals.today import targets_from_protocol
from .engine import ComputedWeek, compute_week
from .schemas import BudgetDay, WeekBudgetResponse, WeekPlanRequest
from .store import WeekPlansStore

router = APIRouter(prefix="/week", tags=["week"])

# Plan-allocation bounds relative to baseline B: a day may not drop below half
# the daily target (nor 1200 kcal) or exceed double it — a "plan" outside that
# band is a data-entry error, not a strategy.
_PLAN_FLOOR_KCAL = 1200.0
_PLAN_MIN_FRACTION = 0.5
_PLAN_MAX_FRACTION = 2.0

# A replan moves kcal BETWEEN days; the week total belongs to the protocol.
# Whole-kcal rounding across 7 days can drift a few kcal, so the sum check
# carries a small tolerance instead of demanding exact equality.
_SUM_TOLERANCE_KCAL = 10.0


@router.get("/budget", response_model=WeekBudgetResponse)
async def week_budget(
    user_id: CurrentUser,
    db: Db,
    date: str = Query(..., description="Any day of the requested week, YYYY-MM-DD"),
    tz: str | None = Query(
        None, description="IANA timezone of the requesting device; overrides the profile tz"
    ),
) -> WeekBudgetResponse:
    """The Monday..Sunday week containing ``date``, with carry-adjusted targets."""
    day = _parse_day(date)
    zone = _zone_or_none(tz) or await _user_tz(db, user_id)
    week_start = day - timedelta(days=day.weekday())
    return await _build_budget(db, user_id, zone, week_start)


@router.put("/plan", response_model=WeekBudgetResponse)
async def put_week_plan(
    req: WeekPlanRequest, user_id: CurrentUser, db: Db
) -> WeekBudgetResponse:
    """Replan today+future days of a week; append a new week_plans version.

    Past days are frozen server-side to their currently effective plan — a
    client naming a past date gets a 422, never a silent rewrite of history.
    Remaining days omitted from ``allocations`` keep their currently effective
    value (partial replans are legal; the sum check runs over the full week).
    """
    zone = _zone_or_none(req.tz) or await _user_tz(db, user_id)
    week_start = _parse_day(req.week_start)
    if week_start.weekday() != 0:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "week_start must be a Monday"
        )
    today = datetime.now(zone).date()
    week_end = week_start + timedelta(days=6)
    if week_end < today:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "week has already ended. Past weeks cannot be replanned",
        )

    targets, _ = targets_from_protocol(await _active_protocol(db, user_id))
    baseline = targets.kcal
    store = WeekPlansStore(db)
    current = await _effective_plan(store, user_id, week_start, baseline)

    submitted: dict[date, int] = {}
    lo = max(_PLAN_FLOOR_KCAL, _PLAN_MIN_FRACTION * baseline)
    hi = _PLAN_MAX_FRACTION * baseline
    for key, value in req.allocations.items():
        try:
            d = date.fromisoformat(key)
        except ValueError as exc:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                f"allocation date '{key}' must be YYYY-MM-DD",
            ) from exc
        if not week_start <= d <= week_end:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                f"allocation date {key} is outside the week {week_start} .. {week_end}",
            )
        if d < today:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                f"allocation date {key} is in the past. Past days are frozen",
            )
        if not lo <= value <= hi:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                f"allocation for {key} must be between {lo:.0f} and {hi:.0f} kcal",
            )
        submitted[d] = int(value)

    # Full-week plan: frozen past + (submitted or kept) today/future. Values are
    # stored as whole kcal — the plan is user intent, not derived math.
    new_plan = {
        d: submitted.get(d, round(current[d]))
        for d in (week_start + timedelta(days=i) for i in range(7))
    }
    weekly_target = sum(current.values())
    if abs(sum(new_plan.values()) - weekly_target) > _SUM_TOLERANCE_KCAL:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            f"allocations must preserve the weekly target of {weekly_target:.0f} kcal "
            f"(±{_SUM_TOLERANCE_KCAL:.0f}); got {sum(new_plan.values())}",
        )

    await store.insert(
        user_id=user_id,
        week_start=week_start,
        allocations={d.isoformat(): v for d, v in sorted(new_plan.items())},
    )
    return await _build_budget(db, user_id, zone, week_start)


# -- assembly -----------------------------------------------------------------


async def _build_budget(
    db: Db, user_id: CurrentUser, zone: ZoneInfo, week_start: date
) -> WeekBudgetResponse:
    """Assemble durable facts for the week and run the engine (shared GET/PUT)."""
    today = datetime.now(zone).date()
    targets, is_stub = targets_from_protocol(await _active_protocol(db, user_id))
    baseline = targets.kcal
    planned = await _effective_plan(WeekPlansStore(db), user_id, week_start, baseline)

    start = datetime.combine(week_start, datetime.min.time(), tzinfo=zone)
    rows = await MealsStore(db).list_between(user_id, start, start + timedelta(days=7))
    consumed: dict[date, float] = {}
    logged: set[date] = set()
    for row in rows:
        local_day = datetime.fromisoformat(row["logged_at"]).astimezone(zone).date()
        kcal = float((row.get("totals") or {}).get("kcal") or 0.0)
        consumed[local_day] = consumed.get(local_day, 0.0) + kcal
        logged.add(local_day)

    week = compute_week(
        week_start=week_start,
        today=today,
        baseline=baseline,
        planned=planned,
        consumed=consumed,
        logged=logged,
    )
    return _to_response(week, is_stub)


async def _effective_plan(
    store: WeekPlansStore, user_id: CurrentUser, week_start: date, baseline: float
) -> dict[date, float]:
    """The currently effective per-day plan: latest week_plans row, defaulting
    every (or any missing) day to the baseline. Lenient on jsonb shape — a
    malformed key falls back rather than 500s a read path."""
    days = [week_start + timedelta(days=i) for i in range(7)]
    planned: dict[date, float] = dict.fromkeys(days, baseline)
    row = await store.latest(user_id, week_start)
    for key, value in ((row or {}).get("allocations") or {}).items():
        try:
            d = date.fromisoformat(str(key))
            kcal = float(value)
        except (TypeError, ValueError):
            continue
        if d in planned:
            planned[d] = kcal
    return planned


def _to_response(week: ComputedWeek, is_stub: bool) -> WeekBudgetResponse:
    return WeekBudgetResponse(
        week_start=week.week_start.isoformat(),
        week_end=week.week_end.isoformat(),
        baseline_daily_kcal=round(week.baseline, 1),
        weekly_target_kcal=round(week.weekly_target, 1),
        carry_kcal=round(week.carry, 1),
        remaining_kcal=round(week.remaining_kcal, 1),
        fully_rebalanced=week.fully_rebalanced,
        leftover_kcal=round(week.leftover_kcal, 1),
        targets_are_stub=is_stub,
        days=[
            BudgetDay(
                date=d.day.isoformat(),
                weekday=d.weekday,
                planned_kcal=round(d.planned, 1),
                adjusted_target_kcal=d.adjusted,
                consumed_kcal=round(d.consumed, 1),
                logged=d.logged,
                state=d.state,  # type: ignore[arg-type]
            )
            for d in week.days
        ],
    )


# -- helpers (mirrors meals/router.py — checkin duplicates these too; keeping the
# copies local avoids coupling this package to the meals router surface) -------


def _zone_or_none(name: str | None) -> ZoneInfo | None:
    """A ZoneInfo for a client-sent IANA name, or None (unknown/absent → profile path)."""
    if not name:
        return None
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return None


async def _user_tz(db: Db, user_id: CurrentUser) -> ZoneInfo:
    rows = await db.select("profiles", user_id=user_id)
    name = (rows[0].get("tz") if rows else None) or "UTC"
    try:
        return ZoneInfo(name)
    except ZoneInfoNotFoundError:
        return ZoneInfo("UTC")


def _parse_day(value: str) -> date:
    try:
        # Localized by the caller via combine(..., tzinfo=zone); naive parse is intentional.
        return datetime.strptime(value, "%Y-%m-%d").date()  # noqa: DTZ007
    except ValueError as exc:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "date must be YYYY-MM-DD"
        ) from exc


async def _active_protocol(db: Db, user_id: CurrentUser) -> dict | None:
    """The user's active protocol row, read directly through the Database seam
    (NOT via the protocols package — same decoupling reasoning as /meals/today:
    this surface only consumes the ``targets`` jsonb)."""
    rows = await db.select("protocols", {"active": True}, user_id=user_id)
    return rows[0] if rows else None
