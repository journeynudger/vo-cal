"""Recalibration on the v2.0 titration (PROTOCOL_LOGIC §3.3; decision 64). Pure, no DB.

The rate of loss against the 0.5 to 1.0 percent of bodyweight per week band moves the deficit
one five-percent step; compliance gates a cut; a gain holds; the engine recomputes the whole
protocol so fat, the band, fiber and produce move with the calories.
"""

from __future__ import annotations

import pytest

from api.checkin.recommend import (
    RATE_FAST,
    RATE_SLOW,
    RecalInputs,
    RecommendationKind,
    recommend,
)
from api.protocols.engine import DEFAULT_TUNABLES, compute_targets
from api.protocols.schemas import Goal, IntakeProfile


def _profile(**over) -> IntakeProfile:
    base = {
        "age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0, "goal": "cut",
        "work": "desk", "train": "moderate", "kids": False, "med": "none", "stress": "moderate",
    }
    base.update(over)
    return IntakeProfile.model_validate(base)


def _inputs(**over) -> RecalInputs:
    base = {
        "profile": _profile(),
        "current_weight_lb": 200.0,
        "starting_weight_lb": 200.0,
        "weeks_elapsed": 4.0,
        "adherence": 0.9,
        "current_reduce_pct": 20.0,
        "activity_level": "Moderate",
        "logging_accuracy": 0.95,
        "avg_steps": 8000,
    }
    base.update(over)
    return RecalInputs(**base)


# -- on pace: the same deficit from the new weight -------------------------------------------


def test_steady_loss_recalibrates_from_the_new_weight():
    # 6 lb over 4 weeks on 200 lb = 0.75 percent a week: inside the band.
    rec = recommend(_inputs(current_weight_lb=194.0))
    assert rec.kind is RecommendationKind.RECALIBRATE_IBW
    assert rec.optional is True
    assert rec.reduce_pct == 20.0
    assert rec.computation is not None
    expected = compute_targets("male", 70.0, 194.0, "Moderate", 20.0)
    assert rec.computation.targets.kcal == expected.targets.kcal
    assert rec.targets is not None
    assert rec.targets.target_kcal == expected.targets.kcal
    assert rec.targets.water_oz == round(194.0 * 0.5)


def test_a_whole_protocol_moves_together():
    rec = recommend(_inputs(current_weight_lb=194.0))
    t = rec.computation.targets
    assert t.fat == round(t.kcal * DEFAULT_TUNABLES.fat_pct / 9)
    assert t.protein_min <= t.protein <= t.protein_max
    assert abs(t.protein * 4 + t.carbs * 4 + t.fat * 9 - t.kcal) <= 4
    assert t.produce_servings > 0


# -- too slow: compliance decides -------------------------------------------------------------


def test_flat_and_executed_steps_the_deficit_down_one_notch():
    rec = recommend(_inputs(adherence=0.9))
    assert rec.kind is RecommendationKind.REDUCE_ALLOCATION
    assert rec.optional is False
    assert rec.reduce_pct == 25.0
    assert rec.computation is not None
    assert rec.computation.targets.kcal < compute_targets("male", 70.0, 200.0, "Moderate", 20.0).targets.kcal


def test_slow_loss_still_counts_as_too_slow():
    # 1 lb over 4 weeks = 0.125 percent a week, under the band's floor.
    rec = recommend(_inputs(current_weight_lb=199.0, adherence=1.0))
    assert rec.kind is RecommendationKind.REDUCE_ALLOCATION


def test_flat_and_not_executed_surfaces_diagnostics_not_a_cut():
    rec = recommend(_inputs(adherence=0.4, logging_accuracy=0.5, avg_steps=3000))
    assert rec.kind is RecommendationKind.DIAGNOSTICS
    assert rec.computation is None
    assert rec.targets is None
    text = " ".join(rec.diagnostics).lower()
    assert "log" in text
    assert "move" in text or "step" in text


# -- too fast: ease -------------------------------------------------------------------------


