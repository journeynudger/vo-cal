"""The grounded estimator answers within a deadline, or the knowledge lane does, or neither
(nutrition/estimator.py WebGroundedEstimator.estimate). Fake lanes, scaled-down clocks.

Pins the budget that made one eight-item parse take 17.5 s in production (2026-09-24): the
grounded lane no longer holds the parse hostage past its deadline, a decline no longer costs
a sequential second call, and nothing waits past the hard cap.
"""

from __future__ import annotations

import asyncio

import pytest

from api.nutrition.estimator import EstimatedFood, WebGroundedEstimator
from api.nutrition.schemas import NutrientProfile
from api.parser.schemas import ParsedItem

GROUNDED = EstimatedFood(per_100g=NutrientProfile(kcal=200, protein=10, carbs=20, fat=8, fiber=1), serving_grams=150.0)
PLAIN = EstimatedFood(per_100g=NutrientProfile(kcal=210, protein=11, carbs=21, fat=8, fiber=1), serving_grams=140.0)


class _Lane:
    """A fake knowledge lane: answers after ``delay`` with ``answer``; remembers cancellation."""

    def __init__(self, delay: float, answer: EstimatedFood | None) -> None:
        self.delay, self.answer = delay, answer
        self.cancelled = False
        self.started = False

    async def estimate(self, item: ParsedItem) -> EstimatedFood | None:
        self.started = True
        try:
            await asyncio.sleep(self.delay)
        except asyncio.CancelledError:
            self.cancelled = True
            raise
        return self.answer


def _estimator(grounded_delay: float, grounded_answer, plain: _Lane | None, **budget) -> WebGroundedEstimator:
    est = WebGroundedEstimator("key", fallback=plain, deadline=0.12, plain_delay=0.04, hard_cap=0.2, **budget)

    async def fake_grounded(item: ParsedItem) -> EstimatedFood | None:
        await asyncio.sleep(grounded_delay)
        return grounded_answer

    est._grounded = fake_grounded  # type: ignore[method-assign]
    return est


ITEM = ParsedItem(name="oikos 23g protein smoothie", confidence=0.8)


@pytest.mark.asyncio
async def test_grounded_in_time_wins_and_the_plain_lane_is_never_paid():
    plain = _Lane(0.01, PLAIN)
    est = _estimator(0.01, GROUNDED, plain)
    assert await est.estimate(ITEM) is GROUNDED
    assert plain.started is False


@pytest.mark.asyncio
async def test_grounded_declines_quickly_and_the_plain_lane_answers():
    plain = _Lane(0.01, PLAIN)
    est = _estimator(0.01, None, plain)
    assert await est.estimate(ITEM) is PLAIN


@pytest.mark.asyncio
async def test_grounded_past_the_deadline_loses_to_a_ready_plain_answer():
    plain = _Lane(0.02, PLAIN)
    est = _estimator(0.5, GROUNDED, plain)
    started = asyncio.get_running_loop().time()
    assert await est.estimate(ITEM) is PLAIN
    elapsed = asyncio.get_running_loop().time() - started
    assert elapsed < 0.2  # the deadline, not the grounded lane's half second


@pytest.mark.asyncio
async def test_grounded_late_but_before_plain_still_wins():
    plain = _Lane(0.5, PLAIN)  # the plain lane is even slower
    est = _estimator(0.15, GROUNDED, plain)  # past the 0.12 deadline, inside the 0.2 cap
    assert await est.estimate(ITEM) is GROUNDED
    await asyncio.sleep(0.01)
    assert plain.cancelled is True


@pytest.mark.asyncio
async def test_nothing_within_the_hard_cap_is_unresolved_not_late():
    plain = _Lane(1.0, PLAIN)
    est = _estimator(1.0, GROUNDED, plain)
    started = asyncio.get_running_loop().time()
    assert await est.estimate(ITEM) is None
    assert asyncio.get_running_loop().time() - started < 0.35
    await asyncio.sleep(0.01)
    assert plain.cancelled is True


@pytest.mark.asyncio
async def test_a_failing_plain_lane_is_a_decline_never_a_500():
    class Boom:
        async def estimate(self, item):
            await asyncio.sleep(0.01)
            raise RuntimeError("provider down")

    est = _estimator(0.5, GROUNDED, Boom())  # type: ignore[arg-type]
    # Grounded lands at 0.5 s, past the 0.2 cap; the plain lane raised: unresolved, no error.
    assert await est.estimate(ITEM) is None


@pytest.mark.asyncio
async def test_without_a_fallback_the_grounded_lane_runs_alone():
    est = _estimator(0.01, GROUNDED, None)
    assert await est.estimate(ITEM) is GROUNDED
