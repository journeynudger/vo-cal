"""Prometheus metric definitions and /metrics endpoint (adapted from Beacon).

Domain metrics are pre-registered here even though their emitters land in later
phases (B parser, D voice-log loop) — a single registration site avoids the
prometheus_client duplicate-registration error and keeps naming in one place.
"""

import hmac

from fastapi import APIRouter, HTTPException, Request, Response, status
from prometheus_client import Counter, Histogram, generate_latest
from prometheus_client.exposition import CONTENT_TYPE_LATEST

from .config import settings

# --- Server-side HTTP metrics ---

REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    labelnames=["method", "endpoint", "status"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    labelnames=["method", "endpoint", "status"],
)

DB_QUERY_DURATION = Histogram(
    "db_query_duration_seconds",
    "Database query duration in seconds",
    labelnames=["operation", "table"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5),
)

# --- Domain metrics (emitters wired in Phases B-D) ---

PARSE_LATENCY = Histogram(
    "parse_latency_seconds",
    "Transcript → parse contract latency (LLM call included)",
    labelnames=["model"],
    buckets=(0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 8.0, 13.0, 21.0),
)

QUESTION_ASKED = Counter(
    "question_asked_total",
    "Clarifying questions asked after a parse",
    labelnames=["field"],
)

CORRECTIONS = Counter(
    "corrections_total",
    "User corrections to parsed meal items",
    labelnames=["field"],
)

# Client-reported speak→logged duration (ingested via /metrics/client).
LOG_DURATION = Histogram(
    "log_duration_ms",
    "Client-reported end-to-end meal log duration in milliseconds",
    buckets=(500, 1000, 2000, 3000, 5000, 8000, 13000, 21000, 34000),
)

# Catch-all for client events that have no dedicated histogram/counter above.
CLIENT_EVENTS = Counter(
    "client_events_total",
    "Client-reported metric events by name",
    labelnames=["name"],
)

# --- Endpoint ---

metrics_router = APIRouter(tags=["system"])


@metrics_router.get("/metrics", include_in_schema=False)
async def prometheus_metrics(request: Request) -> Response:
    """Prometheus scrape endpoint — private-scrape open, public-edge gated.

    Fly's managed Prometheus scrapes the machine DIRECTLY over the private 6PN
    network (fly.toml [metrics]); those requests never pass the edge proxy and
    cannot carry auth headers, so they must stay tokenless. Every request that
    arrives through the public edge is stamped with ``Fly-Client-IP`` by the
    proxy — that stamp is the gate: edge-proxied scrapes need the METRICS_TOKEN
    bearer (unset = refused outright). Before this, request-rate/latency/
    correction-count internals were world-readable (deferred item from #18).
    Failure mode if Fly ever renames the header: the gate fails OPEN (back to
    world-readable, no outage) — revisit on any Fly proxy migration.
    """
    if request.headers.get("fly-client-ip"):
        auth = request.headers.get("authorization", "")
        expected = f"Bearer {settings.metrics_token}"
        if not settings.metrics_token or not hmac.compare_digest(auth, expected):
            raise HTTPException(status.HTTP_403_FORBIDDEN, "metrics restricted")
    return Response(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST,
    )
