"""GET /tracking, PUT /tracking: the person's way of following their nutrition.

Orchestration only: the store holds the versions, the schemas the vocabulary. PUT appends a
version merged with the latest, so the client changes one thing at a time; a decline joins the
list of modes never to be offered again (decision 62).
"""

from __future__ import annotations

from fastapi import APIRouter

from ..dependencies import CurrentUser, Db
from .schemas import PreferenceSource, TrackingPreference, TrackingUpdate, offer_key
from .store import TrackingStore, preference_from_row

router = APIRouter(prefix="/tracking", tags=["tracking"])


@router.get("", response_model=TrackingPreference)
async def get_tracking(user_id: CurrentUser, db: Db) -> TrackingPreference:
    return await TrackingStore(db).latest(user_id)


@router.put("", response_model=TrackingPreference)
async def put_tracking(
    req: TrackingUpdate, user_id: CurrentUser, db: Db
) -> TrackingPreference:
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
    )
    return preference_from_row(row)
