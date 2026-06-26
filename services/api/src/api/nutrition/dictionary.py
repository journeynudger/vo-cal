"""Internal food dictionary — the curated core (dictionary-first resolution).

The dictionary answers high-frequency foods with curated, USDA-grounded
conversion factors; USDA FDC (nutrition/fdc_client.py) covers the long tail.
Dictionary hits are higher-confidence than FDC hits, and that ordering feeds
the confidence score (parser/confidence.py).

What this module owns:

- **Normalized lookup**: lowercase + whitespace/punctuation strip, exact
  canonical match, then alias match.
- **Fat-ratio parameterized ground meat**: "93/7 beef" resolves against the
  ground-beef family; ratios between curated anchors are linearly interpolated
  (kcal/protein/fat scale with leanness). An unknown ratio falls to the
  documented family default (85/15-ish), flagged so confidence is discounted.
- **Modifier math is NOT here** — the parser records the multiplier on the
  amount (contract principle #4); the resolver multiplies grams. This module
  only exposes ``serving_grams`` so a null-amount item can fall back to one
  standard serving.

The LLM never touches these numbers (AGENTS.md #6): everything is deterministic
and unit-tested.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

from .schemas import MatchKind, NutrientProfile

_SEED_PATH = Path(__file__).resolve().parent / "dictionary_seed.json"

# "ground beef 93/7", "93/7 beef", "ground turkey 85/15" → family + ratio. The digit
# boundaries (?<!\d) / (?!\d) keep a 2-digit lean from matching inside a longer number: a
# malformed "100/0" must NOT capture the trailing "00/0" and clamp to the fattiest anchor
# (RT-49) — it falls through to the family default instead.
_GROUND_FAMILIES = ("ground beef", "ground turkey")
_RATIO_RE = re.compile(r"(?<!\d)(\d{2})\s*/\s*(\d{1,2})(?!\d)")


def _normalize(text: str) -> str:
    """Lowercase, collapse whitespace, strip surrounding punctuation."""
    text = text.lower().strip()
    text = re.sub(r"[^\w\s/%]", " ", text)  # keep / for fat ratios, % for "2%"
    return re.sub(r"\s+", " ", text).strip()


@dataclass(frozen=True)
class DictionaryEntry:
    canonical_name: str
    aliases: tuple[str, ...]
    profile: NutrientProfile
    basis_state: str  # "raw" | "cooked" | "ready"
    unit_conversions: dict[str, float]  # unit -> grams per unit (food-specific)
    raw_cooked_factor: float | None  # grams cooked = grams raw * factor
    serving_grams: float
    # Produce servings credited by ONE standard serving (serving_grams) of this
    # food (decision #28: produce is a home-dashboard pillar). Only set on fruits
    # and vegetables; ``0.0`` for everything else (a burger contributes none).
    # Optional in the seed JSON — entries without it default to 0.0.
    produce_servings: float = 0.0
    # Material-variant family (decision #29). When a food has sub-types the user
    # commonly leaves unspecified (whole vs fat-free cheddar, regular vs light
    # mayo, whole vs skim milk), ``variant_family`` names the axis and
    # ``variants`` maps each variant key to its own per-100g profile. ``profile``
    # above is the default variant's profile. Empty/None for foods without a
    # material variant axis. Treated by the clarify engine as a material axis
    # alongside ground-meat ``fat_ratio`` — the resolver fills the default, the
    # clarify engine prices the spread across ``variants``.
    variant_family: str | None = None
    default_variant: str | None = None
    variants: dict[str, NutrientProfile] = field(default_factory=dict)


@dataclass(frozen=True)
class DictionaryMatch:
    entry: DictionaryEntry
    kind: MatchKind
    # For ground-meat family hits, the ratio actually resolved (interpolated or default).
    resolved_fat_ratio: str | None = None
    # Variant axis (decision #29). When the matched entry has a variant family and
    # the user did not name a specific variant, ``variant_unspecified`` is True and
    # the resolver filled the documented ``default_variant``. ``variant_keys`` is the
    # ordered list of variants for this entry (empty when the food has no axis), so
    # the clarify engine can re-price the spread across them.
    variant_unspecified: bool = False
    variant_keys: tuple[str, ...] = ()
    # Set when the user answered the variant question (item.variant); the resolver
    # then prices the chosen variant's profile instead of the default.
    chosen_variant: str | None = None
    # True when a variant WAS supplied but is not a real key for this entry (RT-50): the
    # answer must be surfaced as invalid, never silently collapsed to default-and-unspecified
    # (which reads as "never answered" and re-asks/defaults without telling the user).
    variant_invalid: bool = False


class FoodDictionary:
    """In-memory index over the curated seed.

    Loaded once from ``dictionary_seed.json`` (the seed the food_dictionary
    table is populated from). A live deployment could instead hydrate from the
    table via the Database seam; the lookup logic is identical either way.
    """

    def __init__(self, entries: list[DictionaryEntry]) -> None:
        self._by_canonical: dict[str, DictionaryEntry] = {}
        self._by_alias: dict[str, DictionaryEntry] = {}
        # Ground-meat anchors: family -> {lean_pct: entry}
        self._families: dict[str, dict[int, DictionaryEntry]] = {f: {} for f in _GROUND_FAMILIES}

        for entry in entries:
            self._by_canonical[_normalize(entry.canonical_name)] = entry
            for alias in entry.aliases:
                # Canonical names win over alias collisions across foods.
                self._by_alias.setdefault(_normalize(alias), entry)
            self._index_family(entry)

    def _index_family(self, entry: DictionaryEntry) -> None:
        for family in _GROUND_FAMILIES:
            if entry.canonical_name.startswith(family + " "):
                match = _RATIO_RE.search(entry.canonical_name)
                if match:
                    self._families[family][int(match.group(1))] = entry

    @classmethod
    def from_seed(cls, path: Path = _SEED_PATH) -> FoodDictionary:
        raw = json.loads(path.read_text())
        entries = [
            DictionaryEntry(
                canonical_name=row["canonical_name"],
                aliases=tuple(row["aliases"]),
                profile=NutrientProfile(**row["per_100g"]),
                basis_state=row["basis_state"],
                unit_conversions={
                    k: float(v) for k, v in (row.get("unit_conversions") or {}).items()
                },
                raw_cooked_factor=row.get("raw_cooked_factor"),
                serving_grams=float(row["serving_grams"]),
                produce_servings=float(row.get("produce_servings") or 0.0),
                variant_family=row.get("variant_family"),
                default_variant=row.get("default_variant"),
                variants={
                    key: NutrientProfile(**profile)
                    for key, profile in (row.get("variants") or {}).items()
                },
            )
            for row in raw
        ]
        return cls(entries)

    def __len__(self) -> int:
        return len(self._by_canonical)

    # -- lookup ---------------------------------------------------------------

    def lookup(
        self, name: str, fat_ratio: str | None = None, variant: str | None = None
    ) -> DictionaryMatch | None:
        """Resolve a food name (+ optional fat ratio / chosen variant) to a match.

        Order: ground-meat family (when name names a family) → exact canonical
        → alias. Returns ``None`` on a miss (caller falls through to FDC).
        """
        norm = _normalize(name)

        family = self._family_for(norm)
        if family is not None:
            return self._resolve_family(family, fat_ratio)

        entry = self._by_canonical.get(norm)
        if entry is not None:
            return self._with_variant(DictionaryMatch(entry=entry, kind=MatchKind.CANONICAL), variant)

        entry = self._by_alias.get(norm)
        if entry is not None:
            return self._with_variant(DictionaryMatch(entry=entry, kind=MatchKind.ALIAS), variant)

        return None

    @staticmethod
    def _with_variant(match: DictionaryMatch, variant: str | None = None) -> DictionaryMatch:
        """Annotate a match with its variant axis (decision #29).

        When the matched entry carries a ``variant_family`` (whole/fat-free
        cheddar, regular/light mayo, …), the entry's ``profile`` is the
        *default* variant. A plain name match ("cheddar", "mayo") with no chosen
        variant means the user did not name one, so ``variant_unspecified`` is
        True and the clarify engine prices the spread across ``variant_keys``.
        A valid ``variant`` (the answered check) pins ``chosen_variant`` and
        clears the unspecified flag. A match whose entry has no variant family
        carries no axis — no variant question.
        """
        entry = match.entry
        if not entry.variant_family or not entry.variants:
            return match
        # Three cases: none supplied → unspecified (ask); a valid key → pinned; a supplied
        # key that isn't real → invalid (surfaced, NOT unspecified) so the answer isn't
        # silently discarded and re-asked/defaulted (RT-50).
        supplied = variant is not None
        valid = supplied and variant in entry.variants
        return DictionaryMatch(
            entry=entry,
            kind=match.kind,
            resolved_fat_ratio=match.resolved_fat_ratio,
            variant_unspecified=not supplied,
            variant_keys=tuple(entry.variants),
            chosen_variant=variant if valid else None,
            variant_invalid=supplied and not valid,
        )

    def variant_profile(self, entry: DictionaryEntry, variant_key: str) -> NutrientProfile:
        """Return the per-100g profile for one variant of ``entry``.

        Used by the clarify engine to re-price an item across its variant family
        (e.g. whole vs fat-free cheddar). Falls back to the entry's default
        profile for an unknown key (never raises — the engine only passes keys it
        read from ``variant_keys``).
        """
        return entry.variants.get(variant_key, entry.profile)

    def produce_servings_for(self, name: str, grams: float) -> float:
        """Produce servings credited by ``grams`` of the food named ``name``.

        Matching approach (deterministic, AGENTS.md #6): normalize the stored
        item name and resolve it through the same ``lookup`` path the resolver
        used (canonical → alias; ground-meat families never carry produce). A
        miss (FDC long-tail, unresolved, or non-produce) contributes ``0.0`` —
        produce is a curated-dictionary signal only, never guessed.

        Servings scale linearly with mass: an entry crediting ``produce_servings``
        per ``serving_grams`` credits ``grams / serving_grams × produce_servings``.
        Returned unrounded; the caller rounds the day total once.
        """
        match = self.lookup(name)
        if match is None:
            return 0.0
        entry = match.entry
        if entry.produce_servings <= 0.0 or entry.serving_grams <= 0.0:
            return 0.0
        return grams / entry.serving_grams * entry.produce_servings

    def _family_for(self, norm_name: str) -> str | None:
        """Does this name denote a ground-meat family (so ratio parameterizes it)?

        Matches the bare family ("ground beef", "beef", "ground turkey") — NOT a
        name that already carries a ratio (those hit the canonical index, which
        is fine, but family resolution interpolates and is preferred).
        """
        for family in _GROUND_FAMILIES:
            meat = family.split()[-1]  # "beef" / "turkey"
            if norm_name in {family, meat, f"{meat} ground", f"ground {meat}"}:
                return family
        return None

    def _resolve_family(self, family: str, fat_ratio: str | None) -> DictionaryMatch:
        anchors = self._families[family]
        if fat_ratio:
            match = _RATIO_RE.search(fat_ratio)
            if match:
                lean = int(match.group(1))
                entry, resolved_lean = self._interpolate_family(family, lean)
                # Report the lean ACTUALLY used: equal to the request when in-range
                # (exact or interpolated), but the clamped anchor's lean when the request
                # was outside the curated range — never the unrepresentable request (RT-14).
                return DictionaryMatch(
                    entry=entry,
                    kind=MatchKind.PARAMETERIZED,
                    resolved_fat_ratio=self._fmt_ratio(resolved_lean),
                )
        # No ratio → documented family default (the bare-family entry, ~85/15).
        default = self._by_canonical.get(_normalize(family))
        if default is None:  # pragma: no cover — seed always carries the bare family
            default = anchors[sorted(anchors)[len(anchors) // 2]]
        return DictionaryMatch(entry=default, kind=MatchKind.FAMILY_DEFAULT)

    @staticmethod
    def _fmt_ratio(lean: int) -> str:
        return f"{lean}/{100 - lean}"

    def _interpolate_family(self, family: str, lean: int) -> tuple[DictionaryEntry, int]:
        """Return (entry, resolved_lean) for the requested leanness.

        ``resolved_lean`` is the lean the returned entry actually represents: the request
        itself for an exact anchor or an interpolated profile, but the clamped anchor's lean
        when the request is outside the curated range — so the caller reports the ratio
        actually used, not the unrepresentable request (RT-14).
        """
        anchors = self._families[family]
        if lean in anchors:
            return anchors[lean], lean

        leans = sorted(anchors)
        if lean <= leans[0]:
            return anchors[leans[0]], leans[0]
        if lean >= leans[-1]:
            return anchors[leans[-1]], leans[-1]

        lower = max(x for x in leans if x < lean)
        upper = min(x for x in leans if x > lean)
        lo, hi = anchors[lower], anchors[upper]
        t = (lean - lower) / (upper - lower)

        def lerp(a: float, b: float) -> float:
            return round(a + (b - a) * t, 2)

        profile = NutrientProfile(
            kcal=lerp(lo.profile.kcal, hi.profile.kcal),
            protein=lerp(lo.profile.protein, hi.profile.protein),
            carbs=lerp(lo.profile.carbs, hi.profile.carbs),
            fat=lerp(lo.profile.fat, hi.profile.fat),
            fiber=lerp(lo.profile.fiber, hi.profile.fiber),
        )
        synthetic = DictionaryEntry(
            canonical_name=f"{family} {lean}/{100 - lean}",
            aliases=(),
            profile=profile,
            basis_state=lo.basis_state,
            unit_conversions=dict(lo.unit_conversions),
            raw_cooked_factor=lo.raw_cooked_factor,
            serving_grams=lo.serving_grams,
        )
        return synthetic, lean  # interpolated profile represents the requested lean exactly


# Module-level singleton: the seed is static, so load once.
_DICTIONARY: FoodDictionary | None = None


def get_dictionary() -> FoodDictionary:
    global _DICTIONARY  # noqa: PLW0603 — intentional process-wide cache of static seed data
    if _DICTIONARY is None:
        _DICTIONARY = FoodDictionary.from_seed()
    return _DICTIONARY


# ---------------------------------------------------------------------------
# Modifier math — fixed multipliers from PARSER_CONTRACT.md principle #4.
# The parser already encodes "double"→amount 2 etc.; this table is the canonical
# definition used by the few-shot prompt and by tests that assert the contract.
# ---------------------------------------------------------------------------
SERVING_MODIFIERS: dict[str, float] = {
    "double": 2.0,
    "triple": 3.0,
    "extra": 1.5,
    "light": 0.5,
    "easy on the": 0.5,
    "half": 0.5,
}


def apply_modifier(modifier: str, standard_servings: float = 1.0) -> float:
    """Resolve a spoken modifier to a serving multiplier (× standard serving)."""
    return SERVING_MODIFIERS.get(modifier.lower().strip(), 1.0) * standard_servings
