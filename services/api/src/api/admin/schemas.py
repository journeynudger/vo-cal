"""Pydantic request/response schemas for the admin domain — Phase H (admin review).

The detail/aggregate payloads carry already-assembled jsonb (parse payload,
corrections diff, metrics) so the reviewer sees the raw audit material; the
schemas keep the wire contract explicit without re-validating every nested field.
"""

from __future__ import annotations

from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


class Verdict(str, Enum):
    """Fixed verdict taxonomy (decision #21) — aggregatable, feeds parser iteration."""

    PARSE_OK = "parse_ok"
    PARSE_WRONG_ITEM = "parse_wrong_item"
    PARSE_WRONG_AMOUNT = "parse_wrong_amount"
    RESOLUTION_WRONG_FOOD = "resolution_wrong_food"
    QUESTION_SHOULD_HAVE_FIRED = "question_should_have_fired"
    QUESTION_UNNECESSARY = "question_unnecessary"
    TRANSCRIPT_WRONG = "transcript_wrong"


class LogSummary(BaseModel):
    """One row in the review queue (GET /admin/logs)."""

    id: str
    user_id: str | None
    name: str | None
    meal_type: str | None
    logged_at: str
    confidence: float
    corrections_count: int
    question_asked: bool
    item_count: int


class LogChain(BaseModel):
    """Full audit chain for one meal_log (GET /admin/logs/{id})."""

    meal_log_id: str
    user_id: str | None
    name: str | None
    meal_type: str | None
    logged_at: str
    confidence: float
    confirmed_items: list[dict[str, Any]]
    totals: dict[str, Any]
    parse_id: str | None
    parse_payload: dict[str, Any]
    parse_result: dict[str, Any]
    parsed_meal: dict[str, Any]
    questions: list[dict[str, Any]]
    corrections: list[dict[str, Any]]
    capture_id: str | None
    audio_path: str | None
    signed_audio_url: str | None = Field(
        default=None, description="Short-TTL signed URL for the capture audio (Storage seam)"
    )
    metrics: list[dict[str, Any]]


class ReviewRequest(BaseModel):
    verdict: Verdict
    notes: str | None = Field(default=None, max_length=4000)


class ReviewResponse(BaseModel):
    id: str
    meal_log_id: str
    reviewer: str
    verdict: Verdict
    notes: str | None


class Aggregates(BaseModel):
    """Parser-iteration evidence (GET /admin/aggregates)."""

    correction_rate_by_week: list[dict[str, Any]]
    confidence_calibration: list[dict[str, Any]]
    question_precision: dict[str, Any]
    top_corrected_foods: list[dict[str, Any]]
