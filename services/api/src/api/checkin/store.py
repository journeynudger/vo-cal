"""Durable-truth access for: checkins.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). Methods land in Phase G (weekly check-in).
"""

from ..db import SupportsDatabase


class CheckinStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db
