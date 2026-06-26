"""Clarifying-question engine (P0 item 7, decision #29) + answer-merge.

The ONLY place the threshold is coded (single source of truth, docs/PARSER_CONTRACT.md):

    THRESHOLD_KCAL = 75   OR   THRESHOLD_MACRO_G = 10  (protein, carbs, or fat)

A check fires only when the unknown could move the meal past the threshold. The
old one-question-per-meal cap is gone (decision #29): EVERY material ingredient
that clears the threshold gets its own check. Candidates come from two places:

1. **LLM-proposed** ``missing_details`` (fat_ratio / amount / state) — priced by
   re-resolving the affected item under each plausible extreme.
2. **Engine-synthesized variant checks** — when a resolved item matched a food
   with a variant family (whole/fat-free cheddar, regular/light mayo, …) and the
   user did not name one, the engine prices the spread across the dictionary's
   per-variant macros. The LLM does not need to propose these; the engine knows
   which foods have material variants.

Clearing candidates are ranked by macro impact (highest first) and capped at
``MAX_QUESTIONS`` so a pathological meal cannot produce an endless quiz. Answers
merge per-axis onto the affected item (no re-parse); the caller re-resolves.

All thresholds and ranges are deterministic Python (AGENTS.md #6).
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass

from ..nutrition.resolver import Resolver
from ..nutrition.schemas import Macros, MatchKind
from .schemas import Importance, MissingDetail, ParsedItem, State, Unit

# An amount answer is a bare number or "150g" / "1 cup". A fat-ratio answer is "NN/NN" (the
# contract form, e.g. "93/7"). Inputs that don't match are IGNORED, never coerced — coercing
# a non-answer to amount=1.0 (or writing a non-positive/NaN amount, or a contract-invalid ratio,
# straight past ParsedItem's gt=0/format validation via model_copy) corrupts the resolved macros.
_AMOUNT_ANSWER_RE = re.compile(r"^([\d.]+)\s*([a-z]*)$")
_FAT_RATIO_ANSWER_RE = re.compile(r"^\d{2,3}/\d{1,2}$")
_UNIT_ALIASES = {"grams": "g", "gram": "g", "ounce": "oz", "ounces": "oz", "cups": "cup"}

# THE threshold — single source of truth (docs/PARSER_CONTRACT.md).
THRESHOLD_KCAL = 75.0
THRESHOLD_MACRO_G = 10.0
# Variant ("which product?") axes get a LOWER bar (decision #29 / cofounder
# intent): picking whole vs fat-free cheddar or regular vs light mayo is a single
# tap among known options — cheap and certain — so it is worth asking at a
# smaller swing than a vague amount estimate. At one slice/tbsp these swings are
# ~50-70 kcal; this bar makes the engine ask them, as Francesco wants.
VARIANT_THRESHOLD_KCAL = 40.0
VARIANT_THRESHOLD_MACRO_G = 4.0
# A meal cannot ask more than this many checks (decision #29: per material
# ingredient, but bounded so a 20-ingredient stir-fry is not a quiz).
MAX_QUESTIONS = 4

_FIELD_RE = re.compile(r"items\[(\d+)\]\.(\w+)")
_PLAUSIBLE_FAT_RATIOS = ("70/30", "93/7")
# For an unspecified ground-meat fat ratio, price the FULL curated spread: these extremes
# clamp to the fattiest / leanest anchor of whichever family resolved (RT-16).
_GROUND_MEAT_RATIO_EXTREMES = ("70/30", "99/1")
_PLAUSIBLE_STATES = (State.RAW, State.COOKED)
_FAT_RATIO_OPTIONS = ("80/20", "85/15", "90/10", "93/7")
_STATE_OPTIONS = ("raw", "cooked")

_AMOUNT_RANGE_BY_IMPORTANCE: dict[Importance, tuple[float, float]] = {
    Importance.HIGH: (0.5, 1.5),
    Importance.MEDIUM: (0.6, 1.4),
    Importance.LOW: (0.85, 1.15),
}


@dataclass(frozen=True)
class QuestionDecision:
    """The engine's verdict: every check to ask (ranked, capped), plus diagnostics."""

    questions: list[MissingDetail]
    spreads: dict[str, float]  # field → macro-impact score, for audit/calibration


def _parse_field(field: str) -> tuple[int, str] | None:
    m = _FIELD_RE.match(field)
    if m is None:
        return None
    return int(m.group(1)), m.group(2)


