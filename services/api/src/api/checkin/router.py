"""Checkin routes — Phase G (the weekly check-in and the monthly recalibration).

Surfaces:
  - ``POST /checkin/checkins``        store a self-reported check-in (durable row)
  - ``GET  /checkin/checkins``        the history (the Progress page's weight trend)
  - ``GET  /checkin/checkins/due``    is the weekly check-in due right now?
  - ``POST /checkin/recommend``       the recalibration proposal (recommend.py)

Orchestration only. The decisions live in the tested engine (recommend.py); this router
assembles the durable inputs and persists/returns the result — it computes nothing the
engine owns (AGENTS.md #6). The situational nudges that once lived here moved into the one
nudge engine (nudges/, decision 63); the check-in's hunger and energy feed its stress signal.

NOTE the paths sit under the package prefix ``/checkin`` because routes are added
to the existing mounted router (main.py owns mounting; this file may not). The
resource names (``checkins`` / ``nudges``) are preserved.
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta, tzinfo
from zoneinfo import ZoneInfo

from fastapi import APIRouter, HTTPException, Query, status

from ..dependencies import CurrentUser, Db
from ..intake.store import IntakeStore
from ..meals.guidance import load_guidance
from ..protocols.schemas import IntakeProfile
from ..protocols.staleness import parse_created_at
from ..protocols.store import ProtocolsStore
from ..tracking.projection import projection_for
from ..tracking.store import TrackingStore
from ..zones import profile_zone
from .recommend import basis_weight_lb, build_recal_inputs, numbers_blind_hold, recommend
from .schemas import (
    CheckinDue,
    CheckinRequest,
    CheckinResponse,
    RecommendationResponse,
)
from .store import CheckinStore

_logger = logging.getLogger(__name__)


router = APIRouter(prefix="/checkin", tags=["checkin"])

# A check-in is "due" again once at least this many days have passed. The banner
# copy promises a WEEKLY ritual, so the cadence is 7: the earlier 3-day window
# resurfaced "Weekly check-in ready" twice a week, which read as nagging (user
# report 2026-08 — "too frequent, I see one every time"). Mid-week coaching is
# the nudge engine's job (nudges/), not the check-in banner's.
_DUE_AFTER_DAYS = 7

# The FIRST check-in needs a week worth reviewing: it becomes due only once the
# user's earliest meal log is this old. The old rule (no check-in → always due)
# planted the banner on day one of a fresh account, when there was nothing to
# check in about — noise before the ritual ever had a meaning.
_FIRST_CHECKIN_AFTER_DAYS = 5
# Bounded lookback for the earliest-log probe (matches the "recent history is
# what matters" posture of the nudge engine's window).
_FIRST_CHECKIN_LOOKBACK_DAYS = 30


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


@router.get("/checkins", response_model=list[CheckinResponse])
async def list_checkins(
    user_id: CurrentUser,
    db: Db,
    limit: int = Query(52, ge=1, le=200),
) -> list[CheckinResponse]:
    """Newest-first check-in history. Backs the Progress page's weight trend —
    a year of weekly check-ins fits the default cap."""
    rows = await CheckinStore(db).list_recent(user_id, limit=limit)
    return [_to_checkin_response(row) for row in rows]


@router.get("/checkins/due", response_model=CheckinDue)
async def checkin_due(user_id: CurrentUser, db: Db) -> CheckinDue:
    store = CheckinStore(db)
    tz = await _user_tz(db, user_id)
    now = datetime.now(tz)
    is_mid_week = now.weekday() < 3

    latest = await store.latest(user_id)
    if latest is None:
        # Never checked in: due only once there's a real stretch of logging to
        # review (earliest log ≥ _FIRST_CHECKIN_AFTER_DAYS old). A fresh account
        # used to see the banner from day one — noise, not a ritual.
        lookback = await store.meal_logs_between(
            user_id, now - timedelta(days=_FIRST_CHECKIN_LOOKBACK_DAYS), now
        )
        earliest = _aware(lookback[0]["logged_at"], tz) if lookback else None
        history_days = (now - earliest).days if earliest else 0
        due = history_days >= _FIRST_CHECKIN_AFTER_DAYS
        reason = (
            "First check-in: a week of logging is ready to review."
            if due
            else "No check-in yet; waiting for a first week of logging."
        )
        return CheckinDue(
            due=due,
            reason=reason,
            days_since_last=None,
            is_mid_week=is_mid_week,
        )

    last_dt = _aware(latest.get("created_at"), tz)
    days_since = (now - last_dt).days
    due = days_since >= _DUE_AFTER_DAYS
    reason = (
        f"{days_since} day(s) since last check-in (cadence {_DUE_AFTER_DAYS})."
        if due
        else f"Last check-in was {days_since} day(s) ago; not due yet."
    )
    return CheckinDue(due=due, reason=reason, days_since_last=days_since, is_mid_week=is_mid_week)


@router.post("/recommend", response_model=RecommendationResponse)
async def recommend_recalibration(user_id: CurrentUser, db: Db) -> RecommendationResponse:
    """The monthly recalibration recommendation from the latest check-in + active protocol +
    intake. Read-only — it proposes; POST /protocols/{id}/revise applies.

    A person whose mode prints no numbers gets the numbers-free hold before any prerequisite
    but a protocol: their check-in asks no weight, and the habits intake never asks a goal, so
    the profile's default fat-loss goal would otherwise run the titration and offer new daily
    calories to someone who chose never to see one (decision 72)."""
    if await numbers_blind(db, user_id):
        active = await ProtocolsStore(db).get_active(user_id)
        if active is None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "generate a protocol first")
        tz = await _user_tz(db, user_id)
        guidance = await load_guidance(db, user_id, datetime.now(tz).date(), tz)
        hold = numbers_blind_hold(guidance.line if guidance else None)
        return RecommendationResponse(protocol_id=str(active["id"]), **hold.as_dict())
    profile, active, checkin, basis = await load_recal_context(db, user_id)
    rec = recommend(recal_inputs_from_rows(profile, active, checkin, basis))
    return RecommendationResponse(protocol_id=str(active["id"]), **rec.as_dict())


def recal_inputs_from_rows(profile: IntakeProfile, active: dict, checkin: dict, basis_lb: float):
    """The titration's inputs from the durable rows (shared with /revise)."""
    return build_recal_inputs(
        intake_profile=profile,
        active_targets=dict(active.get("targets") or {}),
        protocol_created_at=parse_created_at(active.get("created_at")),
        starting_weight_lb=basis_lb,
        current_weight_kg=float(checkin["weight_kg"]),
        adherence_self=int(checkin["adherence_self"]),
        checkin_at=parse_created_at(checkin.get("created_at")),
    )


