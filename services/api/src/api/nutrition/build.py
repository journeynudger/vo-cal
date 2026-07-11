"""Single construction site for the nutrition ``Resolver``.

Both the parse-preview path and the meal-confirm path now estimate unknowns
(``estimate_unknowns=True``): bug-6's product rule is that an obvious food never shows
0 kcal in the preview, so the preview gained the same flagged, low-confidence estimate
the confirm path always had. The flag stays as an explicit axis (rather than hardcoding
True) so any future divergence is a visible one-line decision here — not a silent drift
between routers. That drift is the bug this module replaced: ``meals/router`` once
claimed "same construction as the parse path" while silently adding an estimator.
"""

from __future__ import annotations

from ..config import settings
from ..db import SupportsDatabase
from .estimator import make_estimator
from .fdc_client import FdcClient
from .resolver import Resolver


def build_resolver(db: SupportsDatabase, *, estimate_unknowns: bool) -> Resolver:
    """Resolver: AI-first for branded items, dictionary-first otherwise; FDC long-tail when a
    key is configured; a flagged AI estimate for the remaining unknowns when
    ``estimate_unknowns``. The estimator is wrapped in the durable usda_cache-backed cache so
    the same food identity always prices identically (and is paid for once)."""
    fdc = FdcClient(db) if settings.usda_fdc_api_key else None
    estimator = make_estimator(settings.anthropic_api_key, db) if estimate_unknowns else None
    return Resolver(fdc=fdc, estimator=estimator)
