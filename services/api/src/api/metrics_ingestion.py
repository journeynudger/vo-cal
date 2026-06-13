"""Client metrics ingestion — accepts batched events from the iOS client.

Phase D's log-duration events land here. Events are durably stored in the
``client_metrics`` table (via the Database seam) and mirrored into Prometheus.

Privacy rule (AGENTS.md MUST NOT #5): events carry durations, counts, and
confidence values only — never phone numbers or precise health values.
"""

from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, Field

from .db import SupportsDatabase
from .dependencies import get_current_user, get_db
from .metrics import CLIENT_EVENTS, LOG_DURATION

router = APIRouter(prefix="/metrics", tags=["metrics"])

# Event names with a dedicated pre-registered Prometheus instrument.
# Everything else lands in the CLIENT_EVENTS catch-all counter.
_HISTOGRAMS = {
    "log_duration_ms": LOG_DURATION,
}


class ClientMetricEvent(BaseModel):
    name: str = Field(..., min_length=1, max_length=64)
    value: float
    attributes: dict[str, str] = Field(default_factory=dict)
    ts: datetime


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
            CLIENT_EVENTS.labels(name=event.name).inc()

    return {"accepted": accepted}
