"""Pydantic request/response schemas for the intake domain — Phase F (intake & protocol)."""

from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel

from ..protocols.schemas import IntakeProfile


class SaveIntakeRequest(BaseModel):
    """Persist a completed intake. Reuses IntakeProfile (the protocol engine's input) so the
    stored answers are exactly what generated the protocol."""

    intake: IntakeProfile


class IntakeRecord(BaseModel):
    """A persisted, versioned intake row."""

    intake_id: UUID
    version: int
    intake: IntakeProfile