def _impact(
    low: Macros,
    high: Macros,
    kcal_threshold: float = THRESHOLD_KCAL,
    macro_threshold: float = THRESHOLD_MACRO_G,
) -> tuple[float, bool]:
    """Return (impact-score, clears_threshold) for a macro spread."""
    d_kcal = abs(high.kcal - low.kcal)
    d_protein = abs(high.protein - low.protein)
    d_carbs = abs(high.carbs - low.carbs)
    d_fat = abs(high.fat - low.fat)
    clears = (
        d_kcal > kcal_threshold
        or d_protein > macro_threshold
        or d_carbs > macro_threshold
        or d_fat > macro_threshold
    )
    score = d_kcal + 4 * (d_protein + d_carbs + d_fat)
    return score, clears


def _bounding(macros_list: list[Macros]) -> tuple[Macros, Macros]:
    """Per-macro min/max box across a set of variant macros (different variants
    peak on different macros, so we bound each axis independently)."""
    lo = Macros(
        kcal=min(m.kcal for m in macros_list),
        protein=min(m.protein for m in macros_list),
        carbs=min(m.carbs for m in macros_list),
        fat=min(m.fat for m in macros_list),
    )
    hi = Macros(
        kcal=max(m.kcal for m in macros_list),
        protein=max(m.protein for m in macros_list),
        carbs=max(m.carbs for m in macros_list),
        fat=max(m.fat for m in macros_list),
    )
    return lo, hi


def _with(item: ParsedItem, **changes) -> ParsedItem:
    return item.model_copy(update=changes)


def _alternatives(
    item: ParsedItem, attr: str, importance: Importance
) -> tuple[ParsedItem, ParsedItem] | None:
    if attr == "fat_ratio":
        lo, hi = _PLAUSIBLE_FAT_RATIOS
        return _with(item, fat_ratio=lo), _with(item, fat_ratio=hi)
    if attr == "amount":
        lo, hi = _AMOUNT_RANGE_BY_IMPORTANCE[importance]
        return _with(item, amount=lo, unit=None), _with(item, amount=hi, unit=None)
    if attr == "state":
        lo, hi = _PLAUSIBLE_STATES
        return _with(item, state=lo), _with(item, state=hi)
    return None


def _already_set(item: ParsedItem, attr: str) -> bool:
    """True when the item already carries this axis (so it is not a missing detail)."""
    if attr == "fat_ratio":
        return item.fat_ratio is not None
    if attr == "amount":
        return item.amount is not None
    if attr == "state":
        return item.state is not State.UNSPECIFIED
    return False


def _options_for(attr: str) -> list[str] | None:
    if attr == "fat_ratio":
        return list(_FAT_RATIO_OPTIONS)
    if attr == "state":
        return list(_STATE_OPTIONS)
    return None  # amount is free entry


