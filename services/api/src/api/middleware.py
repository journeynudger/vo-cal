"""Observability middleware — request timing, correlation IDs, structured access log.

Adapted from Beacon's ObservabilityMiddleware (pure ASGI, no BaseHTTPMiddleware —
BaseHTTPMiddleware buffers streaming responses and breaks contextvars propagation).
"""

import base64
import json
import logging
import re
import time
import uuid

from starlette.types import ASGIApp, Message, Receive, Scope, Send

from .logging_config import request_id_var, user_id_var
from .metrics import REQUEST_COUNT, REQUEST_DURATION

logger = logging.getLogger(__name__)

# Regex to replace UUID path segments with {id} for low-cardinality metric labels
_UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)


def _normalize_path(path: str) -> str:
    """Replace UUID segments with {id} to keep metric labels finite."""
    return _UUID_RE.sub("{id}", path)


def _extract_user_id_from_header(scope: Scope) -> str:
    """Best-effort user_id extraction from Authorization header (no validation).

    Used only for log correlation — auth is enforced by the dependency layer.
    """
    headers = dict(scope.get("headers", []))
    auth = headers.get(b"authorization", b"").decode("utf-8", errors="ignore")
    if not auth.startswith("Bearer "):
        return "-"
    token = auth[7:]
    try:
        # JWT has 3 parts: header.payload.signature — decode the payload
        payload_b64 = token.split(".")[1]
        padded = payload_b64 + "=" * (4 - len(payload_b64) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded))
        return payload.get("sub", "-")
    except Exception:
        return "-"


class ObservabilityMiddleware:
    """Pure ASGI middleware for request timing, correlation IDs, and logging."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        request_id = uuid.uuid4().hex[:12]
        rid_token = request_id_var.set(request_id)

        user_id = _extract_user_id_from_header(scope)
        uid_token = user_id_var.set(user_id)

        method = scope.get("method", "")
        path = scope.get("path", "")
        start = time.perf_counter()
        status_code = 500  # default if we never see a response

        async def send_wrapper(message: Message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = message["status"]
                # Inject X-Request-ID header
                headers = list(message.get("headers", []))
                headers.append((b"x-request-id", request_id.encode()))
                message["headers"] = headers
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            duration_ms = (time.perf_counter() - start) * 1000
            normalized = _normalize_path(path)

            # Skip logging /metrics scrapes to reduce noise
            if path != "/metrics":
                logger.info(
                    "%s %s %d %.1fms",
                    method,
                    path,
                    status_code,
                    duration_ms,
                    extra={
                        "method": method,
                        "path": normalized,
                        "status": status_code,
                        "duration_ms": round(duration_ms, 2),
                    },
                )

            # Record Prometheus metrics
            duration_s = duration_ms / 1000
            REQUEST_DURATION.labels(
                method=method, endpoint=normalized, status=str(status_code)
            ).observe(duration_s)
            REQUEST_COUNT.labels(method=method, endpoint=normalized, status=str(status_code)).inc()

            request_id_var.reset(rid_token)
            user_id_var.reset(uid_token)
