"""POST /nudges/plan — assemble deterministic signals from durable rows, run the engine.

Orchestration only (parser/router.py pattern): signal math lives in meals/today.py
helpers, the decisions in engine.py and invitations.py, the copy in catalog.py. The client
(NudgeCenter, shipped in TestFlight build 16) refreshes on Today-open and post-log; failures
are silent on its side, so this endpoint must be cheap — a handful of owner-scoped reads, no
LLM. The person's mode (decision 63) and the invitation signals (decision 62) are read here
and handed to the engine.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, tzinfo
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter

from ..checkin.store import CheckinStore
from ..dependencies import CurrentUser, Db
from ..meals.plan import MealPlanStore, match_slots, plan_from_row
from ..meals.store import MealsStore, WaterStore
from ..meals.today import Targets, consumed_from_day, targets_from_protocol
from ..protocols.store import ProtocolsStore
from ..tracking.projection import experience_for
from ..tracking.schemas import TrackingMode
from ..tracking.store import TrackingStore
from .engine import NudgeSignals, plan
from .invitations import InvitationSignals, suggest
from .schemas import NudgePlan, NudgePlanRequest

_logger = logging.getLogger(__name__)

router = APIRouter(prefix="/nudges", tags=["nudges"])

# How far back the one bounded window reads: the invitations need three weeks of logged days,
# which also covers "gone quiet" and the week's streak.
_LOOKBACK_DAYS = 21
# A check-in this recent counts as this week's; older ones say nothing about the week.
_CHECKIN_FRESH_DAYS = 7
# The check-in reads as a rough week when energy is low or hunger is high (1 to 5 scales).
_LOW_ENERGY = 2
_HIGH_HUNGER = 4


@router.post("/plan", response_model=NudgePlan)
async def nudge_plan(req: NudgePlanRequest, user_id: CurrentUser, db: Db) -> NudgePlan:
    tz = await _user_tz(db, user_id)
    now_local = datetime.now(tz)
    day_start = now_local.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = day_start - timedelta(days=now_local.weekday())
    lookback_start = day_start - timedelta(days=_LOOKBACK_DAYS)

    meals_store = MealsStore(db)
    # One bounded window covers today, the streak, quietness and the invitation counts.
    rows = await meals_store.list_between(user_id, lookback_start, now_local + timedelta(seconds=1))
    water_oz = await WaterStore(db).total_between(user_id, day_start, now_local + timedelta(seconds=1))
    # Through the store, like /meals/today: get_active self-heals the zero-active gap a failed
    # supersede leaves, where a raw read served the stub as if it were the plan (2026-08-19).
    protocol_row = await ProtocolsStore(db).get_active(user_id)
    targets, is_stub = targets_from_protocol(protocol_row)
    if is_stub:
        # No protocol yet. The placeholders exist so Today can render, not as anyone's targets:
        # "you've got comfortable room left today" against a 2,000 kcal stub is a claim above
        # proof (MUST NOT #6). Every target-driven trigger in engine._triggered guards on
        # target > 0, so zeroed targets leave exactly the habit nudges (gone quiet, nothing
        # logged, slipping) reachable, which need no plan to be true.
        targets = Targets()
    preference = await TrackingStore(db).latest(user_id)
    # Decision 66: how much the app says lives in the preference now. A stored level wins over
    # the request's (the phone's value is a cache of it); a client whose person was never asked
    # keeps sending its own, as shipped builds do.
    experience = experience_for(preference.nudge_level, preference.frictions)
    level = preference.nudge_level.value if preference.nudge_level is not None else req.level

    today_rows = [r for r in rows if _local(r["logged_at"], tz) >= day_start]
    consumed = consumed_from_day(today_rows, water_oz)

    logged_days = {_local(r["logged_at"], tz).date() for r in rows}
    today = now_local.date()
    days_this_week = sum(1 for d in logged_days if d >= week_start.date())
    # Never logged in the window -> treat as long-quiet.
    days_since = (today - max(logged_days)).days if logged_days else _LOOKBACK_DAYS
    last_14 = sum(1 for d in logged_days if (today - d).days < 14)
    last_21 = sum(1 for d in logged_days if (today - d).days < 21)

    # Meal-plan mode (decision 65): the planned meals against today's logs, ticked by name
    # the way Today ticks them, so the plan nudge speaks to the same card the person sees.
    plan_slots = plan_logged = 0
    if preference.mode is TrackingMode.MEAL_PLAN:
        plan_row = await MealPlanStore(db).latest_row(user_id)
        if plan_row is not None:
            statuses, _ = match_slots(plan_from_row(plan_row).slots, today_rows)
            plan_slots = len(statuses)
            plan_logged = sum(1 for status in statuses if status.logged)

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
        produce_consumed=consumed.produce,
        produce_target=targets.produce,
        weekday=now_local.weekday(),
        stress_flag=await _stress_flag(db, user_id, now_local),
        plan_slots=plan_slots,
        plan_logged=plan_logged,
        planned_meals=_planned_meals(protocol_row),
        evening_reminder=experience.evening_reminder,
    )
    # An invitation is the maker speaking first about the person's setup; only "Coach me along
    # the way" (and a person never asked) hears that voice (decision 66).
    invitation = (
        suggest(
            InvitationSignals(
                mode=preference.mode,
                focus_metrics=tuple(preference.focus_metrics),
                declined_offers=frozenset(preference.declined_offers),
                days_logged_last_21=last_21,
                days_logged_last_14=last_14,
                days_logged_days_15_to_21=last_21 - last_14,
            )
        )
        if experience.offers_invitations
        else None
    )
    result = plan(
        signals,
        req.recently_shown,
        now_local,
        level=level,
        mode=preference.mode,
        focus=preference.focus_metrics,
        invitation=invitation,
    )
    # [nudge]: counts only (MUST-NOT #5) — which triggers fired, never user data.
    _logger.info(
        "[nudge] plan level=%s mode=%s immediate=%d scheduled=%d ids=%s",
        level,
        preference.mode.value,
        len(result.immediate),
        len(result.scheduled),
        [c.id for c in result.immediate] + [s.card.id for s in result.scheduled],
    )
    return result


async def _stress_flag(db: Db, user_id: CurrentUser, now_local: datetime) -> bool:
    """The latest check-in, if it is this week's, read as a rough week (decision 63): the
    hunger and energy a check-in collects feed the stress signal and nothing else."""
    latest = await CheckinStore(db).latest(user_id)
    if latest is None:
        return False
    created = latest.get("created_at")
    try:
        when = created if isinstance(created, datetime) else datetime.fromisoformat(str(created))
    except (TypeError, ValueError):
        return False
    if when.tzinfo is None:
        when = when.replace(tzinfo=now_local.tzinfo)
    if (now_local - when.astimezone(now_local.tzinfo)).days >= _CHECKIN_FRESH_DAYS:
        return False
    energy = latest.get("energy")
    hunger = latest.get("hunger")
    return (energy is not None and int(energy) <= _LOW_ENERGY) or (
        hunger is not None and int(hunger) >= _HIGH_HUNGER
    )


def _planned_meals(protocol_row: dict | None) -> int:
    """The meals a day the person said they eat, from the active protocol's targets; 0 when
    there is no protocol or the engine never stored it (the evening reminder then stays quiet)."""
    if protocol_row is None:
        return 0
    raw = (protocol_row.get("targets") or {}).get("meals_per_day")
    try:
        return int(raw) if raw is not None else 0
    except (TypeError, ValueError):
        return 0


def _local(logged_at: object, tz: tzinfo) -> datetime:
    value = logged_at if isinstance(logged_at, datetime) else datetime.fromisoformat(str(logged_at))
    if value.tzinfo is None:
        value = value.replace(tzinfo=tz)
    return value.astimezone(tz)


async def _user_tz(db: Db, user_id: CurrentUser) -> tzinfo:
    """Profile timezone, defaulting to UTC — same posture as checkin/meals routers."""
    rows = await db.select("profiles", {"id": str(user_id)})
    # The profiles column is ``tz`` (initial migration) — reading "timezone" always
    # missed and silently bucketed every user's nudge windows in UTC.
    name = (rows[0].get("tz") if rows else None) or "UTC"
    try:
        return ZoneInfo(name)
    except ZoneInfoNotFoundError:
        return ZoneInfo("UTC")
