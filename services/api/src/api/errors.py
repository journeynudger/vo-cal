"""Error types, response models, and exception handlers (adapted from Beacon).

Domain code raises typed ApiError subclasses; the registered handlers convert
them into a consistent {"error": {"code", "message", "details"}} JSON shape.
"""

import logging

from fastapi import FastAPI, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel

logger = logging.getLogger(__name__)


class ErrorDetail(BaseModel):
    """Details about an API error."""

    code: str
    message: str
    details: dict = {}


class ErrorResponse(BaseModel):
    """Standard error response wrapper."""

    error: ErrorDetail


class ApiError(Exception):
    """Base for typed domain errors carrying an HTTP status + stable error code."""

    status_code: int = status.HTTP_500_INTERNAL_SERVER_ERROR
    code: str = "internal_error"

    def __init__(self, message: str, details: dict | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.details = details or {}


class NotFoundError(ApiError):
    status_code = status.HTTP_404_NOT_FOUND
    code = "not_found"


class ConflictError(ApiError):
    status_code = status.HTTP_409_CONFLICT
    code = "conflict"


class AuthError(ApiError):
    status_code = status.HTTP_401_UNAUTHORIZED
    code = "unauthorized"


class ForbiddenError(ApiError):
    status_code = status.HTTP_403_FORBIDDEN
    code = "forbidden"


def register_error_handlers(app: FastAPI) -> None:
    """Attach exception handlers to the app (called by the app factory)."""

    @app.exception_handler(ApiError)
    async def api_error_handler(_request: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content=ErrorResponse(
                error=ErrorDetail(code=exc.code, message=exc.message, details=exc.details)
            ).model_dump(),
        )

    @app.exception_handler(RequestValidationError)
    async def validation_exception_handler(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        """Log validation errors with request body for debugging."""
        body = await request.body()
        logger.warning(
            "Validation error on %s: %s",
            request.url.path,
            exc.errors(),
            extra={"path": request.url.path, "body": body.decode("utf-8", errors="replace")},
        )
        return JSONResponse(
            status_code=422,
            content={"detail": jsonable_encoder(exc.errors())},
        )
