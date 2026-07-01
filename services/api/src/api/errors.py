"""Exception handlers (adapted from Beacon).

Only the sanitized 422 handler is live: every router raises ``fastapi.HTTPException``
directly, so the typed ``ApiError`` hierarchy + its handler that once lived here were
dead (no router ever raised one). Removed rather than left as a false affordance.
"""

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

logger = logging.getLogger(__name__)


def register_error_handlers(app: FastAPI) -> None:
    """Attach exception handlers to the app (called by the app factory)."""

    @app.exception_handler(RequestValidationError)
    async def validation_exception_handler(
        _request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        """Sanitized 422 — surface only loc/msg/type, never the raw input.

        The raw ``input`` (and ``ctx``) echoes the caller's payload, which can be PII
        (weights, intake answers, macros — MUST NOT #5) AND non-JSON-serializable (inf/nan,
        e.g. a poisoned Macros value), which previously crashed the 422 into a 500. For the
        same PII reason we no longer log the request body — only the field locations + types.
        """
        safe_errors = [
            {"loc": list(e.get("loc", ())), "msg": str(e.get("msg", "")), "type": str(e.get("type", ""))}
            for e in exc.errors()
        ]
        logger.warning(
            "Validation error on %s: %s",
            _request.url.path,
            [{"loc": e["loc"], "type": e["type"]} for e in safe_errors],
            extra={"path": _request.url.path},
        )
        return JSONResponse(status_code=422, content={"detail": safe_errors})
