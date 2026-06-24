"""Request/response schemas for the checkin domain — Phase G (mid-week nudging).

A check-in row captures the user's self-report (weight, hunger, energy,
adherence) plus the engine's computed trend + recalibration recommendation.
These map to the ``checkins`` table (see supabase initial migration): the inputs
land verbatim; ``computed`` / ``recommendation`` hold structured engine output.

The nudge surface (``/nudges/current``) is computed, not stored — it reflects the
user's live logging signals at request time (decision #32, situational nudging).
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field

from .nudge import NudgeTrigger


class CheckinRequest(BaseModel):
    """A user's self-reported weekly/monthly check-in inputs."""

    weight_kg: float | None = Field(default=None, gt=0, le=600)
    hunger: int | None = Field(default=None, ge=1, le=5)
    energy: int | None = Field(default=None, ge=1, le=5)
    adherence_self: int | None = Field(
        default=None, ge=1, le=5, description="Self-rated adherence 1 (none) to 5 (perfect)"
    )
    notes: str | None = Field(default=None, max_length=2000)


class CheckinResponse(BaseModel):
    id: UUID
    weight_kg: float | None = None
    hunger: int | None = None
    energy: int | None = None
    adherence_self: int | None = None
    notes: str | None = None
    created_at: datetime


class CheckinDue(BaseModel):
    """Whether a mid-week check-in/nudge is due, and why."""

    due: bool
    reason: str = Field(description="Human-readable explanation of the due decision")
    days_since_last: int | None = Field(
        default=None, description="Days since the last check-in; null if never"
    )
    is_mid_week: bool = Field(description="True before the week's midpoint (Mon/Tue/Wed)")


class NudgeResponse(BaseModel):
    """The one situational nudge computed for the user from their logging signals."""

    trigger: NudgeTrigger
    message: str
    branch_options: list[str] = Field(default_factory=list)


class RecalTargetsResponse(BaseModel):
    """The recalibrated five-target set (when a recommendation proposes new numbers)."""

    cal_per_kg: float
    target_kcal: int
    protein_g: int
    water_oz: int
    fiber_g: int


class RecommendationResponse(BaseModel):
    """Structured monthly recalibration recommendation (G). Mirrors Recommendation.as_dict()
    plus the protocol it pertains to. ``targets`` is null for HOLD/DIAGNOSTICS branches."""

    protocol_id: str
    kind: str
    optional: bool
    headline: str
    rationale: str
    targets: RecalTargetsResponse | None = None
    diagnostics: list[str] = Field(default_factory=list)
    clamps: list[str] = Field(default_factory=list)
