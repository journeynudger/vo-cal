"""Clarifying-question engine (P0 item 7) + answer-merge.

Implements the single source-of-truth rule from docs/PARSER_CONTRACT.md — the
ONLY place the 75 kcal / 10 g threshold and the at-most-one rule are coded. No
prompt or screen restates the numbers.

For each parser ``missing_details`` candidate, this engine deterministically
computes the macro spread across the plausible range of the unknown by
*re-resolving the affected item under each alternative* and diffing the results.
A question fires only when the max spread on any single macro exceeds:

    THRESHOLD_KCAL = 75   OR   THRESHOLD_MACRO_G = 10  (protein, carbs, or fat)

When multiple candidates clear the threshold, exactly ONE is selected — the one
with the highest macro impact (ranked by a combined kcal-and-grams impact). The
rest are dropped silently; their uncertainty is priced into per-item confidence,
not asked.

Answer-merge (B5 step 3): applying a user's answer re-resolves ONLY the affected
item — no full re-parse. The other items' resolutions are untouched.

The thresholds and plausible ranges are deterministic Python (AGENTS.md #6); the
LLM only proposes the candidate list.
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

_FIELD_RE = re.compile(r"items\[(\d+)\]\.(\w+)")

# Plausible alternatives per unknown field.
_PLAUSIBLE_FAT_RATIOS = ("70/30", "93/7")  # fattiest vs leanest common ground beef
_PLAUSIBLE_STATES = (State.RAW, State.COOKED)

# Plausible amount range (× standard serving) by the parser's importance prior.
# A genuinely vague amount ("a bowl of rice", HIGH) spans a wide range; a roughly
# discrete portion ("a chicken breast", LOW) is close to one serving. The parser
# encodes which it is via importance (PARSER_CONTRACT.md: importance is the
# parser's prior on macro impact); the engine reads that prior here.
_AMOUNT_RANGE_BY_IMPORTANCE: dict[Importance, tuple[float, float]] = {
    Importance.HIGH: (0.5, 1.5),
    Importance.MEDIUM: (0.6, 1.4),
    Importance.LOW: (0.85, 1.15),
}


@dataclass(frozen=True)
class QuestionDecision:
    """The engine's verdict: the one question to ask (or None), plus diagnostics."""

    question: MissingDetail | None
    spreads: dict[str, float]  # field → max macro spread (kcal-equivalent impact), for audit


def _parse_field(field: str) -> tuple[int, str] | None:
    m = _FIELD_RE.match(field)
    if m is None:
        return None
    return int(m.group(1)), m.group(2)


def _impact(low: Macros, high: Macros) -> tuple[float, bool]:
    """Return (combined-impact-score, clears_threshold) for a macro spread."""
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
    # Rank by kcal plus a gram surcharge so a big macro swing at modest kcal
    # (e.g. fat ratio) still outranks a small one.
    score = d_kcal + 4 * (d_protein + d_carbs + d_fat)
    return score, clears


def _with(item: ParsedItem, **changes) -> ParsedItem:
    return item.model_copy(update=changes)


def _alternatives(
    item: ParsedItem, attr: str, importance: Importance
) -> tuple[ParsedItem, ParsedItem] | None:
    """Two plausible-extreme variants of `item` for the unknown attribute."""
    if attr == "fat_ratio":
        lo, hi = _PLAUSIBLE_FAT_RATIOS
        return _with(item, fat_ratio=lo), _with(item, fat_ratio=hi)
    if attr == "amount":
        lo, hi = _AMOUNT_RANGE_BY_IMPORTANCE[importance]
        # Evaluate as serving multipliers (unit cleared) regardless of any null unit.
        return (
            _with(item, amount=lo, unit=None),
            _with(item, amount=hi, unit=None),
        )
    if attr == "state":
        lo, hi = _PLAUSIBLE_STATES
        return _with(item, state=lo), _with(item, state=hi)
    if attr == "unit":  # rare: ambiguous unit
        return None
    return None


class ClarifyEngine:
    """Decides the single clarifying question for a parsed meal."""

    def __init__(self, resolver: Resolver | None = None) -> None:
        self._resolver = resolver or Resolver()

    async def decide(
        self, items: list[ParsedItem], candidates: list[MissingDetail]
    ) -> QuestionDecision:
        """Evaluate every candidate; return the single highest-impact question over threshold."""
        spreads: dict[str, float] = {}
        best: tuple[float, MissingDetail] | None = None

        for candidate in candidates:
            parsed = _parse_field(candidate.field)
            if parsed is None:
                continue
            idx, attr = parsed
            if not (0 <= idx < len(items)):
                continue

            alts = _alternatives(items[idx], attr, candidate.importance)
            if alts is None:
                continue
            lo_item, hi_item = alts
            lo = await self._resolver.resolve_item(lo_item)
            hi = await self._resolver.resolve_item(hi_item)
            score, clears = _impact(lo.macros, hi.macros)
            spreads[candidate.field] = round(score, 2)
            if clears and (best is None or score > best[0]):
                best = (score, candidate)

        return QuestionDecision(question=best[1] if best else None, spreads=spreads)

    async def merge_answer(
        self, items: list[ParsedItem], field: str, value: object
    ) -> list[ParsedItem]:
        """Apply a user answer to the affected item only; return the updated item list.

        Re-resolution of the single item happens downstream (the caller re-runs
        the resolver); this just produces the corrected ParsedItem list without a
        re-parse, per the contract's answer-merge rule.
        """
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
        if attr == "state":
            return _with(item, state=State(str(value)))
        if attr == "amount":
            # Answer may be "1 cup", "150g", or a bare number of servings.
            amount, unit = _parse_amount_answer(value)
            return _with(item, amount=amount, unit=unit)
        if attr == "unit":
            return _with(item, unit=Unit(str(value)))
        return item


def _parse_amount_answer(value: object) -> tuple[float, Unit | None]:
    """Parse a user's amount answer into (amount, unit).

    Accepts a bare number (servings), or a string like "150g" / "1 cup" / "2 oz".
    """
    if isinstance(value, int | float):
        return float(value), None
    text = str(value).strip().lower()
    m = re.match(r"^([\d.]+)\s*([a-z]*)$", text)
    if m:
        amount = float(m.group(1))
        unit_str = m.group(2)
        unit_map = {u.value: u for u in Unit}
        # accept common aliases
        unit_str = {"grams": "g", "gram": "g", "ounce": "oz", "ounces": "oz", "cups": "cup"}.get(
            unit_str, unit_str
        )
        return amount, unit_map.get(unit_str)
    return 1.0, None