class ClarifyEngine:
    """Decides the set of clarifying checks for a parsed meal (one per material axis)."""

    def __init__(self, resolver: Resolver | None = None) -> None:
        self._resolver = resolver or Resolver()

    async def decide(
        self, items: list[ParsedItem], candidates: list[MissingDetail]
    ) -> QuestionDecision:
        spreads: dict[str, float] = {}
        scored: list[tuple[float, MissingDetail]] = []
        seen: set[str] = set()

        # 1. LLM-proposed candidates (fat_ratio / amount / state).
        for candidate in candidates:
            parsed = _parse_field(candidate.field)
            if parsed is None:
                continue
            idx, attr = parsed
            if not (0 <= idx < len(items)):
                continue
            if _already_set(items[idx], attr):
                continue  # user already specified this axis (e.g. answered) → not missing
            alts = _alternatives(items[idx], attr, candidate.importance)
            if alts is None:
                continue
            lo = await self._resolver.resolve_item(alts[0])
            hi = await self._resolver.resolve_item(alts[1])
            score, clears = _impact(lo.macros, hi.macros)
            spreads[candidate.field] = round(score, 2)
            if clears:
                scored.append((score, candidate.model_copy(update={"options": _options_for(attr)})))
                seen.add(candidate.field)

        # 2. Engine-synthesized material-axis checks (decision #29): the engine knows
        #    which foods have a material axis; the LLM need not propose them.
        for idx, item in enumerate(items):
            check = await self._synthesized_check(idx, item)
            if check is None:
                continue
            field, score, clears, detail = check
            if field in seen:
                continue
            spreads[field] = round(score, 2)
            if clears:
                scored.append((score, detail))

        scored.sort(key=lambda t: t[0], reverse=True)
        return QuestionDecision(questions=[q for _, q in scored[:MAX_QUESTIONS]], spreads=spreads)

    async def _synthesized_check(
        self, idx: int, item: ParsedItem
    ) -> tuple[str, float, bool, MissingDetail] | None:
        """A material-axis check the engine synthesizes for one item, or None when the item
        carries no unspecified material axis. Returns (field, impact-score, clears, question)."""
        resolved = await self._resolver.resolve_item(item)

        # Variant-family foods (whole/fat-free cheddar, regular/light mayo, …): price the
        # spread across the dictionary's per-variant macros.
        if resolved.variant_unspecified and resolved.variant_macros:
            field = f"items[{idx}].variant"
            lo, hi = _bounding(list(resolved.variant_macros.values()))
            score, clears = _impact(lo, hi, VARIANT_THRESHOLD_KCAL, VARIANT_THRESHOLD_MACRO_G)
            detail = MissingDetail(
                field=field,
                importance=Importance.HIGH,
                question=f"Which {item.name}?",
                options=list(resolved.variant_family or resolved.variant_macros.keys()),
            )
            return field, score, clears, detail

        # Ground-meat family default with no stated ratio: fat content is a material single-tap
        # choice (like a variant). Price the full curated spread (the extremes clamp to the
        # fattiest/leanest anchor) so a bare "ground turkey" asks instead of silently logging
        # the ~85/15 default (RT-16).
        if resolved.match_kind is MatchKind.FAMILY_DEFAULT and item.fat_ratio is None:
            field = f"items[{idx}].fat_ratio"
            lo = await self._resolver.resolve_item(
                _with(item, fat_ratio=_GROUND_MEAT_RATIO_EXTREMES[0])
            )
            hi = await self._resolver.resolve_item(
                _with(item, fat_ratio=_GROUND_MEAT_RATIO_EXTREMES[1])
            )
            score, clears = _impact(
                lo.macros, hi.macros, VARIANT_THRESHOLD_KCAL, VARIANT_THRESHOLD_MACRO_G
            )
            detail = MissingDetail(
                field=field,
                importance=Importance.HIGH,
                question=f"What fat content for the {item.name}?",
                options=list(_FAT_RATIO_OPTIONS),
            )
            return field, score, clears, detail

        return None

    async def merge_answer(
        self, items: list[ParsedItem], field: str, value: object
    ) -> list[ParsedItem]:
        """Apply a user's answer to the affected item only (no re-parse)."""
        parsed = _parse_field(field)
        if parsed is None:
            return items
        idx, attr = parsed
        if not (0 <= idx < len(items)):
            return items
        updated = list(items)
        updated[idx] = self._apply(items[idx], attr, value)
        return updated

    @staticmethod
    def _apply(item: ParsedItem, attr: str, value: object) -> ParsedItem:
        # Each branch validates before _with (which uses model_copy and so SKIPS field
        # validators): a bad answer is ignored (item unchanged), never written as a poisoned
        # value or raised as a 500.
        if attr == "fat_ratio":
            ratio = str(value)
            return _with(item, fat_ratio=ratio) if _FAT_RATIO_ANSWER_RE.match(ratio) else item
        if attr == "variant":
            return _with(item, variant=str(value))
        if attr == "state":
            try:
                return _with(item, state=State(str(value)))
            except ValueError:
                return item
        if attr == "amount":
            parsed = _parse_amount_answer(value)
            return _with(item, amount=parsed[0], unit=parsed[1]) if parsed else item
        if attr == "unit":
            try:
                return _with(item, unit=Unit(str(value)))
            except ValueError:
                return item
        return item


def _parse_amount_answer(value: object) -> tuple[float, Unit | None] | None:
    """Parse an amount answer into (amount, unit), or None when it isn't a usable POSITIVE,
    finite amount. Returning None means "ignore this answer" — we never fabricate a quantity
    (which would falsely raise confidence) or write a non-positive/NaN amount (which would
    bypass ParsedItem.amount's gt=0 contract via model_copy and corrupt the macros)."""
    if isinstance(value, bool):  # bool is an int subclass — never a quantity
        return None
    unit: Unit | None = None
    if isinstance(value, int | float):
        amount = float(value)
    else:
        m = _AMOUNT_ANSWER_RE.match(str(value).strip().lower())
        if not m:
            return None
        amount = float(m.group(1))
        unit_str = _UNIT_ALIASES.get(m.group(2), m.group(2))
        unit = {u.value: u for u in Unit}.get(unit_str)
    if not math.isfinite(amount) or amount <= 0:
        return None
    return amount, unit
