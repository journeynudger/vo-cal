"""Single construction site for the nutrition ``Resolver``.

The parse-preview path and the meal-confirm path deliberately differ on ONE axis and
nothing else: confirm estimates unknown foods (so a logged meal never silently shows
0 kcal), while preview leaves them ``UNRESOLVED`` plus a ``missing_detail`` — an honest
"I don't know this" the user can fix, with no paid LLM estimate burned on a parse they
may abandon. Both share dictionary-first + FDC-long-tail resolution.

Kept here, not in either router, so the two paths cannot drift. The bug this replaced:
``meals/router._build_resolver`` carried a comment claiming "Same construction as the
parse path" while silently adding the estimator the parse path omits.
"""

from __future__ import annotations

from ..config import settings
from ..db import SupportsDatabase
from .estimator import make_estimator
from .fdc_client import FdcClient
from .resolver import Resolver


def build_resolver(db: SupportsDatabase, *, estimate_unknowns: bool) -> Resolver:
    """Dictionary-first resolver. FDC long-tail only when a key is configured; an AI
    estimate for the remaining unknowns only when ``estimate_unknowns`` (the confirm path)."""
    fdc = FdcClient(db) if settings.usda_fdc_api_key else None
    estimator = make_estimator(settings.anthropic_api_key) if estimate_unknowns else None
    return Resolver(fdc=fdc, estimator=estimator)
