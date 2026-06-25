"""Per-item and meal confidence scoring (P0 item 6).

Confidence ∈ [0,1] is the trust arithmetic the UI surfaces (gold numerals) and
the clarify engine reads. It is the product of three independent signals:

    confidence = llm_extraction × match_quality × amount_specificity

- **llm_extraction**  — the parser's own confidence the item is what was said
  (ParsedItem.confidence). Mumbled/ambiguous mentions arrive lower.
- **match_quality**   — how trustworthy the resolution was, by match kind:
  dictionary-canonical (1.0) > parameterized ground-meat (0.95) > alias (0.92) >
  family default (0.7) > FDC top hit (0.6) > unresolved (0.0). This is the
  resolver's ``match_score``.
- **amount_specificity** — how precisely the quantity was pinned: stated mass
  (1.0) > stated volume (0.95) > stated count (0.9) > serving multiplier (0.8) >
  inferred serving (0.65). Less-specified amounts mean a wider true range, so
  lower confidence even when the food itself resolved cleanly.

Calibration table (the multipliers below) is deliberately conservative: a fully
specified dictionary food the user enunciated clearly lands ~0.95+, while an
unresolved guess floors near 0. The numbers are tuned against the fixture corpus
(scripts/parser-eval) and may be re-calibrated there; they are NOT model output.

Meal-level confidence is the calorie-weighted mean of item confidences — a
low-confidence rounding-error garnish should not drag down a meal dominated by a
cleanly-resolved steak. Zero-calorie items (water, the container item) fall back
to an unweighted contribution so they are not silently ignored.
"""

from __future__ import annotations

from ..nutrition.resolver import ResolvedItem
from ..nutrition.schemas import AmountSpecificity

# Amount-specificity → confidence multiplier (calibration table).
_SPECIFICITY_FACTOR: dict[AmountSpecificity, float] = {
    AmountSpecificity.STATED_MASS: 1.0,
    AmountSpecificity.STATED_VOLUME: 0.95,
    AmountSpecificity.STATED_COUNT: 0.9,
    AmountSpecificity.SERVING_MULTIPLIER: 0.8,
    AmountSpecificity.INFERRED_SERVING: 0.65,
}


def item_confidence(resolved: ResolvedItem) -> float:
    """Composite per-item confidence in [0,1]."""
    if resolved.match_score == 0.0:
        return 0.0  # unresolved — no trustworthy macros at all
    llm = resolved.item.confidence
    match = resolved.match_score
    specificity = _SPECIFICITY_FACTOR[resolved.amount_specificity]
    return round(llm * match * specificity, 4)


def meal_confidence(resolved: list[ResolvedItem]) -> float:
    """Calorie-weighted mean of item confidences.

    Items with zero calories (containers, black coffee) carry no calorie weight,
    so they fall into an unweighted tail averaged in with a nominal weight — they
    still count, but cannot dominate. With no items at all, confidence is 0.
    """
    if not resolved:
        return 0.0

    confidences = [item_confidence(r) for r in resolved]
    weights = [max(r.macros.kcal, 0.0) for r in resolved]
    total_weight = sum(weights)

    if total_weight == 0:
        return round(sum(confidences) / len(confidences), 4)

    # An UNRESOLVED item (match_score 0) has zero macros not because it's a garnish but because
    # we FAILED to resolve it — an unknown-size gap in the totals, not a harmless zero. Weight it
    # like a typical resolved item so its 0.0 confidence actually drags the meal down (RT-17),
    # rather than being dismissed as a zero-calorie garnish. Genuinely zero-calorie RESOLVED items
    # (water, black coffee) keep the small floor weight.
    n_caloric = sum(1 for w in weights if w > 0)
    avg_caloric = total_weight / n_caloric if n_caloric else total_weight
    floor = total_weight / (len(resolved) * 20)  # ~5% of average item weight

    def weight_for(r: ResolvedItem, w: float) -> float:
        if w > 0:
            return w
        if r.match_score == 0.0:
            return avg_caloric  # unresolved gap: count it like a real item
        return floor  # genuine zero-calorie resolved garnish

    num = sum(
        c * weight_for(r, w) for c, r, w in zip(confidences, resolved, weights, strict=True)
    )
    den = sum(weight_for(r, w) for r, w in zip(resolved, weights, strict=True))
    return round(num / den, 4)
