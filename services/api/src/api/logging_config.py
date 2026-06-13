"""Structured JSON logging configuration (adapted from Beacon)."""

import json
import logging
import sys
from contextvars import ContextVar
from datetime import UTC, datetime

# Per-request context variables — set by middleware, read by formatter
request_id_var: ContextVar[str] = ContextVar("request_id", default="-")
user_id_var: ContextVar[str] = ContextVar("user_id", default="-")


class JsonFormatter(logging.Formatter):
    """Outputs log records as single-line JSON."""

    def format(self, record: logging.LogRecord) -> str:
        log = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        # Add context vars
        log["request_id"] = request_id_var.get("-")
        log["user_id"] = user_id_var.get("-")

        # Add any extras passed via logger.info("msg", extra={...})
        for key in ("method", "path", "status", "duration_ms"):
            if hasattr(record, key):
                log[key] = getattr(record, key)

        # Include exception info if present
        if record.exc_info and record.exc_info[0] is not None:
            log["exception"] = self.formatException(record.exc_info)

        return json.dumps(log, default=str)


def setup_logging(*, debug: bool = False) -> None:
    """Configure root logger with JSON output to stdout."""
    root = logging.getLogger()
    root.setLevel(logging.DEBUG if debug else logging.INFO)

    # Clear existing handlers to avoid duplicates on reload
    root.handlers.clear()

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root.addHandler(handler)

    # Suppress noisy loggers
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("hpack").setLevel(logging.WARNING)
