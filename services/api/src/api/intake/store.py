"""Durable-truth access for: intake_responses.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). Methods land in Phase F (intake & protocol).
"""

from ..db import SupportsDatabase


class IntakeStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db
