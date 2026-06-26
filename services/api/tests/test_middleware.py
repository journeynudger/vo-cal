"""Access-log identity (C3).

The observability middleware decoded the JWT ``sub`` WITHOUT verifying the signature
and logged it as ``user_id`` — so a forged token put an attacker-controlled id into the
audit trail. The middleware must trust only the *verified* identity established by the
auth dependency: forged/anonymous → "-", authenticated → the verified id.
"""

from __future__ import annotations

import base64
import json
import logging

from api.logging_config import JsonFormatter


def _forged_jwt(sub: str) -> str:
    """A syntactically valid JWT with attacker-chosen sub and a bogus signature."""
    def seg(d: dict) -> str:
        return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()

    return f"{seg({'alg': 'HS256', 'typ': 'JWT'})}.{seg({'sub': sub})}.not-a-real-signature"


class _Capture(logging.Handler):
    """Captures the *formatted* JSON line (so user_id_var is read at emit time)."""

    def __init__(self) -> None:
        super().__init__()
        self.lines: list[dict] = []
        self.setFormatter(JsonFormatter())

    def emit(self, record: logging.LogRecord) -> None:
        self.lines.append(json.loads(self.format(record)))


def _capture_access_log():
    handler = _Capture()
    logger = logging.getLogger("api.middleware")
    logger.addHandler(handler)
    return logger, handler


def test_forged_token_sub_is_not_logged(client):
    # /health needs no auth, so get_current_user never runs: a forged Bearer must NOT
    # leak its sub into the access log — user_id stays "-".
    logger, handler = _capture_access_log()
    try:
        client.get("/health", headers={"Authorization": f"Bearer {_forged_jwt('attacker-controlled')}"})
    finally:
        logger.removeHandler(handler)

    line = next(line for line in handler.lines if line.get("path") == "/health")
    assert line["user_id"] == "-"  # never the forged sub


def test_access_log_uses_verified_user(client, auth_headers, test_user_id):
    # An authenticated request logs the VERIFIED id (set by the auth dependency), so we
    # keep log correlation without ever trusting the raw token.
    logger, handler = _capture_access_log()
    try:
        client.get("/meals/today?date=2026-06-26", headers=auth_headers)
    finally:
        logger.removeHandler(handler)

    line = next(line for line in handler.lines if line.get("path", "").startswith("/meals/today"))
    assert line["user_id"] == str(test_user_id)