async def numbers_blind(db: Db, user_id: CurrentUser) -> bool:
    """True when the person's mode prints no numbers (tracking/projection.py). Shared with
    POST /protocols/{id}/revise so a recalibration can never be applied where none is shown."""
    preference = await TrackingStore(db).latest(user_id)
    return not projection_for(preference.mode).prints_numbers


async def load_recal_context(db: Db, user_id: CurrentUser) -> tuple[IntakeProfile, dict, dict, float]:
    """Load + validate the durable inputs recalibration needs, or 422 with which is missing,
    and the weight the active protocol was built from. Shared shape with POST
    /protocols/{id}/revise so both judge prerequisites alike."""
    intake_row = await IntakeStore(db).latest(user_id)
    if intake_row is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "complete intake first")
    active = await ProtocolsStore(db).get_active(user_id)
    if active is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "generate a protocol first")
    checkin = await CheckinStore(db).latest(user_id)
    if checkin is None or checkin.get("weight_kg") is None or checkin.get("adherence_self") is None:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "a check-in with weight and adherence is required",
        )
    profile = IntakeProfile.model_validate(intake_row["answers"])
    basis = basis_weight_lb(
        active_targets=dict(active.get("targets") or {}),
        protocol_created_at=parse_created_at(active.get("created_at")),
        intake_weight_lb=profile.weight_lb,
        intake_at=parse_created_at(intake_row.get("created_at")),
        checkins=await CheckinStore(db).list_recent(user_id),
        parse_at=parse_created_at,
    )
    return profile, active, checkin, basis


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
    return await profile_zone(db, user_id)
