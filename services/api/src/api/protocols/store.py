"""Durable-truth access for: protocols.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). Methods land in Phase F (intake & protocol).
"""

from ..db import SupportsDatabase


class ProtocolsStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db
