"""Admin review routes — Phase H (admin review), CLI+endpoints flavor (#25).

Every route is gated by ``require_admin`` (server-side email allowlist; the
service-role key never leaves the API). Auditability is non-negotiable (#7):
the detail route writes an ``admin_audit_log`` row BEFORE assembling the chain
or minting a signed audio URL, so an access is recorded even if assembly fails.
"""

from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, HTTPException, Query, status

from ..dependencies import AdminUser, Db, Storage
from ..storage import CAPTURE_AUDIO_BUCKET
from .schemas import Aggregates, LogChain, LogSummary, ReviewRequest, ReviewResponse
from .store import AdminStore

router = APIRouter(prefix="/admin", tags=["admin"])

# Audio URLs are minted just-in-time for one review; a short TTL bounds the
# exposure window of a sensitive recording (decision #21, exit criteria).
_AUDIO_URL_TTL_SECONDS = 300


def _parse_dt(value: str | None) -> datetime | None:
    if value is None:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "date filters must be ISO-8601",
        ) from exc


@router.get("/logs", response_model=list[LogSummary])
async def list_logs(
    admin: AdminUser,
    db: Db,
    low_confidence: bool = Query(False),
    has_corrections: bool = Query(False),
    question_asked: bool | None = Query(None),
    user_id: str | None = Query(None),
    start: str | None = Query(None, description="ISO-8601; logged_at >= start"),
    end: str | None = Query(None, description="ISO-8601; logged_at < end"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> list[LogSummary]:
    del admin  # gate only; the queue list is non-identifying summaries, not audited
    rows = await AdminStore(db).list_logs(
        low_confidence=low_confidence,
        has_corrections=has_corrections,
        question_asked=question_asked,
        user_id=user_id,
        start=_parse_dt(start),
        end=_parse_dt(end),
        limit=limit,
        offset=offset,
    )
    return [LogSummary(**r) for r in rows]


@router.get("/logs/{meal_log_id}", response_model=LogChain)
async def get_log(meal_log_id: str, admin: AdminUser, db: Db, storage: Storage) -> LogChain:
    store = AdminStore(db)

    # Audit FIRST: a detail read of a user's food diary + audio is sensitive, so
    # the access is recorded before any data is assembled or any URL is minted.
    await store.write_audit(
        admin_email=admin,
        action="read_log_chain",
        subject_type="meal_log",
        subject_id=meal_log_id,
    )

    chain = await store.get_log_chain(meal_log_id)
    if chain is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "meal log not found")

    signed_url: str | None = None
    if chain.get("audio_path"):
        signed_url = await storage.signed_url(
            CAPTURE_AUDIO_BUCKET, chain["audio_path"], ttl_seconds=_AUDIO_URL_TTL_SECONDS
        )

    return LogChain(**chain, signed_audio_url=signed_url)


@router.post("/logs/{meal_log_id}/review", response_model=ReviewResponse, status_code=201)
async def review_log(
    meal_log_id: str, req: ReviewRequest, admin: AdminUser, db: Db
) -> ReviewResponse:
    store = AdminStore(db)

    # The meal must exist before a verdict is recorded against it.
    chain = await store.get_log_chain(meal_log_id)
    if chain is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "meal log not found")

    row = await store.insert_review(
        meal_log_id=meal_log_id,
        reviewer=admin,
        verdict=req.verdict.value,
        notes=req.notes,
    )
    await store.write_audit(
        admin_email=admin,
        action="insert_review",
        subject_type="meal_log",
        subject_id=meal_log_id,
    )
    return ReviewResponse(
        id=row["id"],
        meal_log_id=row["meal_log_id"],
        reviewer=row["reviewer"],
        verdict=req.verdict,
        notes=row.get("notes"),
    )


@router.get("/aggregates", response_model=Aggregates)
async def aggregates(admin: AdminUser, db: Db) -> Aggregates:
    del admin  # gate only; aggregates are non-identifying rollups, not audited
    return Aggregates(**await AdminStore(db).aggregates())
