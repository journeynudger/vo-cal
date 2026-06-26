"""Client metrics ingestion — accepts batched events from the iOS client.

Phase D's log-duration events land here. Events are durably stored in the
``client_metrics`` table (via the Database seam) and mirrored into Prometheus.

Privacy rule (AGENTS.md MUST NOT #5): events carry durations, counts, and
confidence values only — never phone numbers or precise health values.
"""

from collections.abc import Callable
from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, Field, field_validator

from .db import SupportsDatabase
from .dependencies import get_current_user, get_db
from .metrics import CLIENT_EVENTS, LOG_DURATION
from .parser.schemas import MealType

router = APIRouter(prefix="/metrics", tags=["metrics"])

# Event names with a dedicated pre-registered Prometheus instrument.
# Everything else lands in the CLIENT_EVENTS catch-all counter.
_HISTOGRAMS = {
    "log_duration_ms": LOG_DURATION,
}

# Server-owned allowlist of recognized client event names — the Phase D/F telemetry
# vocabulary (.claude/plans). The Prometheus label is drawn ONLY from this set; any other
# (client-controlled) name collapses to "other" so a client cannot explode label
# cardinality (C4). Storage keeps the raw name (bounded to 64 chars) for offline analysis.
_ALLOWED_EVENT_NAMES: frozenset[str] = frozenset({
    "log_duration_ms",
    "capture_to_transcript_ms",
    "transcript_to_parse_ms",
    "question_asked",
    "question_answered",
    "question_skipped",
    "corrections_count",
    "parse_confidence",
    "intake_started",
    "intake_step_completed",
    "intake_completed",
    "protocol_generated",
    "protocol_viewed",
    "tutorial_completed",
    "first_log_started",
    "outbox_retry",
})
_OTHER_EVENT_LABEL = "other"


def _is_uuid(value: str) -> bool:
    try:
        UUID(value)
    except ValueError:
        return False
    return True


_MEAL_TYPES: frozenset[str] = frozenset(meal_type.value for meal_type in MealType)

# Server-owned allowlist of attribute keys + a validator per key. Every other key is
# dropped, and an allowlisted key is dropped unless its value passes the validator, so a
# client can't ship PII (weights, phone) into durable telemetry or the admin chain
# (MUST NOT #5, C1). meal_log_id/meal_id are the UUIDs the admin metrics-correlation reads
# (admin/store.py); meal_type is a low-cardinality enum tag. Each value must be bounded —
# a UUID or a known enum member — so nothing free-form rides in under an allowed key.
_ATTRIBUTE_VALIDATORS: dict[str, Callable[[str], bool]] = {
    "meal_log_id": _is_uuid,
    "meal_id": _is_uuid,
    "meal_type": _MEAL_TYPES.__contains__,
}


def _event_label(name: str) -> str:
    """The bounded Prometheus label for an event name (allowlist-or-'other')."""
    return name if name in _ALLOWED_EVENT_NAMES else _OTHER_EVENT_LABEL


def _sanitize_attributes(attributes: dict[str, str]) -> dict[str, str]:
    clean: dict[str, str] = {}
    for key, value in attributes.items():
        validator = _ATTRIBUTE_VALIDATORS.get(key)
        if validator is not None and isinstance(value, str) and validator(value):
            clean[key] = value
    return clean


class ClientMetricEvent(BaseModel):
    name: str = Field(..., min_length=1, max_length=64)
    value: float
    attributes: dict[str, str] = Field(default_factory=dict)
    ts: datetime

    @field_validator("attributes")
    @classmethod
    def _allowlist_attributes(cls, value: dict[str, str]) -> dict[str, str]:
        # Sanitize at the boundary so the cleaned dict is what flows to storage AND any
        # consumer — never the raw client dict (parse, don't repeatedly validate).
        return _sanitize_attributes(value)


class ClientMetricsBatch(BaseModel):
    events: list[ClientMetricEvent] = Field(..., max_length=100)


class MetricsStore:
    """Persists client events through the Database seam."""

    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def record(self, user_id: UUID, events: list[ClientMetricEvent]) -> int:
        for event in events:
            await self._db.insert(
                "client_metrics",
                {
                    "user_id": str(user_id),
                    "name": event.name,
                    "value": event.value,
                    "attributes": event.attributes,
                    "ts": event.ts.isoformat(),
                },
            )
        return len(events)


def get_metrics_store(db: Annotated[SupportsDatabase, Depends(get_db)]) -> MetricsStore:
    return MetricsStore(db)


@router.post("/client", status_code=status.HTTP_202_ACCEPTED)
async def ingest_client_metrics(
    batch: ClientMetricsBatch,
    user_id: Annotated[UUID, Depends(get_current_user)],
    store: Annotated[MetricsStore, Depends(get_metrics_store)],
) -> dict:
    """Accept batched client events: store durably, mirror into Prometheus."""
    accepted = await store.record(user_id, batch.events)

    for event in batch.events:
        histogram = _HISTOGRAMS.get(event.name)
        if histogram is not None:
            histogram.observe(event.value)
        else:
            CLIENT_EVENTS.labels(name=_event_label(event.name)).inc()

    return {"accepted": accepted}
