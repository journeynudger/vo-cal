"""Resolution + macro calculation — the deterministic bridge (AGENTS.md #6).

Per parsed item:
  1. Resolve the food: dictionary first (curated, high-confidence), USDA FDC
     second (long tail). A miss on both → ``unresolved`` (zero macros + a
     missing_detail so the user can fix it; never a crash).
  2. Normalize the stated quantity to grams:
       - mass units (g/oz/lb)        → global gram conversion
       - ml                          → entry-specific density (default 1 g/ml)
       - volume/count units          → food-specific unit_conversions
       - null unit + amount (n)      → n × standard serving (modifier math:
                                       "double"→2, "light"→0.5)
       - null amount                 → 1 × standard serving (inferred)
       - raw/cooked factor applied when the item's state differs from the
         dictionary entry's per-100g basis state.
  3. profile.for_grams(grams) → item macros. Meal totals = Σ items.

Resolution metadata (source, match kind/score, grams, basis) rides along for
the confidence scorer (parser/confidence.py) and the admin panel.

This module is pure and synchronous given a resolved profile; the only async is
the optional FDC fallback. The LLM never reaches here.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from ..parser.schemas import ParsedItem, State, Unit
from .dictionary import DictionaryMatch, FoodDictionary, get_dictionary
from .estimator import NutritionEstimator
from .fdc_client import FdcClient
from .schemas import (
    AmountSpecificity,
    Macros,
    MatchKind,
    NutrientProfile,
    ResolutionSource,
)

logger = logging.getLogger(__name__)

# Global mass conversions to grams (food-independent).
_GRAMS_PER_OZ = 28.3495
_GRAMS_PER_LB = 453.592

# Match-quality scores by kind (0..1) — feeds the confidence scorer.
_MATCH_SCORE: dict[MatchKind, float] = {
    MatchKind.CANONICAL: 1.0,
    MatchKind.ALIAS: 0.92,
    MatchKind.PARAMETERIZED: 0.95,
    MatchKind.FAMILY_DEFAULT: 0.7,
    MatchKind.FDC: 0.6,
    MatchKind.ESTIMATED: 0.35,  # low by design — an AI guess, flagged for correction
    MatchKind.NONE: 0.0,
}

# A neutral fallback density for an unknown ml conversion (water-like).
_DEFAULT_ML_DENSITY = 1.0


@dataclass(frozen=True)
class ResolvedItem:
    """One parsed item joined with its deterministic resolution + macros."""

    item: ParsedItem
    source: ResolutionSource
    match_kind: MatchKind
    match_score: float
    grams: float
    macros: Macros
    amount_specificity: AmountSpecificity
    resolved_fat_ratio: str | None = None
    resolved_name: str | None = None  # canonical/FDC name actually used
    # Material-variant axis (decision #29). When the matched food has variant
    # sub-types (whole/fat-free cheddar, regular/light mayo, …), ``variant_family``
    # is the ordered list of variant keys and ``variant_unspecified`` is True when
    # the user did not name one (so the resolver used the documented default). The
    # clarify engine reads these to price the spread across the family.
    variant_family: list[str] | None = None
    variant_unspecified: bool = False
    # Macros for every variant at the resolved grams (decision #29) — the clarify
    # engine prices the spread across these without re-resolving. None when the
    # food has no variant axis.
    variant_macros: dict[str, Macros] | None = None
    resolved_variant: str | None = None  # the chosen variant (when answered)
    # True when macros came from the AI estimator (food not in dictionary/FDC), not a
    # deterministic resolution — the UI flags it and invites a correction (estimator.py).
    is_estimate: bool = False


@dataclass(frozen=True)
class ResolvedMeal:
    items: list[ResolvedItem]
    totals: Macros


def classify_specificity(item: ParsedItem) -> AmountSpecificity:
    """How precisely the user stated the quantity (feeds confidence)."""
    if item.amount is None:
        return AmountSpecificity.INFERRED_SERVING
    if item.unit is None:
        return AmountSpecificity.SERVING_MULTIPLIER
    if item.unit in (Unit.G, Unit.OZ, Unit.LB, Unit.ML):
        return AmountSpecificity.STATED_MASS
    if item.unit in (Unit.CUP, Unit.TBSP, Unit.TSP):
        return AmountSpecificity.STATED_VOLUME
    return AmountSpecificity.STATED_COUNT  # piece / slice / scoop


def to_grams(item: ParsedItem, entry_conversions: dict[str, float], serving_grams: float) -> float:
    """Convert a parsed amount+unit into grams using food-specific conversions.

    `serving_grams` anchors null-unit (serving multiplier) and null-amount cases.
    """
    amount = item.amount

    if amount is None:
        return serving_grams  # one standard serving

    if item.unit is None:
        return amount * serving_grams  # modifier math: amount = multiplier

    unit = item.unit
    if unit is Unit.G:
        return amount
    if unit is Unit.OZ:
        return amount * _GRAMS_PER_OZ
    if unit is Unit.LB:
        return amount * _GRAMS_PER_LB
    if unit is Unit.ML:
        return amount * entry_conversions.get("ml", _DEFAULT_ML_DENSITY)

    # Volume/count units are food-specific. Missing conversion → fall back to a
    # standard serving (better than zero); callers downgrade specificity so the
    # confidence reflects the guess, not the stated volume/count (see _fell_back_to_serving).
    per_unit = entry_conversions.get(unit.value)
    if per_unit is None:
        logger.info("No %s conversion for item %r — using standard serving", unit.value, item.name)
        return amount * serving_grams
    return amount * per_unit


def _fell_back_to_serving(item: ParsedItem, entry_conversions: dict[str, float]) -> bool:
    """True when a STATED volume/count amount had no food-specific conversion, so to_grams used
    the standard-serving guess. The resolved grams are then an inference ("1 serving"), not the
    stated volume/count precision — so the amount specificity (which feeds confidence) must be
    downgraded to INFERRED_SERVING rather than reported as STATED_VOLUME/STATED_COUNT. Mass units
    (g/oz/lb/ml) always convert exactly and never fall back."""
    if item.amount is None or item.unit is None:
        return False
    if item.unit in (Unit.G, Unit.OZ, Unit.LB, Unit.ML):
        return False
    return entry_conversions.get(item.unit.value) is None


def apply_state_factor(
    grams: float, item_state: State, basis_state: str, raw_cooked_factor: float | None
) -> float:
    """Adjust grams when the logged state differs from the profile's basis state.

    The stored factor is grams_cooked = grams_raw × factor. The per-100g profile
    describes `basis_state`. If the user weighed the food in a different state, we
    convert their grams into the basis state before applying the per-100g macros.
    """
    if raw_cooked_factor is None or basis_state == "ready":
        return grams
    if item_state is State.UNSPECIFIED:
        return grams  # assume weighed in the basis state (no question fired here)
    item_basis = item_state.value  # "raw" | "cooked"
    if item_basis == basis_state:
        return grams
    if basis_state == "cooked" and item_basis == "raw":
        return grams * raw_cooked_factor  # raw grams → cooked-equivalent grams
    if basis_state == "raw" and item_basis == "cooked":
        return grams / raw_cooked_factor
    return grams


class Resolver:
    """Resolves parsed items to grams + macros, dictionary-first then FDC."""

    def __init__(
        self,
        dictionary: FoodDictionary | None = None,
        fdc: FdcClient | None = None,
        estimator: NutritionEstimator | None = None,
    ) -> None:
        self._dict = dictionary or get_dictionary()
        self._fdc = fdc
        self._estimator = estimator

    async def resolve_item(self, item: ParsedItem) -> ResolvedItem:
        match = self._dict.lookup(item.name, fat_ratio=item.fat_ratio, variant=item.variant)
        if match is not None:
            return self._from_dictionary(item, match)

        if self._fdc is not None:
            fdc_result = await self._fdc.resolve(item.name)
            if fdc_result is not None:
                return self._from_fdc(item, fdc_result.profile, fdc_result.description)

        # Last resort: a flagged AI estimate beats a silent 0 kcal (estimator.py). Falls back to
        # unresolved when no estimator is configured or the estimate fails — never a crash.
        if self._estimator is not None:
            estimated = await self._estimate(item)
            if estimated is not None:
                return estimated

        return self._unresolved(item)

    async def resolve_meal(self, items: list[ParsedItem]) -> ResolvedMeal:
        resolved = [await self.resolve_item(i) for i in items]
        totals = Macros.zero()
        for r in resolved:
            totals = totals + r.macros
        return ResolvedMeal(items=resolved, totals=totals)

    # -- builders -------------------------------------------------------------

    def _from_dictionary(self, item: ParsedItem, match: DictionaryMatch) -> ResolvedItem:
        entry = match.entry
        grams = to_grams(item, entry.unit_conversions, entry.serving_grams)
        grams = apply_state_factor(grams, item.state, entry.basis_state, entry.raw_cooked_factor)
        # Chosen variant (answered) → its profile; else the default (entry.profile).
        chosen_profile = (
            entry.variants[match.chosen_variant] if match.chosen_variant else entry.profile
        )
        variant_macros = (
            {k: prof.for_grams(grams) for k, prof in entry.variants.items()}
            if entry.variants
            else None
        )
        return ResolvedItem(
            item=item,
            source=ResolutionSource.DICTIONARY,
            match_kind=match.kind,
            match_score=_MATCH_SCORE[match.kind],
            grams=round(grams, 2),
            macros=chosen_profile.for_grams(grams),
            amount_specificity=(
                AmountSpecificity.INFERRED_SERVING
                if _fell_back_to_serving(item, entry.unit_conversions)
                else classify_specificity(item)
            ),
            resolved_fat_ratio=match.resolved_fat_ratio,
            resolved_name=entry.canonical_name,
            variant_family=list(match.variant_keys) or None,
            variant_unspecified=match.variant_unspecified,
            variant_macros=variant_macros,
            resolved_variant=match.chosen_variant,
        )

    def _from_fdc(self, item: ParsedItem, profile: NutrientProfile, name: str) -> ResolvedItem:
        # FDC profiles are per-100g "as reported"; no curated serving size, so a
        # null amount falls back to a conventional 100 g portion.
        serving = 100.0
        grams = to_grams(item, {}, serving)
        return ResolvedItem(
            item=item,
            source=ResolutionSource.FDC,
            match_kind=MatchKind.FDC,
            match_score=_MATCH_SCORE[MatchKind.FDC],
            grams=round(grams, 2),
            macros=profile.for_grams(grams),
            amount_specificity=(
                # FDC has no curated volume/count conversions, so any stated volume/count is a
                # serving guess — never report it as stated precision.
                AmountSpecificity.INFERRED_SERVING
                if _fell_back_to_serving(item, {})
                else classify_specificity(item)
            ),
            resolved_name=name,
        )

    def _unresolved(self, item: ParsedItem) -> ResolvedItem:
        return ResolvedItem(
            item=item,
            source=ResolutionSource.UNRESOLVED,
            match_kind=MatchKind.NONE,
            match_score=0.0,
            grams=0.0,
            macros=Macros.zero(),
            amount_specificity=classify_specificity(item),
            resolved_name=None,
        )

    async def _estimate(self, item: ParsedItem) -> ResolvedItem | None:
        """AI best-guess for a food not in the dictionary/FDC — flagged, low-trust, correctable.

        Returns None if the estimator declines (no key / parse failure / zero estimate), so the
        caller falls back to UNRESOLVED. ESTIMATED carries a low match_score (0.35) → low
        confidence, so the meal flags for review rather than silently trusting the guess.
        """
        result = await self._estimator.estimate(item)
        if result is None:
            return None
        grams, macros = result
        return ResolvedItem(
            item=item,
            source=ResolutionSource.ESTIMATED,
            match_kind=MatchKind.ESTIMATED,
            match_score=_MATCH_SCORE[MatchKind.ESTIMATED],
            grams=grams,
            macros=macros,
            amount_specificity=classify_specificity(item),
            resolved_name=item.name,
            is_estimate=True,
        )
