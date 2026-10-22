"""Exception handlers (adapted from Beacon).

The sanitized 422 handler, and the 409 for a versioned write that lost every race (routers
otherwise raise ``fastapi.HTTPException`` directly; the typed ``ApiError`` hierarchy + its
handler that once lived here were dead and were removed rather than left as a false affordance).
"""

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .db import VersionRaceLostError

logger = logging.getLogger(__name__)


def register_error_handlers(app: FastAPI) -> None:
    """Attach exception handlers to the app (called by the app factory)."""

    @app.exception_handler(VersionRaceLostError)
    async def version_race_handler(_request: Request, exc: VersionRaceLostError) -> JSONResponse:
        """A burst of concurrent writes for one person took every next version first. Raised by
        stores (PUT /tracking, the bar's changes, PUT /meals/plan), so it maps here once rather
        than at each caller; nothing of the losing write was stored."""
        logger.warning("version race lost on %s", exc.table, extra={"path": _request.url.path})
        return JSONResponse(
            status_code=409, content={"detail": "This changed somewhere else at the same moment. Try again."}
        )

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
