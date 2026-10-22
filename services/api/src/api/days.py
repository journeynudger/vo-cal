"""A day the client names (``?date=YYYY-MM-DD``), parsed once for every router.

The window is wide on purpose: it exists to keep the day arithmetic (a week's Monday, the next
midnight, a zone's offset) inside what ``datetime`` can hold, never to judge which day a person
may ask about. ``0001-01-01`` and ``9999-12-31`` parsed, and the arithmetic past them raised an
OverflowError the API answered as a 500 (2026-10-22 audit). A phone on a non-Gregorian calendar
sends its own year (a Buddhist-calendar iPhone writes 2569); that day stays readable here and is
the client's bug to fix, so no build that sends it starts failing.
"""

from __future__ import annotations

import re
from datetime import date

from fastapi import HTTPException, status

FIRST_DAY = date(1900, 1, 1)
LAST_DAY = date(2999, 12, 31)
# The one shape the API takes; ``date.fromisoformat`` alone also reads "20261022" and week dates.
_DAY = re.compile(r"\d{4}-\d{2}-\d{2}")


def parse_day(value: str) -> date:
    """A calendar day with no zone: the caller localizes it (combine(..., tzinfo=zone))."""
    try:
        if not _DAY.fullmatch(value):
            raise ValueError(value)
        day = date.fromisoformat(value)
    except ValueError as exc:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "date must be YYYY-MM-DD") from exc
    if not FIRST_DAY <= day <= LAST_DAY:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            f"date must be between {FIRST_DAY.isoformat()} and {LAST_DAY.isoformat()}",
        )
    return day
