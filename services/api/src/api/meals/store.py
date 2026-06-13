"""Durable-truth access for: meal_logs, corrections, saved_meals.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). Methods land in Phase D (voice log loop).
"""

from ..db import SupportsDatabase


class MealsStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db
