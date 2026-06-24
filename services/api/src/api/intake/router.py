"""Intake routes (Phase F2) — persist the deep intake as a versioned, append-only record.

POST /intake stores the completed intake (the same IntakeProfile that feeds
/protocols/generate) so the answers are durable and auditable, not just transient input
to protocol math. GET /intake/latest powers resume + an "already onboarded?" check.
Orchestration only; the store owns durability (AGENTS.md deep couplings).
"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, status

from ..dependencies import CurrentUser, Db
from ..protocols.schemas import IntakeProfile
from .schemas import IntakeRecord, SaveIntakeRequest
from .store import IntakeStore

router = APIRouter(prefix="/intake", tags=["intake"])


@router.post("", response_model=IntakeRecord, status_code=status.HTTP_201_CREATED)
async def save_intake(req: SaveIntakeRequest, user_id: CurrentUser, db: Db) -> IntakeRecord:
    row = await IntakeStore(db).insert(user_id=user_id, answers=req.intake.model_dump(mode="json"))
    return IntakeRecord(intake_id=row["id"], version=int(row["version"]), intake=req.intake)


@router.get("/latest", response_model=IntakeRecord)
async def latest_intake(user_id: CurrentUser, db: Db) -> IntakeRecord:
    row = await IntakeStore(db).latest(user_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no intake on file")
    return IntakeRecord(
        intake_id=row["id"],
        version=int(row["version"]),
        intake=IntakeProfile.model_validate(row["answers"]),
    )
