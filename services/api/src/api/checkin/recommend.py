"""Recalibration on the v2.0 titration (PROTOCOL_LOGIC §3.3; decision 64).

Francesco recalibrates by formula, not feeling ("same thing, different result = insanity").
The IP's weekly auto-adjustment compares the rate of weight change to a 0.5 to 1.0 percent of
bodyweight per week band and moves the deficit one 5 percent step: too slow, add five; too
fast, take five away; clamp 0 to 25; re-apply the calorie floor. This module decides WHICH
step, deterministically, and hands the engine the inputs; the engine recomputes the WHOLE
protocol at the current weight, so fat, the protein band, fiber, produce and the whys move
together (findings ledger 53: the old path moved four numbers and left the rest stale).

Two of Francesco's judgments sit on top of the titration and are kept on purpose:

- **Compliance gates a cut.** Too slow on a month that was not executed is DIAGNOSTICS, never
  a cut: "cutting calories on an unexecuted month fixes the wrong thing". The honest levers
  (movement, logging) are surfaced instead.
- **A gain holds.** One month up is not a trend, and a cut with a "you did the work" headline
  on a gain is a trust violation (red-team regression, 2026-08). HOLD, look at the week.

Non-cut goals hold: the titration is a fat-loss instrument and there is no documented
maintain or gain math to invent (AGENTS.md #6).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum

from ..protocols.engine import (
    DEFAULT_TUNABLES,
    ProtocolComputation,
    ProtocolTunables,
    compute_targets,
    infer_activity_level,
    infer_reduce_pct,
    lb_to_kg,
)
from ..protocols.schemas import IntakeProfile

# The IP's target rate of loss, as a fraction of bodyweight per week (§3.3).
RATE_SLOW = 0.005
RATE_FAST = 0.010
# One titration step, in deficit percentage points; the IP works in fives.
STEP_PCT = 5.0
# A weight change smaller than this is measurement, not progress; a recalibration to it would
# move nothing a person could see.
_NO_PROGRESS_KG = 0.3
# Adherence (0..1, the check-in's 1 to 5 self-rating over 5) at or above which a flat month
# counts as executed: the gate between the cut branch and the diagnostics branch.
_COMPLIANT_ADHERENCE = 0.8
# A protocol younger than a week is read as one week old: the rate is per week and a check-in
# the day after generation must not read a normal fluctuation as a landslide.
_MIN_WEEKS = 1.0


class RecommendationKind(str, Enum):
    """Which branch fired. Stable ids: stored, asserted, decoded by the app."""

    RECALIBRATE_IBW = "recalibrate_ibw"  # on pace; the same deficit from the new weight
    REDUCE_ALLOCATION = "reduce_allocation"  # too slow and executed: five more percent off
    EASE_DEFICIT = "ease_deficit"  # too fast: five percent back
    DIAGNOSTICS = "diagnostics"  # too slow and not executed: look first
    HOLD = "hold"


@dataclass(frozen=True)
class RecalInputs:
    """Inputs to one recalibration, all from durable rows (the caller assembles them)."""

    profile: IntakeProfile
    current_weight_lb: float
    starting_weight_lb: float
    weeks_elapsed: float
    adherence: float  # 0..1
    current_reduce_pct: float  # the deficit the active protocol was built with
    activity_level: str  # the IP level the active protocol was built with
    meals_per_day: int = 3
    logging_accuracy: float | None = None  # 0..1, e.g. days logged / days
    avg_steps: int | None = None

    @property
    def weight_change_kg(self) -> float:
        """Signed: negative = lost weight, positive = gained."""
        return round(lb_to_kg(self.current_weight_lb) - lb_to_kg(self.starting_weight_lb), 2)

    @property
    def weekly_rate(self) -> float:
        """Fraction of starting bodyweight lost per week (positive = losing)."""
        if self.starting_weight_lb <= 0:
            return 0.0
        weeks = max(_MIN_WEEKS, self.weeks_elapsed)
        return (self.starting_weight_lb - self.current_weight_lb) / self.starting_weight_lb / weeks


@dataclass(frozen=True)
class RecalTargets:
    """The wire shape the shipped check-in screen decodes (target_kcal, protein_g, water_oz,
    fiber_g; cal_per_kg is the implied kcal per kg of ideal weight). The full protocol rides
    beside it in ``Recommendation.computation``."""

    cal_per_kg: float
    target_kcal: int
    protein_g: int
    water_oz: int
    fiber_g: int


@dataclass(frozen=True)
class Recommendation:
    """Structured recalibration output. ``optional`` mirrors Francesco's "pitch, often
    optional" framing; ``clamps`` records any rail that bound the request; ``diagnostics``
    carries the honest levers for the not-executed case. ``computation`` is the whole new
    protocol when the branch proposes one, and what /revise persists."""

    kind: RecommendationKind
    optional: bool
    headline: str
    rationale: str
    targets: RecalTargets | None = None
    computation: ProtocolComputation | None = None
    reduce_pct: float | None = None
    diagnostics: list[str] = field(default_factory=list)
    clamps: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "kind": self.kind.value,
            "optional": self.optional,
            "headline": self.headline,
            "rationale": self.rationale,
            "targets": _targets_dict(self.targets),
            "protocol": (
                self.computation.targets.model_dump(mode="json") if self.computation else None
            ),
            "diagnostics": list(self.diagnostics),
            "clamps": list(self.clamps),
        }


def _targets_dict(targets: RecalTargets | None) -> dict | None:
    if targets is None:
        return None
    return {
        "cal_per_kg": targets.cal_per_kg,
        "target_kcal": targets.target_kcal,
        "protein_g": targets.protein_g,
        "water_oz": targets.water_oz,
        "fiber_g": targets.fiber_g,
    }


def build_recal_inputs(
    *,
    intake_profile: IntakeProfile,
    active_targets: dict,
    protocol_created_at: datetime | None,
    current_weight_kg: float,
    adherence_self: int,
    checkin_at: datetime | None = None,
) -> RecalInputs:
    """Assemble RecalInputs from durable rows. Pure (no DB) so it is testable.

    - starting weight = the intake bodyweight (the baseline; always present once intake is
      persisted);
    - the deficit and activity level come from the active protocol's stored facts (written
      since 2026-10-04), else re-inferred from the intake exactly as generate would;
    - weeks elapsed = protocol creation to the check-in, at least one;
    - adherence: the 1..5 self-rating over 5 (the 0.8 gate is hit at 4+).
    """
    reduce_pct = active_targets.get("reduce_pct")
    activity = active_targets.get("activity_level")
    weeks = _MIN_WEEKS
    if protocol_created_at is not None:
        end = checkin_at or datetime.now(protocol_created_at.tzinfo)
        weeks = max(_MIN_WEEKS, (end - protocol_created_at).total_seconds() / (7 * 86400))
    return RecalInputs(
        profile=intake_profile,
        current_weight_lb=current_weight_kg * 2.2046226218,
        starting_weight_lb=intake_profile.weight_lb,
        weeks_elapsed=weeks,
        adherence=max(0.0, min(1.0, adherence_self / 5.0)),
        current_reduce_pct=(
            float(reduce_pct) if reduce_pct is not None else infer_reduce_pct(intake_profile)
        ),
        activity_level=(
            str(activity) if activity else infer_activity_level(intake_profile)
        ),
        meals_per_day=int(active_targets.get("meals_per_day") or 3),
    )


def recommend(
    inputs: RecalInputs, *, tunables: ProtocolTunables = DEFAULT_TUNABLES
) -> Recommendation:
    """Run the titration and return one structured recommendation."""
    if inputs.profile.goal.value != "cut":
        return Recommendation(
            kind=RecommendationKind.HOLD,
            optional=True,
            headline="Holding your plan: recalibration is a fat-loss tool.",
            rationale=(
                "Your goal isn't fat loss, so a flat month isn't a signal to cut. We hold the "
                "current plan; a fresh intake is the way to change the targets if your goal changes."
            ),
        )

    change_kg = inputs.weight_change_kg
    rate = inputs.weekly_rate

    # A gain holds (red-team regression, 2026-08): one month up is not a trend.
    if change_kg >= _NO_PROGRESS_KG:
        return Recommendation(
            kind=RecommendationKind.HOLD,
            optional=True,
            headline=f"Up {change_kg:g} kg. We hold and look at the week, not cut.",
            rationale=(
                "One month up isn't a trend, and a gain isn't a signal to slash calories. "
                "Hold the current plan, tighten consistency, and re-measure next week."
            ),
        )

    if rate > RATE_FAST:
        return _propose(
            inputs,
            tunables,
            RecommendationKind.EASE_DEFICIT,
            reduce_pct=inputs.current_reduce_pct - STEP_PCT,
            optional=False,
            headline="Faster than the plan intends. We ease the deficit one notch.",
            rationale=(
                "Losing more than one percent a week costs muscle and energy. Five percent "
                "less deficit keeps the loss, and keeps you. Re-measured next week."
            ),
        )

    if rate >= RATE_SLOW:
        if abs(change_kg) < _NO_PROGRESS_KG:
            return _hold_on_pace()
        return _propose(
            inputs,
            tunables,
            RecommendationKind.RECALIBRATE_IBW,
            reduce_pct=inputs.current_reduce_pct,
            optional=True,
            headline=f"Down {abs(change_kg):g} kg at a steady pace. Let's recalibrate to where you are now.",
            rationale=(
                "Your weight moved, so your ideal weight and everything built on it move too. "
                "Same deficit, new starting point. Optional if you'd rather hold the numbers."
            ),
        )

    # Too slow (flat, or a loss under half a percent a week). Compliance decides.
    if inputs.adherence >= _COMPLIANT_ADHERENCE:
        return _propose(
            inputs,
            tunables,
            RecommendationKind.REDUCE_ALLOCATION,
            reduce_pct=inputs.current_reduce_pct + STEP_PCT,
            optional=False,
            headline="Scale held and you did the work. We step the deficit down one notch.",
            rationale=(
                "Same input, same result means the math needs to move: five percent more "
                "deficit, re-measured next week. Never a leap."
            ),
        )
    return Recommendation(
        kind=RecommendationKind.DIAGNOSTICS,
        optional=False,
        headline="Before we change anything, let's look at what actually happened.",
        rationale=(
            "Cutting calories on a week that wasn't fully executed fixes the wrong thing. "
            "Two honest questions first: how much did you really move, and how accurate was "
            "the logging?"
        ),
        diagnostics=_diagnostics(inputs),
    )


def _hold_on_pace() -> Recommendation:
    return Recommendation(
        kind=RecommendationKind.HOLD,
        optional=True,
        headline="On pace. Nothing to change this week.",
        rationale="The scale moved the way the plan intends. Same numbers, same week.",
    )


def _propose(
    inputs: RecalInputs,
    tunables: ProtocolTunables,
    kind: RecommendationKind,
    *,
    reduce_pct: float,
    optional: bool,
    headline: str,
    rationale: str,
) -> Recommendation:
    """Recompute the whole protocol at the current weight with the titrated deficit."""
    clamps: list[str] = []
    clamped = max(0.0, min(tunables.reduce_pct_max, reduce_pct))
    if clamped != reduce_pct:
        clamps.append(
            f"deficit {reduce_pct:g}% clamped to {clamped:g}% (the IP works between 0 and "
            f"{tunables.reduce_pct_max:g} percent, PROTOCOL_LOGIC §3.3)"
        )
    computation = compute_targets(
        inputs.profile.sex.value,
        inputs.profile.height_in,
        inputs.current_weight_lb,
        inputs.activity_level,
        clamped,
        meals_per_day=inputs.meals_per_day,
        tunables=tunables,
    )
    facts = computation.facts
    # The inferred coach inputs ride with the targets (as generate persists them), so the
    # recommendation's protocol dict and the revised row carry the deficit they were built with.
    computation = ProtocolComputation(
        targets=computation.targets.model_copy(
            update={"reduce_pct": facts.reduce_pct, "activity_level": facts.activity_level}
        ),
        facts=facts,
    )
    if facts.floored:
        clamps.append(
            f"target {facts.target_pre_floor} kcal raised to the {facts.calorie_floor} kcal "
            "floor (PROTOCOL_LOGIC §3.1)"
        )
    t = computation.targets
    targets = RecalTargets(
        cal_per_kg=round(t.kcal / facts.ibw_kg, 1) if facts.ibw_kg else 0.0,
        target_kcal=t.kcal,
        protein_g=t.protein,
        water_oz=t.water_oz,
        fiber_g=t.fiber,
    )
    return Recommendation(
        kind=kind,
        optional=optional,
        headline=headline,
        rationale=rationale,
        targets=targets,
        computation=computation,
        reduce_pct=clamped,
        clamps=clamps,
    )


def _diagnostics(inputs: RecalInputs) -> list[str]:
    """Honest levers for the not-executed case (movement, logging)."""
    out: list[str] = []
    if inputs.logging_accuracy is not None and inputs.logging_accuracy < _COMPLIANT_ADHERENCE:
        pct = round(inputs.logging_accuracy * 100)
        out.append(f"Logging covered about {pct}% of days. Accuracy first, numbers second.")
    else:
        out.append("How accurate was the logging? Every bite, every day?")
    if inputs.avg_steps is not None:
        out.append(f"Movement averaged ~{inputs.avg_steps:,} steps/day. Is that the real week?")
    else:
        out.append("How much did you actually move this week?")
    return out
