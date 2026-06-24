"""Checkin routes — Phase G (mid-week situational nudging, decision #32).

Three surfaces:
  - ``POST /checkin/checkins``        store a self-reported check-in (durable row)
  - ``GET  /checkin/checkins/due``    is a mid-week check-in/nudge due right now?
  - ``GET  /checkin/nudges/current``  the one situational nudge for the user now

Orchestration only. The decisions live in the tested engines: ``select_nudge``
(nudge.py) and the recalibration tree (recommend.py). This router assembles the
deterministic signal inputs from durable rows and persists/returns the result —
it computes nothing the engines own (AGENTS.md #6).

NOTE the paths sit under the package prefix ``/checkin`` because routes are added
to the existing mounted router (main.py owns mounting; this file may not). The
resource names (``checkins`` / ``nudges``) are preserved.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta, tzinfo
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, HTTPException, status

from ..dependencies import CurrentUser, Db
from ..intake.store import IntakeStore
from ..protocols.schemas import IntakeProfile
from ..protocols.store import ProtocolsStore
from .nudge import NudgeSignals, select_nudge
from .recommend import build_recal_inputs, recommend
from .schemas import (
    CheckinDue,
    CheckinRequest,
    CheckinResponse,
    NudgeResponse,
    RecommendationResponse,
)
from .store import CheckinStore

router = APIRouter(prefix="/checkin", tags=["checkin"])

# A check-in is "due" again once at least this many days have passed (the
# mid-week cadence is one touch per week; the due window opens after ~3 days so a
# mid-week nudge can land before the next week starts).
_DUE_AFTER_DAYS = 3


@router.post("/checkins", response_model=CheckinResponse, status_code=201)
async def create_checkin(req: CheckinRequest, user_id: CurrentUser, db: Db) -> CheckinResponse:
    row = await CheckinStore(db).insert(
        user_id=user_id,
        weight_kg=req.weight_kg,
        hunger=req.hunger,
        energy=req.energy,
        adherence_self=req.adherence_self,
        notes=req.notes,
    )
    return _to_checkin_response(row)


@router.get("/checkins/due", response_model=CheckinDue)
async def checkin_due(user_id: CurrentUser, db: Db) -> CheckinDue:
    store = CheckinStore(db)
    tz = await _user_tz(db, user_id)
    now = datetime.now(tz)
    is_mid_week = now.weekday() < 3

    latest = await store.latest(user_id)
    if latest is None:
        # Never checked in: due, and especially so before the midpoint.
        return CheckinDue(
            due=True,
            reason="No check-in yet — first mid-week touch.",
            days_since_last=None,
            is_mid_week=is_mid_week,
        )

    last_dt = _aware(latest.get("created_at"), tz)
    days_since = (now - last_dt).days
    due = days_since >= _DUE_AFTER_DAYS
    reason = (
        f"{days_since} day(s) since last check-in (cadence {_DUE_AFTER_DAYS})."
        if due
        else f"Last check-in was {days_since} day(s) ago — not due yet."
    )
    return CheckinDue(due=due, reason=reason, days_since_last=days_since, is_mid_week=is_mid_week)


@router.get("/nudges/current", response_model=NudgeResponse)
async def current_nudge(user_id: CurrentUser, db: Db) -> NudgeResponse:
    signals = await _build_signals(db, user_id)
    nudge = select_nudge(signals)
    return NudgeResponse(
        trigger=nudge.trigger, message=nudge.message, branch_options=nudge.branch_options
    )


@router.post("/recommend", response_model=RecommendationResponse)
async def recommend_recalibration(user_id: CurrentUser, db: Db) -> RecommendationResponse:
    """The monthly recalibration recommendation from the latest check-in + active protocol +
    intake. Read-only — it proposes; POST /protocols/{id}/revise applies."""
    profile, active, checkin = await load_recal_context(db, user_id)
    rec = recommend(
        build_recal_inputs(
            intake_profile=profile,
            active_kcal=int(active["targets"]["kcal"]),
            current_weight_kg=float(checkin["weight_kg"]),
            adherence_self=int(checkin["adherence_self"]),
        )
    )
    return RecommendationResponse(protocol_id=str(active["id"]), **rec.as_dict())


async def load_recal_context(db: Db, user_id: CurrentUser) -> tuple[IntakeProfile, dict, dict]:
    """Load + validate the three durable inputs recalibration needs, or 422 with which is
    missing. Shared shape with POST /protocols/{id}/revise so both judge prerequisites alike."""
    intake_row = await IntakeStore(db).latest(user_id)
    if intake_row is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "complete intake first")
    active = await ProtocolsStore(db).get_active(user_id)
    if active is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "generate a protocol first")
    checkin = await CheckinStore(db).latest(user_id)
    if checkin is None or checkin.get("weight_kg") is None or checkin.get("adherence_self") is None:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "a check-in with weight and adherence is required",
        )
    return IntakeProfile.model_validate(intake_row["answers"]), active, checkin


# -- signal assembly ----------------------------------------------------------


async def _build_signals(db: Db, user_id: CurrentUser) -> NudgeSignals:
    """Derive deterministic nudge signals from this week's owner-scoped meal_logs.

    Adherence signals that need a protocol (kcal-vs-target, water, produce) are
    left ``None`` until the protocol engine (Phase F) lands; the bank simply
    skips rules whose inputs are absent. Day-count + last-log-age drive the
    no-log-today / mid-week-slipping rules with only meal_logs as input.
    """
    store = CheckinStore(db)
    tz = await _user_tz(db, user_id)
    now = datetime.now(tz)

    # This calendar week, Monday 00:00 (local) through now.
    week_start = datetime.combine(
        (now - timedelta(days=now.weekday())).date(), datetime.min.time(), tzinfo=tz
    )
    rows = await store.meal_logs_between(user_id, week_start, now + timedelta(seconds=1))

    days_logged = len({_local_date(r["logged_at"], tz) for r in rows})
    last_log_age = _last_log_age_hours(rows, now, tz)

    return NudgeSignals(
        weekday=now.weekday(),
        days_logged_this_week=days_logged,
        last_log_age_hours=last_log_age,
    )


def _last_log_age_hours(rows: list[dict], now: datetime, tz: tzinfo) -> float | None:
    if not rows:
        return None
    latest = max(_aware(r["logged_at"], tz) for r in rows)
    return round((now - latest).total_seconds() / 3600.0, 2)


# -- helpers ------------------------------------------------------------------


def _to_checkin_response(row: dict) -> CheckinResponse:
    return CheckinResponse(
        id=row["id"],
        weight_kg=row.get("weight_kg"),
        hunger=row.get("hunger"),
        energy=row.get("energy"),
        adherence_self=row.get("adherence_self"),
        notes=row.get("notes"),
        created_at=_aware(row.get("created_at"), UTC),
    )


def _local_date(logged_at: str, tz: tzinfo):
    return _aware(logged_at, tz).astimezone(tz).date()


def _aware(value: str | None, tz: tzinfo) -> datetime:
    """Parse an ISO timestamp into a tz-aware datetime; naive values get ``tz``."""
    dt = datetime.fromisoformat(value) if value else datetime.now(tz)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=tz)
    return dt


async def _user_tz(db: Db, user_id: CurrentUser) -> ZoneInfo:
    rows = await db.select("profiles", user_id=user_id)
    name = (rows[0].get("tz") if rows else None) or "UTC"
    try:
        return ZoneInfo(name)
    except ZoneInfoNotFoundError:
        return ZoneInfo("UTC")
