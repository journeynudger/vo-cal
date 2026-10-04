"""The adjusted week, shared by the week screen and Today (decision 61).

One number for one day: /week/budget and /meals/today both read the week through here, so
the target Today prints for a day is the week screen's adjusted target for that day (the
person's plan plus any carried overage). Orchestration only; the math is engine.compute_week.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from ..db import SupportsDatabase
from ..meals.store import MealsStore
from ..meals.today import targets_from_protocol
from ..protocols.store import ProtocolsStore
from .engine import ComputedWeek, compute_week
from .store import WeekPlansStore


async def adjusted_week(
    db: SupportsDatabase, user_id: UUID, zone: ZoneInfo, week_start: date
) -> tuple[ComputedWeek, bool]:
    """Durable facts for the Monday-start week → the engine's week; ``is_stub`` says the
    baseline is the pre-onboarding placeholder. Reads the protocol through the store so the
    zero-active heal applies here too (the raw read served the stub once, 2026-08-19)."""
    today = datetime.now(zone).date()
    targets, is_stub = targets_from_protocol(await ProtocolsStore(db).get_active(user_id))
    baseline = targets.kcal
    planned = await effective_plan(WeekPlansStore(db), user_id, week_start, baseline)

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
    return week, is_stub


def adjusted_target_for(week: ComputedWeek, day: date) -> int | None:
    """The week's adjusted target for ``day``, or None when the day is not in the week."""
    for computed in week.days:
        if computed.day == day:
            return computed.adjusted
    return None


async def effective_plan(
    store: WeekPlansStore, user_id: UUID, week_start: date, baseline: float
) -> dict[date, float]:
    """The currently effective per-day plan: latest week_plans row, defaulting every (or any
    missing) day to the baseline. Lenient on jsonb shape: a malformed key falls back rather
    than 500s a read path."""
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
