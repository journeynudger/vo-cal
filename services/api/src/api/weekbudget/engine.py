"""Weekly budget math — pure, deterministic, unit-tested in isolation.

The LLM extracts; THIS code calculates (AGENTS.md #6). Everything here is a
function of (week_start, today, baseline, plan, consumed, logged): no clocks,
no I/O, no randomness — the router supplies the tz-resolved "today" and the
durable rows, the engine turns them into numbers. Same inputs, same output.

Semantics (a rolling week that only ever tightens):
  - carry = Σ over PAST TRACKED days of min(0, planned − consumed): an overage
    carries forward as a cut, a shortfall carries NOTHING. A tracked day that
    reads under plan is indistinguishable from an unfinished log (one coffee at
    8 AM is a log), and until 2026-09-24 every such day banked "headroom" that
    told the person to make up three days of calories in the days left. A
    thin day is a thin day; the plan for the rest of the week does not rise.
  - A past day with no live meal log is NOT TRACKED: it contributes zero and is
    assumed on plan (facts-first, AGENTS.md #4: never claim more than the facts).
  - Remaining days (today + future) absorb the carry equally, clamped per day
    to [max(1200, planned − 0.25·baseline), planned + 0.25·baseline]; clamped
    residual waterfalls onto the still-open days (≤ 7 passes — each pass either
    clamps a day or absorbs everything, so 7 always terminates).
  - Past days never move: adjusted = planned (history is history).
"""

from __future__ import annotations

from collections.abc import Collection, Mapping
from dataclasses import dataclass
from datetime import date, timedelta

# Hard floor on any adjusted daily target. Below ~1200 kcal a "budget" stops
# being a nudge and starts being a directive no consumer app should issue.
FLOOR_KCAL = 1200.0

# Per-day swing band around the plan, as a fraction of the baseline. A day may
# absorb at most ±25% of baseline of carry — one heavy Saturday must not turn
# Sunday into a fast (or a binge).
SWING_FRACTION = 0.25

# Distribution passes are bounded by the week length: every pass either clamps
# at least one day (≤ 7 total) or absorbs the whole residual and stops.
_MAX_PASSES = 7

# Float-noise guard for "is the residual actually zero" — kcal live in the
# thousands, so anything under a millionth of a kcal is arithmetic dust.
_EPSILON = 1e-6


@dataclass(frozen=True)
class ComputedDay:
    day: date
    weekday: int  # 0 = Monday
    planned: float
    adjusted: int  # whole kcal (see _round_days)
    consumed: float
    logged: bool
    state: str  # "past" | "today" | "future"


@dataclass(frozen=True)
class ComputedWeek:
    week_start: date
    week_end: date
    baseline: float
    weekly_target: float  # Σ planned
    carry: float
    remaining_kcal: float  # Σ remaining adjusted − today's consumed (0 for a past week)
    fully_rebalanced: bool
    leftover_kcal: float  # carry the clamps could not place (0 when fully rebalanced)
    days: tuple[ComputedDay, ...]


def compute_week(
    *,
    week_start: date,
    today: date,
    baseline: float,
    planned: Mapping[date, float],
    consumed: Mapping[date, float],
    logged: Collection[date],
) -> ComputedWeek:
    """Compute the adjusted week from durable facts. Pure and deterministic.

    ``planned`` must cover all 7 days of the week (the router defaults missing
    days to the baseline). ``consumed`` maps day → kcal eaten (missing = 0.0);
    ``logged`` is the set of days with ≥ 1 live meal log — the days that are
    tracked at all. Only an overage on a tracked past day carries (as a cut).
    """
    days = [week_start + timedelta(days=i) for i in range(7)]

    carry = sum(
        min(0.0, planned[d] - consumed.get(d, 0.0))
        for d in days
        if d < today and d in logged
    )

    remaining = [d for d in days if d >= today]
    adjusted: dict[date, float] = {d: planned[d] for d in days}
    fully_rebalanced = True
    leftover = 0.0
    # No remaining days (week entirely past): nothing to rebalance — adjusted
    # stays = planned everywhere and the carry is reported as a plain fact.
    if remaining and abs(carry) > _EPSILON:
        values, fully_rebalanced, leftover = _distribute(
            [planned[d] for d in remaining],
            [_bounds(planned[d], baseline) for d in remaining],
            carry,
        )
        for d, value in zip(remaining, values, strict=True):
            adjusted[d] = value

    rounded = _round_days(adjusted, remaining)

    if remaining:
        remaining_kcal = round(
            sum(rounded[d] for d in remaining) - consumed.get(today, 0.0), 1
        )
    else:
        remaining_kcal = 0.0

    return ComputedWeek(
        week_start=week_start,
        week_end=days[-1],
        baseline=baseline,
        weekly_target=sum(planned[d] for d in days),
        carry=carry,
        remaining_kcal=remaining_kcal,
        fully_rebalanced=fully_rebalanced,
        leftover_kcal=leftover,
        days=tuple(
            ComputedDay(
                day=d,
                weekday=d.weekday(),
                planned=planned[d],
                adjusted=rounded[d],
                consumed=consumed.get(d, 0.0),
                logged=d in logged,
                state="past" if d < today else ("today" if d == today else "future"),
            )
            for d in days
        ),
    )


def _bounds(planned: float, baseline: float) -> tuple[float, float]:
    """The clamp band for one day's adjusted target: floor and swing cap."""
    return (max(FLOOR_KCAL, planned - SWING_FRACTION * baseline), planned + SWING_FRACTION * baseline)


def _distribute(
    targets: list[float], bounds: list[tuple[float, float]], carry: float
) -> tuple[list[float], bool, float]:
    """Spread ``carry`` equally over ``targets``, clamped; waterfall the residue.

    Each pass gives every still-open day an equal share; a day whose result
    would leave its band is pinned to the bound and its overflow rolls into the
    next pass's residual. If every day pins and residual remains, the week
    cannot fully absorb the carry: report it (leftover) rather than silently
    violating the clamps — facts-first.
    """
    values = list(targets)
    open_days = list(range(len(values)))
    residual = carry
    for _ in range(_MAX_PASSES):
        if not open_days or abs(residual) <= _EPSILON:
            break
        share = residual / len(open_days)
        residual = 0.0
        still_open: list[int] = []
        for i in open_days:
            proposed = values[i] + share
            lo, hi = bounds[i]
            if proposed > hi:
                residual += proposed - hi
                values[i] = hi
            elif proposed < lo:
                residual += proposed - lo
                values[i] = lo
            else:
                values[i] = proposed
                still_open.append(i)
        open_days = still_open
    fully = abs(residual) <= _EPSILON
    return values, fully, (0.0 if fully else residual)


def _round_days(adjusted: Mapping[date, float], remaining: list[date]) -> dict[date, int]:
    """Round each day to whole kcal without drifting the week total.

    Naive per-day rounding drifts the remaining-days sum by up to n·0.5 kcal
    off the invariant Σ remaining adjusted == Σ remaining planned + carry
    (post-clamp). We keep the invariant EXACT at whole-kcal precision by
    rounding the remaining-days float sum once and handing the LAST remaining
    day whatever the earlier days' rounding left over — deterministic, and the
    last day moves by strictly less than n kcal (n ≤ 7), which is inside the
    tolerance this contract documents. Past days round independently: their
    adjusted equals their planned and participates in no invariant.
    """
    rounded = {d: round(v) for d, v in adjusted.items()}
    if remaining:
        exact_total = round(sum(adjusted[d] for d in remaining))
        head = sum(rounded[d] for d in remaining[:-1])
        rounded[remaining[-1]] = exact_total - head
    return rounded
