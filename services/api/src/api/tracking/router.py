"""GET /tracking, PUT /tracking: the person's way of following their nutrition.

Orchestration only: the store holds the versions, the schemas the vocabulary. PUT appends a
version merged with the latest, so the client changes one thing at a time; a decline joins the
list of modes never to be offered again (decision 62).
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter

from ..db import SupportsDatabase
from ..dependencies import CurrentUser, Db
from .projection import experience_for, offerable_focus
from .schemas import PreferenceSource, TrackingPreference, TrackingUpdate, offer_key
from .store import TrackingStore, preference_from_row

router = APIRouter(prefix="/tracking", tags=["tracking"])


@router.get("", response_model=TrackingPreference)
async def get_tracking(user_id: CurrentUser, db: Db) -> TrackingPreference:
    return _with_offerable(await TrackingStore(db).latest(user_id))


@router.put("", response_model=TrackingPreference)
async def put_tracking(
    req: TrackingUpdate, user_id: CurrentUser, db: Db
) -> TrackingPreference:
    return _with_offerable(await apply_update(db, user_id, req))


async def apply_update(db: SupportsDatabase, user_id: UUID, req: TrackingUpdate) -> TrackingPreference:
    """The one merge of an update onto the latest version: PUT /tracking and the bar's answer
    (decision 71) both land here, so a setting said is the same record as a setting tapped."""
    store = TrackingStore(db)
    current = await store.latest(user_id)
    declined = list(current.declined_offers)
    source = req.source
    if req.decline_offer is not None:
        if req.decline_offer not in declined:
            declined.append(req.decline_offer)
        if req.mode is None and req.focus_metrics is None:
            source = PreferenceSource.DECLINED
    mode = req.mode or current.mode
    focus = req.focus_metrics if req.focus_metrics is not None else current.focus_metrics
    # Decision 66: the level and the frictions ride the same versions. None keeps the latest;
    # an empty frictions list is an answer in its own right ("none of these").
    level = req.nudge_level if req.nudge_level is not None else current.nudge_level
    frictions = req.frictions if req.frictions is not None else current.frictions
    # Decision 69: when the person logs rides the same versions.
    anchor = req.log_anchor if req.log_anchor is not None else current.log_anchor
    # Choosing by hand what was once declined as an offer is the person's own choice: the
    # decline recorded "do not offer", not "never again by my own hand".
    for taken in [offer_key(mode=mode)] + [offer_key(focus=f) for f in focus]:
        if taken in declined:
            declined.remove(taken)
    row = await store.append(
        user_id=user_id,
        mode=mode,
        focus_metrics=focus,
        declined_offers=declined,
        source=source,
        nudge_level=level,
        frictions=frictions,
        log_anchor=anchor,
    )
    return preference_from_row(row)


def _with_offerable(preference: TrackingPreference) -> TrackingPreference:
    preference.offerable_focus = offerable_focus(preference.mode)
    preference.experience = experience_for(preference.nudge_level, preference.frictions, preference.log_anchor)
    return preference
