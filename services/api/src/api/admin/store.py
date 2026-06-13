"""Durable-truth access for: admin_reviews, admin_audit_log.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). Methods land in Phase H (admin review).
"""

from ..db import SupportsDatabase


class AdminStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db
