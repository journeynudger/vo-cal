"""Resolution + macro calculation — the deterministic bridge (AGENTS.md #6).

Per parsed item:
  1. Resolve the food: branded items AI-first (the model knows the label), then
     dictionary (curated, high-confidence), then the estimator for amounts FDC
     can't price, then USDA FDC (long tail, mass-stated amounts ONLY — its
     per-100g rows can't price a count or a bare mention without guessing),
     then a last-resort estimate. A miss everywhere → ``unresolved`` (zero
     macros + a missing_detail so the user can fix it; never a crash).
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

# A BRANDED estimate is an informed label read (the user named the product; the model
# knows its label), not a blind guess — it scores like a good deterministic match so
# confidence/certainty don't nag someone who literally read the package aloud
# (field bug 2026-07: Chobani/Babybel).
_BRANDED_ESTIMATE_SCORE = 0.8

# A neutral fallback density for an unknown ml conversion (water-like).
_DEFAULT_ML_DENSITY = 1.0

# Discrete-count units: a stated count can only be priced with a per-piece weight.
_COUNT_UNITS = (Unit.PIECE, Unit.SLICE, Unit.SCOOP)

# Units FDC can price exactly: its profiles are per-100g with NO serving or per-piece
# data, so only a stated mass (or ml at assumed density) converts without guessing.
_MASS_UNITS = (Unit.G, Unit.OZ, Unit.LB, Unit.ML)

# FDC plausibility gate: same Atwater identity the estimator enforces (kcal ≈ 4P+4C+9F),
# with the same generous tolerance. Only meaningful when the macros carry real energy
# (>20 kcal by Atwater) — trace-macro foods (lettuce, coffee) are exempt.
_FDC_ATWATER_TOLERANCE = 0.35


def _fdc_profile_plausible(profile: NutrientProfile) -> bool:
    atwater = 4 * profile.protein + 4 * profile.carbs + 9 * profile.fat
    if atwater <= 20:
        # Trace-macro foods (lettuce, coffee, spirits) are exempt from the identity —
        # but BOUNDED: a row with real kcal and no macros at all (data-quality rows
        # mapping only Energy) is maximally inconsistent, not exempt. 250 kcal/100g
        # keeps spirits (~231) and every genuine trace-macro food.
        return profile.kcal <= 250
    if profile.kcal <= 0:
        return False
    return abs(profile.kcal - atwater) <= _FDC_ATWATER_TOLERANCE * max(profile.kcal, atwater)


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
    # Web sources a grounded estimate was read from (estimator.py FoodSource) — surfaced
    # to the user as the trust row ("4 sources"). Empty for deterministic resolutions.
    sources: tuple = ()


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
        if unit in _COUNT_UNITS:
            # COUNT-UNIT SAFETY, enforced at the math itself (field bugs 2026-07: "3 pieces
            # of turkey bacon" → 1104 kcal via the estimator path, then "2 pieces" → 736 kcal
            # via the FDC path — the guard lived in ONE caller, resolver._estimate, and FDC
            # walked straight past it). serving_grams is ONE SERVING, not one piece; count ×
            # serving balloons any count-stated food whose per-piece weight is unknown. With
            # no per-piece conversion a count CANNOT be priced — resolve to a single serving
            # (honest floor; callers downgrade specificity via _fell_back_to_serving).
            # MUST-NOT #5: item names are user content — log the unit only.
            logger.info(
                "No %s conversion for item — one serving, never count x serving", unit.value
            )
            return serving_grams
        logger.info("No %s conversion for item — using standard serving", unit.value)
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
        # Request-scoped memo (a Resolver is constructed per request via Depends /
        # _build_resolver). Requirement: the clarify engine re-resolves the same items
        # resolve_meal just resolved; with a live estimator that was a SECOND paid,
        # nondeterministic LLM estimate per unknown item per parse — and clarify could
        # price its questions against different macros than the totals shown to the
        # user. Memoizing on the item's exact contract fields makes every duplicate
        # resolve free and intra-request consistent (same item → same numbers).
        self._memo: dict[str, ResolvedItem] = {}

    async def resolve_item(self, item: ParsedItem) -> ResolvedItem:
        key = item.model_dump_json()
        cached = self._memo.get(key)
        if cached is not None:
            return cached
        resolved = await self._resolve_uncached(item)
        self._memo[key] = resolved
        return resolved

    async def _resolve_uncached(self, item: ParsedItem) -> ResolvedItem:
        # BRANDED items resolve AI-first (field bug 2026-07): the dictionary is generic by
        # design (MUST-NOT #4 forbids a branded DB), so a branded product exactly matching a
        # generic alias silently priced as the WRONG generic — "Chobani 30g-protein yogurt
        # drink" → whole-milk "yogurt" (3g protein). The model knows the actual label; use
        # it. When no estimator is configured (offline/tests) or it declines, fall through
        # to the deterministic path unchanged.
        if item.brand and self._estimator is not None:
            estimated = await self._estimate(item)
            if estimated is not None:
                return estimated

        match = self._dict.lookup(item.name, fat_ratio=item.fat_ratio, variant=item.variant)
        if match is not None:
            return self._from_dictionary(item, match)

        # FDC is only authoritative when it can actually price the stated amount: its
        # profiles are per-100g with no serving or per-piece data, so a COUNT unit or a
        # null amount resolves through FDC as a 100 g guess. The estimator knows real
        # serving_grams and per-piece weights (web-grounded, durably cached), so for
        # those amounts it goes FIRST. Field bugs 2026-07: "2 pieces of turkey bacon"
        # → FDC 2×100 g = 736 kcal; "iced matcha" → 100 g of matcha POWDER (418 kcal).
        fdc_can_price = item.amount is not None and item.unit in _MASS_UNITS
        estimator_declined = False
        if not fdc_can_price and self._estimator is not None:
            estimated = await self._estimate(item)
            if estimated is not None:
                return estimated
            estimator_declined = True  # don't pay for a second identical attempt below

        # FDC prices ONLY mass-stated amounts. Its per-100g profiles carry no serving or
        # per-piece data, so pricing a null amount or a count through FDC is a silent
        # "assume 100 g" guess — which ships the per-100g row AS the item total. Field bug
        # 2026-07-19: "a Big Mac" (brand unset by the parser) missed the dictionary, hit
        # FDC's per-100g row, and logged 234 kcal for a ~590 kcal sandwich at a
        # confident-looking 39%; "a Sprite" logged 40 kcal the same way. When the
        # estimator (which knows real serving sizes) has declined and the amount isn't a
        # mass, the honest answer is unresolved + a question — never a 100 g guess.
        if self._fdc is not None and fdc_can_price:
            fdc_result = await self._fdc.resolve(item.name)
            if fdc_result is not None and _fdc_profile_plausible(fdc_result.profile):
                # The plausibility gate is load-bearing: FDC rows carry data-quality bugs
                # (field report 2026-07: "idaho potato" -> 7 kcal/100g WITH 17.5 g carbs —
                # 14 kcal for a 200 g potato). An internally inconsistent row must fall
                # through to the web-grounded estimator, not silently price the meal.
                return self._from_fdc(item, fdc_result.profile)

        # Last resort: a flagged AI estimate beats a silent 0 kcal (estimator.py). Falls back to
        # unresolved when no estimator is configured or the estimate fails — never a crash.
        if self._estimator is not None and not estimator_declined:
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
            variant_family=list(match.variant_keys) or None,
            variant_unspecified=match.variant_unspecified,
            variant_macros=variant_macros,
            resolved_variant=match.chosen_variant,
        )

    def _from_fdc(self, item: ParsedItem, profile: NutrientProfile) -> ResolvedItem:
        # Only reachable with a stated mass (the fdc_can_price gate in _resolve_uncached):
        # FDC profiles are per-100g with no serving/per-piece data, so a mass is the only
        # amount they can price without inventing a portion. The serving anchor below is
        # therefore never consulted by to_grams — mass units convert globally.
        grams = to_grams(item, {}, 100.0)
        return ResolvedItem(
            item=item,
            source=ResolutionSource.FDC,
            match_kind=MatchKind.FDC,
            match_score=_MATCH_SCORE[MatchKind.FDC],
            grams=round(grams, 2),
            macros=profile.for_grams(grams),
            amount_specificity=classify_specificity(item),
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
        )

    async def _estimate(self, item: ParsedItem) -> ResolvedItem | None:
        """AI food identity + deterministic portion math — flagged, correctable (estimator.py).

        The estimator returns a per-100g profile + serving/unit grams ONCE (cached durably);
        grams and macros for THIS portion are computed here with the same ``to_grams`` math a
        dictionary entry uses — the model never prices individual logs. Returns None if the
        estimator declines (no key / implausible reply), so the caller falls through.
        Branded estimates score high (informed label read); brand-less ones stay low-trust.
        """
        est = await self._estimator.estimate(item)
        if est is None:
            return None
        fell_back = _fell_back_to_serving(item, est.unit_conversions)
        # Count-unit safety (a count with no per-piece weight = one serving, never
        # count × serving) now lives in to_grams itself, so EVERY caller — dictionary,
        # FDC, estimator — gets the same net; it can't be forgotten per-path again.
        grams = to_grams(item, est.unit_conversions, est.serving_grams)
        specificity = (
            AmountSpecificity.INFERRED_SERVING if fell_back else classify_specificity(item)
        )
        if item.brand and item.amount is None and specificity is AmountSpecificity.INFERRED_SERVING:
            # A sealed branded product with no stated amount = ONE package — the label
            # defines the portion; it is a count, not a guessed serving (a Chobani drink
            # is a bottle). Without this the packaged case was dinged twice for
            # "inferred" despite being fully specified by the product itself.
            # `amount is None` is load-bearing: when the user DID state a count that fell
            # back to one serving ("3 pieces of Applegate turkey bacon" with no per-piece
            # weight), the portion is a guess and must keep its low-trust flag.
            specificity = AmountSpecificity.STATED_COUNT
        # A WEB-GROUNDED estimate (sources present) was read off the actual label online —
        # it outranks even a branded knowledge read; a brand-less sourced item is no longer
        # a blind guess either.
        if est.sources:
            score = 0.85
        elif item.brand:
            score = _BRANDED_ESTIMATE_SCORE
        else:
            score = _MATCH_SCORE[MatchKind.ESTIMATED]
        return ResolvedItem(
            item=item,
            source=ResolutionSource.ESTIMATED,
            match_kind=MatchKind.ESTIMATED,
            match_score=score,
            grams=round(grams, 2),
            macros=est.per_100g.for_grams(grams),
            amount_specificity=specificity,
            is_estimate=True,
            sources=est.sources,
        )
