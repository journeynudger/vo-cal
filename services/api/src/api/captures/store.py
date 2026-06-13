"""Durable-truth access for: captures, transcripts.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). Methods land in Phases C-D (voice port & log loop).
"""

from ..db import SupportsDatabase


class CapturesStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db
