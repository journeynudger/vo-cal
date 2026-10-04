"""GET /tracking, PUT /tracking: the person's way of following their nutrition.

Orchestration only: the store holds the versions, the schemas the vocabulary. PUT appends a
version merged with the latest, so the client changes one thing at a time; a decline joins the
list of modes never to be offered again (decision 62).
"""

from __future__ import annotations

from fastapi import APIRouter

from ..dependencies import CurrentUser, Db
from .schemas import PreferenceSource, TrackingPreference, TrackingUpdate
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
    declined = list(current.declined_modes)
    source = req.source
    if req.decline_mode is not None:
        if req.decline_mode not in declined:
            declined.append(req.decline_mode)
        if req.mode is None and req.focus_metrics is None:
            source = PreferenceSource.DECLINED
    mode = req.mode or current.mode
    # Choosing a mode the person once declined an invitation to is their own choice: the
    # decline recorded "do not offer", not "never again by my own hand".
    if req.mode is not None and req.mode in declined:
        declined.remove(req.mode)
    row = await store.append(
        user_id=user_id,
        mode=mode,
        focus_metrics=req.focus_metrics if req.focus_metrics is not None else current.focus_metrics,
        declined_modes=declined,
        source=source,
    )
    return preference_from_row(row)
