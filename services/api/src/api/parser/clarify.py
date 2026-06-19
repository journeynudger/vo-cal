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

import re
from dataclasses import dataclass

from ..nutrition.resolver import Resolver
from ..nutrition.schemas import Macros
from .schemas import Importance, MissingDetail, ParsedItem, State, Unit

# THE threshold — single source of truth (docs/PARSER_CONTRACT.md).
THRESHOLD_KCAL = 75.0
THRESHOLD_MACRO_G = 10.0
# A meal cannot ask more than this many checks (decision #29: per material
# ingredient, but bounded so a 20-ingredient stir-fry is not a quiz).
MAX_QUESTIONS = 4

_FIELD_RE = re.compile(r"items\[(\d+)\]\.(\w+)")
_PLAUSIBLE_FAT_RATIOS = ("70/30", "93/7")
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


def _impact(low: Macros, high: Macros) -> tuple[float, bool]:
    """Return (impact-score, clears_threshold) for a macro spread."""
    d_kcal = abs(high.kcal - low.kcal)
    d_protein = abs(high.protein - low.protein)
    d_carbs = abs(high.carbs - low.carbs)
    d_fat = abs(high.fat - low.fat)
    clears = (
        d_kcal > THRESHOLD_KCAL
        or d_protein > THRESHOLD_MACRO_G
        or d_carbs > THRESHOLD_MACRO_G
        or d_fat > THRESHOLD_MACRO_G
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

        # 2. Engine-synthesized variant checks (decision #29): the engine knows
        #    which foods have a material variant axis; the LLM need not propose them.
        for idx, item in enumerate(items):
            resolved = await self._resolver.resolve_item(item)
            if not (resolved.variant_unspecified and resolved.variant_macros):
                continue
            field = f"items[{idx}].variant"
            if field in seen:
                continue
            lo, hi = _bounding(list(resolved.variant_macros.values()))
            score, clears = _impact(lo, hi)
            spreads[field] = round(score, 2)
            if clears:
                scored.append((
                    score,
                    MissingDetail(
                        field=field,
                        importance=Importance.HIGH,
                        question=f"Which {item.name}?",
                        options=list(resolved.variant_family or resolved.variant_macros.keys()),
                    ),
                ))

        scored.sort(key=lambda t: t[0], reverse=True)
        return QuestionDecision(questions=[q for _, q in scored[:MAX_QUESTIONS]], spreads=spreads)

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
        if attr == "fat_ratio":
            return _with(item, fat_ratio=str(value))
        if attr == "variant":
            return _with(item, variant=str(value))
        if attr == "state":
            return _with(item, state=State(str(value)))
        if attr == "amount":
            amount, unit = _parse_amount_answer(value)
            return _with(item, amount=amount, unit=unit)
        if attr == "unit":
            return _with(item, unit=Unit(str(value)))
        return item


def _parse_amount_answer(value: object) -> tuple[float, Unit | None]:
    """Parse an amount answer into (amount, unit): a bare number, or "150g" / "1 cup"."""
    if isinstance(value, int | float):
        return float(value), None
    text = str(value).strip().lower()
    m = re.match(r"^([\d.]+)\s*([a-z]*)$", text)
    if m:
        amount = float(m.group(1))
        unit_str = {"grams": "g", "gram": "g", "ounce": "oz", "ounces": "oz", "cups": "cup"}.get(
            m.group(2), m.group(2)
        )
        return amount, {u.value: u for u in Unit}.get(unit_str)
    return 1.0, None
