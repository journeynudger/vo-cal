"""POST /nudges/plan — assemble deterministic signals from durable rows, run the engine.

Orchestration only (parser/router.py pattern): signal math lives in meals/today.py
helpers, the decisions in engine.py, the copy in catalog.py. The client (NudgeCenter,
shipped in TestFlight build 16) refreshes on Today-open and post-log; failures are
silent on its side, so this endpoint must be cheap — three owner-scoped reads, no LLM.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, tzinfo
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter

from ..dependencies import CurrentUser, Db
from ..meals.store import MealsStore, WaterStore
from ..meals.today import consumed_from_day, targets_from_protocol
from .engine import NudgeSignals, plan
from .schemas import NudgePlan, NudgePlanRequest

_logger = logging.getLogger(__name__)

router = APIRouter(prefix="/nudges", tags=["nudges"])

# How far back "gone quiet" looks before giving up counting (bounded read).
_LOOKBACK_DAYS = 8


@router.post("/plan", response_model=NudgePlan)
async def nudge_plan(req: NudgePlanRequest, user_id: CurrentUser, db: Db) -> NudgePlan:
    tz = await _user_tz(db, user_id)
    now_local = datetime.now(tz)
    day_start = now_local.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = day_start - timedelta(days=now_local.weekday())
    lookback_start = day_start - timedelta(days=_LOOKBACK_DAYS)

    meals_store = MealsStore(db)
    # One bounded window covers today + streak + quietness; sliced locally.
    rows = await meals_store.list_between(user_id, lookback_start, now_local + timedelta(seconds=1))
    water_oz = await WaterStore(db).total_between(user_id, day_start, now_local + timedelta(seconds=1))
    protocol_rows = await db.select("protocols", {"active": True}, user_id=user_id)
    targets, _is_stub = targets_from_protocol(protocol_rows[0] if protocol_rows else None)

    today_rows = [r for r in rows if _local(r["logged_at"], tz) >= day_start]
    consumed = consumed_from_day(today_rows, water_oz)

    logged_days = {_local(r["logged_at"], tz).date() for r in rows}
    days_this_week = sum(1 for d in logged_days if d >= week_start.date())
    # Never logged in the window -> treat as long-quiet.
    days_since = (now_local.date() - max(logged_days)).days if logged_days else _LOOKBACK_DAYS

    signals = NudgeSignals(
        kcal_consumed=consumed.kcal,
        kcal_target=targets.kcal,
        protein_consumed=consumed.protein,
        protein_target=targets.protein,
        water_oz=consumed.water,
        water_target=targets.water,
        fiber_consumed=consumed.fiber,
        fiber_target=targets.fiber,
        meals_today=len(today_rows),
        days_logged_this_week=days_this_week,
        days_since_last_log=days_since,
    )
    result = plan(signals, req.recently_shown, now_local)
    # [nudge]: counts only (MUST-NOT #5) — which triggers fired, never user data.
    _logger.info(
        "[nudge] plan immediate=%d scheduled=%d ids=%s",
        len(result.immediate),
        len(result.scheduled),
        [c.id for c in result.immediate] + [s.card.id for s in result.scheduled],
    )
    return result


def _local(logged_at: object, tz: tzinfo) -> datetime:
    value = logged_at if isinstance(logged_at, datetime) else datetime.fromisoformat(str(logged_at))
    if value.tzinfo is None:
        value = value.replace(tzinfo=tz)
    return value.astimezone(tz)


async def _user_tz(db: Db, user_id: CurrentUser) -> tzinfo:
    """Profile timezone, defaulting to UTC — same posture as checkin/meals routers."""
    rows = await db.select("profiles", {"id": str(user_id)})
    name = (rows[0].get("timezone") if rows else None) or "UTC"
    try:
        return ZoneInfo(name)
    except ZoneInfoNotFoundError:
        return ZoneInfo("UTC")
