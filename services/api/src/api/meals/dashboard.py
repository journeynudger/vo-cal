"""Compose Today for a mode (decision 60): the planner between the stores and the screen.

Pure: (projection, focus, targets, consumed, remaining, band, meals today) → panels. The engine
computed every target; this decides which the person asked to see and how each completes. One
progress language on the page (a header over a bar): every panel is a tile or the calories
card, never a ring (the Rams review, R7). The client renders kinds and skips unknown ones.
"""

from __future__ import annotations

from collections.abc import Sequence

from ..tracking.projection import Projection, extra_metrics
from ..tracking.schemas import FocusMetric, TrackingMode
from .today import Consumed, Panel, Remaining, Targets

# Calories "land" when the day ends inside this window of the target (the card's existing
# completion rule on the client, moved server-side so every mode shares it).
_CALORIES_LOW = 0.90
_CALORIES_HIGH = 1.05

_TITLES: dict[str, str] = {
    "kcal": "Calories left",
    "protein": "Protein",
    "carbs": "Carbs",
    "fat": "Fat",
    "fiber": "Fiber",
    "water": "Water",
    "produce": "Produce",
    "sugar": "Sugar",
    "sodium": "Sodium",
    "logged": "Logged today",
}
_UNITS: dict[str, str] = {
    "kcal": "cal",
    "protein": "g",
    "carbs": "g",
    "fat": "g",
    "fiber": "g",
    "sugar": "g",
    "water": "oz",
    "sodium": "mg",
    "produce": "",
    "logged": "",
}
# Less is the goal for these; the tile never completes and turns over past the target.
_STAY_UNDER: frozenset[str] = frozenset({"sugar", "sodium"})


def compose(
    projection: Projection,
    focus: Sequence[FocusMetric],
    targets: Targets,
    consumed: Consumed,
    remaining: Remaining,
    *,
    protein_band: tuple[float, float],
    meals_today: int,
) -> list[Panel]:
    """The ordered panels for the mode plus the focus metrics it does not already print."""
    mode = projection.mode
    panels: list[Panel] = []
    if mode is TrackingMode.HABITS:
        panels.append(_habit_logged(meals_today))
        panels.append(_tile("water", targets, consumed, remaining, can_add=True))
        panels.append(_tile("produce", targets, consumed, remaining))
    elif mode is TrackingMode.CALORIES:
        panels.append(_calories(targets, consumed, remaining))
    elif mode is TrackingMode.MACROS:
        panels.append(_calories(targets, consumed, remaining))
        panels.append(_tile("protein", targets, consumed, remaining, band=protein_band))
        panels.append(_tile("carbs", targets, consumed, remaining))
        panels.append(_tile("fat", targets, consumed, remaining))
    else:  # FIVE and, until the plan builder ships, MEAL_PLAN
        panels.append(_calories(targets, consumed, remaining))
        panels.append(_tile("protein", targets, consumed, remaining, band=protein_band))
        panels.append(_tile("produce", targets, consumed, remaining))
        panels.append(_tile("water", targets, consumed, remaining, can_add=True))
        panels.append(_tile("fiber", targets, consumed, remaining))

    for metric in extra_metrics(mode, list(focus)):
        panel = _tile(
            metric.value,
            targets,
            consumed,
            remaining,
            band=protein_band if metric is FocusMetric.PROTEIN else None,
            can_add=metric is FocusMetric.WATER,
        )
        if panel is not None:
            panels.append(panel)
    return [p for p in panels if p is not None]


def _calories(targets: Targets, consumed: Consumed, remaining: Remaining) -> Panel:
    target = targets.kcal
    eaten = consumed.kcal
    ratio = eaten / target if target > 0 else 0.0
    return Panel(
        kind="calories_left",
        metric="kcal",
        title=_TITLES["kcal"],
        consumed=eaten,
        target=target,
        remaining=remaining.kcal,
        unit=_UNITS["kcal"],
        direction="land",
        complete=target > 0 and _CALORIES_LOW <= ratio <= _CALORIES_HIGH,
        over=eaten > target,
        support=f"of {target:,.0f} today",
    )


def _tile(
    metric: str,
    targets: Targets,
    consumed: Consumed,
    remaining: Remaining,
    *,
    band: tuple[float, float] | None = None,
    can_add: bool = False,
) -> Panel | None:
    target = _num(getattr(targets, metric, None))
    eaten = _num(getattr(consumed, metric, None))
    if target is None or eaten is None or target <= 0:
        return None  # not a metric the model carries, or no target to measure against
    left = _num(getattr(remaining, metric, None))
    if left is None:
        left = round(target - eaten, 1)
    unit = _UNITS.get(metric, "")
    unknown = int(getattr(consumed, f"{metric}_unknown_items", 0) or 0)

    if metric in _STAY_UNDER:
        return Panel(
            kind="metric_tile",
            metric=metric,
            title=_TITLES.get(metric, metric.title()),
            consumed=eaten,
            target=target,
            remaining=left,
            unit=unit,
            direction="stay_under",
            complete=False,
            over=eaten > target > 0,
            # The value line says "38 / 45 g"; the one thing it cannot say is what was not
            # counted, so that is the whole support line, and nothing when every food was known.
            support=f"{unknown} food{'s' if unknown != 1 else ''} not known" if unknown else "",
            unknown_items=unknown,
        )

    if band is not None and band[0] < band[1] and metric == "protein":
        low, high = band
        return Panel(
            kind="metric_tile",
            metric=metric,
            title=_TITLES[metric],
            consumed=eaten,
            target=target,
            remaining=left,
            unit=unit,
            direction="land",
            complete=low <= eaten <= high,
            over=eaten > high,
            band_low=low,
            band_high=high,
            support=_band_support(eaten, low, high),
            can_add=can_add,
        )

    # A tile prints "72 / 96 oz" itself; a line repeating the target under it is clutter. The
    # calories card alone carries "of 1,805 today", because its numeral is what is left.
    return Panel(
        kind="metric_tile",
        metric=metric,
        title=_TITLES.get(metric, metric.title()),
        consumed=eaten,
        target=target,
        remaining=left,
        unit=unit,
        direction="reach",
        complete=target > 0 and eaten >= target,
        over=False,
        support="",
        can_add=can_add,
        unknown_items=unknown,
    )


def _band_support(eaten: float, low: float, high: float) -> str:
    """The protein line, strength-based and calm (decision 28): under is "more to go", never a
    failure; inside is the optimal range; over is a quiet note. The client colours the inside
    case; the words are the server's so every client says the same thing."""
    if eaten < low:
        return f"{low - eaten:,.0f} g to optimal"
    if eaten > high:
        return f"{eaten - high:,.0f} g over optimal"
    return "In your optimal range"


def _habit_logged(meals_today: int) -> Panel:
    """The one habit with no nutrient behind it: a day with at least one log. The support line
    says what the person did, in their words, never a streak (6.7, users not consumers)."""
    if meals_today <= 0:
        support = "Not yet"
    elif meals_today == 1:
        support = "1 meal"
    else:
        support = f"{meals_today} meals"
    return Panel(
        kind="habit_tile",
        metric="logged",
        title=_TITLES["logged"],
        consumed=float(meals_today),
        target=1.0,
        remaining=float(max(0, 1 - meals_today)),
        unit="",
        direction="reach",
        complete=meals_today >= 1,
        support=support,
    )


def _num(value: object) -> float | None:
    if value is None:
        return None
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