def test_too_fast_eases_the_deficit_one_notch():
    # 12 lb over 4 weeks on 200 lb = 1.5 percent a week.
    rec = recommend(_inputs(current_weight_lb=188.0))
    assert rec.kind is RecommendationKind.EASE_DEFICIT
    assert rec.reduce_pct == 15.0
    assert rec.computation.targets.kcal == compute_targets("male", 70.0, 188.0, "Moderate", 15.0).targets.kcal


# -- rails ----------------------------------------------------------------------------------


def test_deficit_clamps_to_the_ip_range_and_reports():
    at_max = recommend(_inputs(current_reduce_pct=25.0, adherence=1.0))
    assert at_max.kind is RecommendationKind.REDUCE_ALLOCATION
    assert at_max.reduce_pct == 25.0
    assert any("clamped" in c for c in at_max.clamps)
    at_zero = recommend(_inputs(current_weight_lb=188.0, current_reduce_pct=0.0))
    assert at_zero.kind is RecommendationKind.EASE_DEFICIT
    assert at_zero.reduce_pct == 0.0
    assert any("clamped" in c for c in at_zero.clamps)


def test_a_cut_never_lands_below_the_calorie_floor():
    small = _profile(sex="female", height_in=60.0, weight_lb=110.0, train="none", stress="low")
    rec = recommend(_inputs(profile=small, current_weight_lb=110.0, starting_weight_lb=110.0,
                            activity_level="Low", adherence=1.0))
    assert rec.kind is RecommendationKind.REDUCE_ALLOCATION
    assert rec.computation.targets.kcal == DEFAULT_TUNABLES.calorie_floor_female
    assert any("floor" in c for c in rec.clamps)


def test_a_young_protocol_reads_as_one_week_old():
    # Two days old: a 2 lb drop is one percent of bodyweight, which per week would be a landslide
    # if divided by 2/7 weeks. Read as one week, it is inside the band.
    rec = recommend(_inputs(current_weight_lb=198.0, weeks_elapsed=2 / 7))
    assert rec.kind is RecommendationKind.RECALIBRATE_IBW
    assert RATE_SLOW <= _inputs(current_weight_lb=198.0, weeks_elapsed=2 / 7).weekly_rate <= RATE_FAST


# -- holds ----------------------------------------------------------------------------------


def test_a_gain_holds_never_cuts():
    rec = recommend(_inputs(current_weight_lb=204.0, adherence=1.0))
    assert rec.kind is RecommendationKind.HOLD
    assert rec.computation is None
    assert "hold" in rec.headline.lower()


def test_a_tiny_change_on_pace_holds():
    # A light person inside the band whose loss is under 0.3 kg: the rate is right and the number
    # would not move anything a person could see, so nothing changes.
    light = _profile(sex="female", height_in=62.0, weight_lb=100.0)
    rec = recommend(_inputs(profile=light, starting_weight_lb=100.0, current_weight_lb=99.4,
                            weeks_elapsed=1.0, activity_level="Moderate"))
    assert rec.kind is RecommendationKind.HOLD
    assert "pace" in rec.headline.lower()


def test_maintain_and_gain_goals_hold():
    for goal in (Goal.MAINTAIN, Goal.GAIN):
        rec = recommend(_inputs(profile=_profile(goal=goal.value)))
        assert rec.kind is RecommendationKind.HOLD
        assert rec.optional is True


def test_recommendation_as_dict_is_jsonable():
    import json

    rec = recommend(_inputs(current_weight_lb=194.0))
    payload = rec.as_dict()
    json.dumps(payload)
    assert payload["kind"] == "recalibrate_ibw"
    assert payload["protocol"]["kcal"] == rec.computation.targets.kcal
    assert set(payload["targets"]) == {"cal_per_kg", "target_kcal", "protein_g", "water_oz", "fiber_g"}
    assert payload["targets"]["cal_per_kg"] == pytest.approx(rec.targets.cal_per_kg)
