"""Durable-truth access for: food_dictionary, usda_cache.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings). Methods land in Phase B (parser & nutrition).
"""

from ..db import SupportsDatabase


class NutritionStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db
