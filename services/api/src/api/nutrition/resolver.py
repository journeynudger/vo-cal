"""Resolution + macro calculation — the deterministic bridge (AGENTS.md #6).

Two stages, deliberately separate (2026-09-23):

  1. IDENTITY  ``Resolver.resolve_identity(item) -> FoodIdentity``: WHICH food this is —
     a per-100g profile, its portion data (serving, per-unit weights), basis state and
     provenance. Reads ONLY the identity fields (name, brand, variant, fat ratio, prep
     method), never the amount, unit or state.
       brand-less: curated exact → curated head (suffix rescue) → AI estimator → USDA FDC
                   → unresolved
       branded:    curated brand line → AI estimator (the model knows the label) → curated
                   generic head → USDA FDC (branded query) → unresolved
  2. PRICING   ``price(identity, item) -> ResolvedItem``: HOW MUCH — grams from the stated
     amount through the identity's conversions, then macros. Pure and synchronous.

Why the split: the old single ladder chose the SOURCE by the amount's unit (USDA search
first for a stated mass, curated head first otherwise), so "200 g cosmic crisp apple"
priced USDA's "Desserts, apple crisp" at 322 kcal while "a cosmic crisp apple" priced the
curated apple at 95 kcal, and a manual edit from one amount to the other silently swapped
the food (field incident 2026-09-23). Identity now never sees the amount, is memoized per
identity fields within a request (so a clarify spread is always priced against ONE
identity), and is persisted on the parse item so refine/confirm re-price the SAME
identity (``Resolver.prime``). A name/brand/variant/fat-ratio edit misses the memo and
re-identifies — those are the edits that are supposed to change the food.

Quantity normalization (pricing):
  - mass units (g/oz/lb)        → global gram conversion
  - ml                          → identity-specific density (default 1 g/ml)
  - volume/count units          → food-specific unit_conversions
  - null unit + amount (n)      → n × standard serving (modifier math: "double"→2)
  - null amount                 → 1 × standard serving (inferred)
  - raw/cooked factor applied when the item's state differs from the identity's basis.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Protocol

from pydantic import ValidationError

from ..parser.schemas import ParsedItem, State, Unit
from .dictionary import DictionaryMatch, FoodDictionary, get_dictionary, normalize_name
from .estimator import EstimatedFood, NutritionEstimator, estimate_cache_key
from .fatsecret_client import FatSecretClient, FatSecretResult
from .fdc_client import FdcClient, FdcResult
from .schemas import (
    AmountSpecificity,
    FoodIdentity,
    FoodSourceRef,
    Macros,
    MatchKind,
    NutrientProfile,
    ResolutionSource,
)

logger = logging.getLogger(__name__)

# Global mass conversions to grams (food-independent).
# One address for the ounce (restructure Phase 4, decision 4): the calorie eval and the
# resolver tests import these; nothing else spells them.
GRAMS_PER_OZ = 28.3495
GRAMS_PER_LB = 453.592

# Match-quality scores by kind (0..1) — feeds the confidence scorer.
_MATCH_SCORE: dict[MatchKind, float] = {
    MatchKind.CANONICAL: 1.0,
    MatchKind.ALIAS: 0.92,
    MatchKind.PARAMETERIZED: 0.95,
    # Suffix rescue ("kitkat creamer" → "creamer"): the head food is curated but the
    # spoken prefix is not priced, so it scores below a full alias hit.
    MatchKind.SUFFIX: 0.8,
    MatchKind.FAMILY_DEFAULT: 0.7,
    MatchKind.FDC: 0.6,
    # A FatSecret row passed the relevance gate and carries real servings: below a curated
    # alias, above USDA's per-100 g rows and every estimate.
    MatchKind.FATSECRET: 0.75,
    MatchKind.ESTIMATED: 0.35,  # low by design — an AI guess, flagged for correction
    MatchKind.NONE: 0.0,
}

# A BRANDED estimate is an informed label read (the user named the product; the model
# knows its label), not a blind guess — it scores like a good deterministic match so
# confidence/certainty don't nag someone who literally read the package aloud
# (field bug 2026-07: Chobani/Babybel).
_BRANDED_ESTIMATE_SCORE = 0.8
# A WEB-GROUNDED estimate (sources present) was read off the actual label online — it
# outranks even a branded knowledge read; a brand-less sourced item is no longer a blind guess.
_SOURCED_ESTIMATE_SCORE = 0.85

# A neutral fallback density for an unknown ml conversion (water-like).
_DEFAULT_ML_DENSITY = 1.0

# Discrete-count units: a stated count can only be priced with a per-piece weight.
_COUNT_UNITS = (Unit.PIECE, Unit.SLICE, Unit.SCOOP)

# Volume units without a food-specific conversion price as PHYSICAL volume at the food's
# density (ml conversion, default 1 g/ml): a US cup is 240 ml, a tablespoon 15, a teaspoon 5.
# The old fallback was amount × standard serving, which made "two cups of spaghetti
# bolognese" two 350 g plates (1057 kcal, calorie-eval 2026-09-23) and would price "2 tbsp"
# of any sauce without a tbsp conversion as two whole servings. Physical volume is off by
# the food's density (flour 0.5, greens 0.15) where a curated entry has no cup conversion;
# a serving multiple is off by whatever the serving happens to be.
_ML_PER_VOLUME_UNIT: dict[Unit, float] = {Unit.CUP: 240.0, Unit.TBSP: 15.0, Unit.TSP: 5.0}

# Units a portion-less identity (USDA per-100g row) can price exactly: a stated mass (or ml
# at assumed density) converts without a serving or per-piece guess.
_MASS_UNITS = (Unit.G, Unit.OZ, Unit.LB, Unit.ML)

# FDC plausibility gate: same Atwater identity the estimator enforces (kcal ≈ 4P+4C+9F),
# with the same generous tolerance. Only meaningful when the macros carry real energy
# (>20 kcal by Atwater) — trace-macro foods (lettuce, coffee) are exempt.
_FDC_ATWATER_TOLERANCE = 0.35
# A branded FatSecret row may differ from the curated generic head by at most this factor
# either way (a "Fairlife milk" row at 3x milk's kcal is the protein shake, not the milk).
_BRAND_BAND = 2.5

# Sanity band for a BRANDED estimate against the curated generic head the name also matches
# ("Chobani strawberry greek yogurt" → greek yogurt, flavored). A label read that lands
# outside 0.2x..3x of the head's kcal/100 g is a misread (a per-ounce or per-serving table
# taken as per-100 g, the wrong product class), not a formulation: real brand variation —
# zero-sugar sodas, light beers, protein-fortified yogurts — stays inside it. Declined
# estimates fall to the head with its variant chip. Heads under 10 kcal/100 g (water, diet
# soda) have no meaningful ratio and are exempt.
_BRANDED_BAND = (0.2, 3.0)
_BAND_MIN_HEAD_KCAL = 10.0

# ParsedItem.fat_ratio contract pattern: persisted rows carry free-form ratios (a user edit),
# which must degrade to "unspecified" when rebuilding an item for priming, never raise.
_FAT_RATIO_RE = re.compile(r"^\d{2}/\d{1,2}$")

_ZERO_PROFILE = NutrientProfile(kcal=0.0, protein=0.0, carbs=0.0, fat=0.0, fiber=0.0)

# No identity claim: zero macros + the missing-detail flow (never a crash, never a guess).
UNRESOLVED_IDENTITY = FoodIdentity(
    key="unresolved",
    source=ResolutionSource.UNRESOLVED,
    match_kind=MatchKind.NONE,
    match_score=0.0,
    per_100g=_ZERO_PROFILE,
)

# A composed-meal display grouping (parser/compose.py verdict): a container whose contents
# carry the meal, or a component absorbed into a named dish. Priced at zero deliberately;
# DICTIONARY/CANONICAL so it is confidence-neutral (zero-kcal items get the floor weight in
# meal_confidence, like water) and the estimator is never called for it.
GROUPING_IDENTITY = FoodIdentity(
    key="grouping",
    source=ResolutionSource.DICTIONARY,
    match_kind=MatchKind.CANONICAL,
    match_score=1.0,
    per_100g=_ZERO_PROFILE,
    serving_grams=0.0,
)


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
    """One parsed item joined with its identity and priced for its stated amount."""

    item: ParsedItem
    identity: FoodIdentity
    grams: float
    macros: Macros
    amount_specificity: AmountSpecificity
    # Macros for every variant at the resolved grams (decision #29) — the clarify engine
    # prices the spread across these without re-resolving. None when the food has no
    # variant axis.
    variant_macros: dict[str, Macros] | None = None

    # Identity pass-throughs under the pre-split names, so confidence/certainty/clarify and
    # the routers keep reading one object.
    @property
    def source(self) -> ResolutionSource:
        return self.identity.source

    @property
    def match_kind(self) -> MatchKind:
        return self.identity.match_kind

    @property
    def match_score(self) -> float:
        return self.identity.match_score

    @property
    def resolved_fat_ratio(self) -> str | None:
        return self.identity.resolved_fat_ratio

    @property
    def variant_family(self) -> list[str] | None:
        return self.identity.variant_family

    @property
    def variant_unspecified(self) -> bool:
        return self.identity.variant_unspecified

    @property
    def resolved_variant(self) -> str | None:
        return self.identity.resolved_variant

    @property
    def is_estimate(self) -> bool:
        return self.identity.is_estimate

    @property
    def sources(self) -> tuple[FoodSourceRef, ...]:
        return tuple(self.identity.sources)


@dataclass(frozen=True)
class ResolvedMeal:
    items: list[ResolvedItem]
    totals: Macros


def identity_fields_key(item: ParsedItem) -> str:
    """The fields identity resolution reads — and nothing else. Two items with the same key
    are the same food; amount, unit and state only change the pricing."""
    return json.dumps([item.name, item.brand, item.variant, item.fat_ratio, item.prep_method])


def persistable_identity(identity: FoodIdentity) -> FoodIdentity | None:
    """The identity to write on a parse/meal item, or None when there is no identity claim to
    carry forward (unresolved items re-identify next time; groupings are a composition
    verdict, re-derived from the transcript at every step)."""
    if identity.source is ResolutionSource.UNRESOLVED or identity.key == GROUPING_IDENTITY.key:
        return None
    return identity


def stored_identities(rows: Iterable[dict]) -> list[tuple[ParsedItem, FoodIdentity]]:
    """Recover (item, identity) pairs from persisted parse-result or meal-log item dicts,
    for ``Resolver.prime``. Rows without a persisted identity (older parses, groupings,
    unresolved items) or with an unparseable one are skipped — they simply re-identify.
    Only ever fed from SERVER rows: a client-sent identity carries per-100g numbers and the
    client never authors trustworthy macros (Non-Negotiable #6)."""
    out: list[tuple[ParsedItem, FoodIdentity]] = []
    for row in rows:
        raw = row.get("identity") if isinstance(row, dict) else None
        if not raw:
            continue
        ratio = row.get("fat_ratio")
        try:
            identity = FoodIdentity.model_validate(raw)
            item = ParsedItem(
                name=str(row.get("name") or ""),
                brand=row.get("brand"),
                variant=row.get("variant"),
                fat_ratio=ratio if isinstance(ratio, str) and _FAT_RATIO_RE.match(ratio) else None,
                prep_method=row.get("prep_method"),
                confidence=1.0,
            )
        except ValidationError:
            continue
        out.append((item, identity))
    return out


def classify_specificity(item: ParsedItem) -> AmountSpecificity:
    """How precisely the user stated the quantity (feeds confidence)."""
    if item.amount is None:
        return AmountSpecificity.INFERRED_SERVING
    if item.unit is None:
        return AmountSpecificity.SERVING_MULTIPLIER
    if item.unit in _MASS_UNITS:
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
        return amount * GRAMS_PER_OZ
    if unit is Unit.LB:
        return amount * GRAMS_PER_LB
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
            # via the FDC path — the guard lived in ONE caller and FDC walked straight past
            # it). serving_grams is ONE SERVING, not one piece; count × serving balloons any
            # count-stated food whose per-piece weight is unknown. With no per-piece
            # conversion a count CANNOT be priced — resolve to a single serving (honest
            # floor; callers downgrade specificity via _fell_back_to_serving).
            # MUST-NOT #5: item names are user content — log the unit only.
            logger.info(
                "No %s conversion for item — one serving, never count x serving", unit.value
            )
            return serving_grams
        logger.info("No %s conversion for item — physical volume at density", unit.value)
        density = entry_conversions.get("ml", _DEFAULT_ML_DENSITY)
        return amount * _ML_PER_VOLUME_UNIT[unit] * density
    return amount * per_unit


def _fell_back_to_serving(item: ParsedItem, entry_conversions: dict[str, float]) -> bool:
    """True when a STATED volume/count amount had no food-specific conversion, so to_grams used
    a guess (one serving for a count; physical volume at a default density for a volume). The
    resolved grams are then an inference, not the stated volume/count precision — so the amount
    specificity (which feeds confidence) must be downgraded to INFERRED_SERVING rather than
    reported as STATED_VOLUME/STATED_COUNT. Mass units (g/oz/lb/ml) always convert exactly and
    never fall back."""
    if item.amount is None or item.unit is None:
        return False
    if item.unit in _MASS_UNITS:
        return False
    return entry_conversions.get(item.unit.value) is None


def _is_stated_mass(item: ParsedItem) -> bool:
    return item.amount is not None and item.unit in _MASS_UNITS


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


# -- pricing (pure) --------------------------------------------------------------


def price(identity: FoodIdentity, item: ParsedItem) -> ResolvedItem:
    """Grams + macros for THIS item's amount from an already-resolved identity.

    The only place amount/unit/state are read. An identity without portion data (a USDA
    per-100g row) can price a stated mass and nothing else: pricing a count or a bare
    mention through it would be a silent "assume 100 g" — the 234-kcal Big Mac shape
    (2026-07-19) — so those degrade to unresolved (zero macros + the missing-detail flow).
    """
    if identity.source is ResolutionSource.UNRESOLVED:
        return _unpriced(item)
    if identity.serving_grams is None and not _is_stated_mass(item):
        logger.info(
            "identity without portion data cannot price a non-mass amount (unit=%s)",
            item.unit.value if item.unit else "serving",
        )
        return _unpriced(item)
    if identity.unweighed_serving and _is_stated_mass(item):
        # The mirror case: a serving with no weight can price servings, never grams.
        # Decided here, in pricing, because identity must not depend on the amount
        # (the resolver memoizes one identity per food across every quantity of it).
        logger.info("unweighed serving cannot price a stated mass (unit=%s)", item.unit.value if item.unit else "-")
        return _unpriced(item)

    grams = to_grams(item, identity.unit_conversions, identity.serving_grams or 0.0)
    grams = apply_state_factor(grams, item.state, identity.basis_state, identity.raw_cooked_factor)
    fell_back = _fell_back_to_serving(item, identity.unit_conversions)
    specificity = AmountSpecificity.INFERRED_SERVING if fell_back else classify_specificity(item)
    if (
        identity.is_estimate
        and item.brand
        and item.amount is None
        and specificity is AmountSpecificity.INFERRED_SERVING
    ):
        # A sealed branded product with no stated amount = ONE package — the label defines
        # the portion; it is a count, not a guessed serving (a Chobani drink is a bottle).
        # Without this the packaged case was dinged twice for "inferred" despite being fully
        # specified by the product itself. `amount is None` is load-bearing: when the user
        # DID state a count that fell back to one serving ("3 pieces of Applegate turkey
        # bacon" with no per-piece weight), the portion is a guess and keeps its low-trust flag.
        specificity = AmountSpecificity.STATED_COUNT
    variant_macros = (
        {key: prof.for_grams(grams) for key, prof in identity.variant_profiles.items()}
        if identity.variant_profiles
        else None
    )
    return ResolvedItem(
        item=item,
        identity=identity,
        grams=round(grams, 2),
        macros=identity.per_100g.for_grams(grams),
        amount_specificity=specificity,
        variant_macros=variant_macros,
    )


def _unpriced(item: ParsedItem) -> ResolvedItem:
    return ResolvedItem(
        item=item,
        identity=UNRESOLVED_IDENTITY,
        grams=0.0,
        macros=Macros.zero(),
        amount_specificity=classify_specificity(item),
    )


def grouping(item: ParsedItem) -> ResolvedItem:
    """A suppressed item as a zero-calorie display grouping (see GROUPING_IDENTITY)."""
    return ResolvedItem(
        item=item,
        identity=GROUPING_IDENTITY,
        grams=0.0,
        macros=Macros.zero(),
        amount_specificity=classify_specificity(item),
    )


def _estimate_within_band(est: EstimatedFood, head: DictionaryMatch | None) -> bool:
    """Category sanity for a branded label read (see _BRANDED_BAND). No head → nothing to
    compare against → accepted (the Atwater/serving-basis fences already ran)."""
    if head is None:
        return True
    entry = head.entry
    reference = entry.variants[head.chosen_variant] if head.chosen_variant else entry.profile
    if reference.kcal < _BAND_MIN_HEAD_KCAL:
        return True
    ratio = est.per_100g.kcal / reference.kcal
    lo, hi = _BRANDED_BAND
    if lo <= ratio <= hi:
        return True
    # MUST-NOT #5: no names in logs — the head's canonical is curated data, the ratio is a number.
    logger.info(
        "branded estimate declined: %.2fx the curated head %r (band %.1f..%.1f)",
        ratio, entry.canonical_name, lo, hi,
    )
    return False


# -- identity builders -----------------------------------------------------------


def _dictionary_identity(match: DictionaryMatch, spoken_name: str) -> FoodIdentity:
    entry = match.entry
    chosen = entry.variants[match.chosen_variant] if match.chosen_variant else entry.profile
    key = f"dictionary:{entry.canonical_name}"
    if match.chosen_variant:
        key += f"/{match.chosen_variant}"
    if match.resolved_fat_ratio:
        key += f"/{match.resolved_fat_ratio}"
    canonical = entry.canonical_name
    return FoodIdentity(
        key=key,
        source=ResolutionSource.DICTIONARY,
        match_kind=match.kind,
        match_score=_MATCH_SCORE[match.kind],
        per_100g=chosen,
        serving_grams=entry.serving_grams,
        unit_conversions=dict(entry.unit_conversions),
        basis_state=entry.basis_state,
        raw_cooked_factor=entry.raw_cooked_factor,
        resolved_fat_ratio=match.resolved_fat_ratio,
        variant_family=list(match.variant_keys) or None,
        variant_profiles=dict(entry.variants) or None,
        variant_unspecified=match.variant_unspecified,
        resolved_variant=match.chosen_variant,
        priced_as=canonical if normalize_name(canonical) != normalize_name(spoken_name) else None,
    )


def _estimate_identity(item: ParsedItem, est: EstimatedFood) -> FoodIdentity:
    if est.sources:
        score = _SOURCED_ESTIMATE_SCORE
    elif item.brand:
        score = _BRANDED_ESTIMATE_SCORE
    else:
        score = _MATCH_SCORE[MatchKind.ESTIMATED]
    return FoodIdentity(
        key=estimate_cache_key(item),
        source=ResolutionSource.ESTIMATED,
        match_kind=MatchKind.ESTIMATED,
        match_score=score,
        per_100g=est.per_100g,
        serving_grams=est.serving_grams,
        unit_conversions=dict(est.unit_conversions),
        is_estimate=True,
        sources=[FoodSourceRef(url=s.url, title=s.title) for s in est.sources],
    )


def _fatsecret_identity(result: FatSecretResult, spoken_name: str) -> FoodIdentity:
    # An unweighed serving (a restaurant "1 serving") is carried as 100 g so per-serving
    # numbers survive the per-100 g contract; the ladder refuses such a row for a stated
    # mass (see _identify_via_fatsecret), so the convention never prices a weight wrongly.
    serving_grams = result.serving_grams if result.serving_grams else 100.0
    return FoodIdentity(
        key=f"fatsecret:{result.food_id}",
        source=ResolutionSource.FATSECRET,
        match_kind=MatchKind.FATSECRET,
        match_score=_MATCH_SCORE[MatchKind.FATSECRET],
        per_100g=result.per_100g,
        serving_grams=serving_grams,
        unweighed_serving=not result.serving_grams,
        unit_conversions=dict(result.unit_conversions),
        priced_as=result.description if normalize_name(result.description) != normalize_name(spoken_name) else None,
    )


def _fdc_identity(result: FdcResult) -> FoodIdentity:
    return FoodIdentity(
        key=f"fdc:{result.fdc_id}",
        source=ResolutionSource.FDC,
        match_kind=MatchKind.FDC,
        match_score=_MATCH_SCORE[MatchKind.FDC],
        per_100g=result.profile,
        serving_grams=None,  # per-100g row: no serving or per-piece data
        priced_as=result.description or None,
    )


# -- the resolver -----------------------------------------------------------------


class PersonalVocabulary(Protocol):
    """What the resolver asks of the person's own foods (foods/index.py implements it)."""

    def identity_for(self, item: ParsedItem) -> FoodIdentity | None: ...


class Resolver:
    """Identifies parsed items (memoized per identity fields) and prices them."""

    def __init__(
        self,
        dictionary: FoodDictionary | None = None,
        fdc: FdcClient | None = None,
        estimator: NutritionEstimator | None = None,
        fatsecret: FatSecretClient | None = None,
    ) -> None:
        self._dict = dictionary or get_dictionary()
        self._fdc = fdc
        self._estimator = estimator
        self._fatsecret = fatsecret
        # Request-scoped identity memo keyed by identity_fields_key (a Resolver is built per
        # request via Depends / _build_resolver). Requirement: the clarify engine re-resolves
        # the items resolve_meal just resolved, plus amount/state alternatives of them; with a
        # live estimator that was a SECOND paid, nondeterministic LLM estimate per unknown item
        # per parse, and a spread could be priced against different macros than the totals.
        # Memoizes the TASK (not the result) so CONCURRENT callers share one in-flight
        # identification. Alternatives that vary only amount/unit/state hit the same key by
        # construction — a spread is always priced against ONE identity.
        self._identities: dict[str, FoodIdentity | asyncio.Task[FoodIdentity]] = {}
        # The person's own foods (foods/index.py), consulted before every database. Set per
        # request by the routers once the user is known; None means no personal vocabulary.
        self._personal: PersonalVocabulary | None = None

    def register_personal(self, vocabulary: PersonalVocabulary | None) -> None:
        self._personal = vocabulary

    def prime(self, item: ParsedItem, identity: FoodIdentity) -> None:
        """Seed the memo with an identity resolved earlier (a parse row's persisted identity)
        so refine/confirm re-PRICE the food the user saw instead of re-identifying it. Items
        whose identity fields changed (name/brand/variant/fat ratio) miss the memo and
        identify fresh — exactly the edits that SHOULD change the food."""
        self._identities.setdefault(identity_fields_key(item), identity)

    async def resolve_identity(self, item: ParsedItem) -> FoodIdentity:
        key = identity_fields_key(item)
        entry = self._identities.get(key)
        if entry is None:
            entry = asyncio.ensure_future(self._identify(item))
            self._identities[key] = entry
        if isinstance(entry, FoodIdentity):
            return entry
        return await entry

    async def resolve_item(self, item: ParsedItem) -> ResolvedItem:
        return price(await self.resolve_identity(item), item)

    async def resolve_meal(self, items: list[ParsedItem]) -> ResolvedMeal:
        # Items resolve CONCURRENTLY: a several-item meal with two estimator lookups
        # (web search, seconds each on a cold cache) paid them back-to-back — the p95
        # parse hit 12-15 s (eval 2026-07-30). Wall-clock is now the slowest item.
        resolved = list(await asyncio.gather(*(self.resolve_item(i) for i in items)))
        totals = Macros.zero()
        for r in resolved:
            totals = totals + r.macros
        return ResolvedMeal(items=resolved, totals=totals)

    # -- the identity ladder ------------------------------------------------------

    async def _identify(self, item: ParsedItem) -> FoodIdentity:
        # If you named it, you meant it: a personal food wins over every database, brand or
        # not (a meal-prep container is often spoken with its brand).
        if self._personal is not None:
            personal = self._personal.identity_for(item)
            if personal is not None:
                return personal
        if item.brand:
            return await self._identify_branded(item)

        exact = self._dict.lookup(
            item.name, fat_ratio=item.fat_ratio, variant=item.variant, include_suffix=False
        )
        if exact is not None:
            return _dictionary_identity(exact, item.name)

        # Curated head (suffix rescue) BEFORE every live source, for every amount kind: a
        # curated food under a flavor/cultivar/brand-line prefix prices deterministically and
        # free ("cosmic crisp apple" → apple; "kitkat creamer" → coffee creamer). The
        # 2026-08-20 ordering let USDA search go first for a stated mass so "50 g bison
        # bacon" could find USDA's bison row; that bought one rare exact match at the price
        # of the apple incident (USDA's "apple crisp" dessert for "200 g cosmic crisp
        # apple") and made the food depend on the unit. Gone: the head wins, the UI says
        # what was priced (priced_as), and a name edit re-identifies.
        head = self._dict.lookup(item.name, fat_ratio=item.fat_ratio, variant=item.variant)
        if head is not None:
            return _dictionary_identity(head, item.name)

        # No curated match at all. FatSecret first (2026-09-24): a database row with the
        # label's serving, cups and pieces, deterministic and cached, before the estimator
        # pays a model for a guess. The estimator then carries what FatSecret lacks; USDA
        # FDC stays last (per-100 g rows price a stated mass only, see price()) and
        # scripts/food-source-eval measures whether it is still reached.
        fatsecret = await self._identify_via_fatsecret(item, branded=False)
        if fatsecret is not None:
            return fatsecret
        if self._estimator is not None:
            est = await self._estimator.estimate(item)
            if est is not None:
                return _estimate_identity(item, est)
        return await self._identify_via_fdc(item.name) or UNRESOLVED_IDENTITY

    async def _identify_branded(self, item: ParsedItem) -> FoodIdentity:
        """Branded ladder.

        CURATED brand lines preempt the AI-first flow (field report 2026-08-20: Fairlife
        milk paying the estimator and getting the wrong sibling product — protein shakes —
        back; Coffee-mate flavors unresolvable). The gate is opt-in per entry: lookup_branded
        accepts only entries that themselves mention the brand.

        Everything else BRANDED resolves AI-first (field bug 2026-07): the dictionary is
        generic by design (MUST-NOT #4 forbids a branded DB), so a branded product exactly
        matching a generic alias silently priced as the WRONG generic — "Chobani
        30g-protein yogurt drink" → whole-milk "yogurt" (3 g protein). The model knows the
        actual label; use it. When no estimator is configured (offline/tests) or it
        declines, the curated generic head prices it with its variant chip, then FDC's
        branded rows, then unresolved.
        """
        assert item.brand  # caller-checked
        branded = self._dict.lookup_branded(
            item.brand, item.name, fat_ratio=item.fat_ratio, variant=item.variant
        )
        if branded is not None:
            return _dictionary_identity(branded, item.name)
        head = self._dict.lookup(item.name, fat_ratio=item.fat_ratio, variant=item.variant)
        # FatSecret's brand rows are the label as the maker published it; the same band
        # check as the estimator's keeps a wrong sibling product (a shake for a milk) out.
        fatsecret = await self._identify_via_fatsecret(item, branded=True, head=head)
        if fatsecret is not None:
            return fatsecret
        if self._estimator is not None:
            est = await self._estimator.estimate(item)
            if est is not None and _estimate_within_band(est, head):
                return _estimate_identity(item, est)
        if head is not None:
            return _dictionary_identity(head, item.name)
        # The brand is part of the query for USDA's Branded rows; don't double it when the
        # user already said it inside the name ("fairlife 2% milk").
        spoken = normalize_name(item.name)
        query = spoken if normalize_name(item.brand) in spoken else f"{item.brand} {item.name}"
        return await self._identify_via_fdc(query, branded=True) or UNRESOLVED_IDENTITY

    async def _identify_via_fatsecret(
        self, item: ParsedItem, *, branded: bool, head: DictionaryMatch | None = None
    ) -> FoodIdentity | None:
        if self._fatsecret is None:
            return None
        term = f"{item.brand} {item.name}".strip() if branded and item.brand else item.name
        if branded and item.brand and normalize_name(item.brand) in normalize_name(item.name):
            term = item.name
        result = await self._fatsecret.resolve(term, branded=branded)
        if result is None or not _fdc_profile_plausible(result.per_100g):
            return None
        if head is not None:
            ratio = result.per_100g.kcal / max(head.entry.profile.kcal, 1.0)
            if not (1 / _BRAND_BAND <= ratio <= _BRAND_BAND):
                return None
        return _fatsecret_identity(result, item.name)

    async def _identify_via_fdc(self, term: str, *, branded: bool = False) -> FoodIdentity | None:
        if self._fdc is None:
            return None
        result = await self._fdc.resolve(term, branded=branded)
        if result is None or not _fdc_profile_plausible(result.profile):
            # The plausibility gate is load-bearing: FDC rows carry data-quality bugs
            # (field report 2026-07: "idaho potato" -> 7 kcal/100g WITH 17.5 g carbs —
            # 14 kcal for a 200 g potato). An internally inconsistent row is a miss.
            return None
        return _fdc_identity(result)
