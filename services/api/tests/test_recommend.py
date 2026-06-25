"""Phase G: monthly recalibration decision tree (offline, pure-Python, no DB).

Golden cases for the three documented branches (decision #37) plus the cal/kg
rail bounds: a recalibration may never walk the allocation outside the 24–29
cal/kg fat-loss band, and a clamp is always reported (never hidden).
"""

from __future__ import annotations

from api.checkin.recommend import (
    RecalInputs,
    RecommendationKind,
    recommend,
)


def _inputs(**over) -> RecalInputs:
    base = {
        "current_weight_kg": 80.0,
        "starting_weight_kg": 80.0,
        "ideal_body_weight_kg": 70.0,
        "current_cal_per_kg": 27.0,
        "adherence": 0.9,
        "logging_accuracy": 0.95,
        "avg_steps": 8000,
    }
    base.update(over)
    return RecalInputs(**base)


# -- Branch 1: lost weight → recalibrate to adjusted IBW (optional) -----------


def test_lost_weight_recalibrates_to_ibw():
    rec = recommend(_inputs(current_weight_kg=77.0, starting_weight_kg=80.0))
    assert rec.kind is RecommendationKind.RECALIBRATE_IBW
    assert rec.optional is True  # "pitch, often optional"
    assert rec.targets is not None
    # Calories key off IBW × cal/kg (70 × 27 = 1890); protein/water off bodyweight.
    assert rec.targets.target_kcal == 1890
    assert rec.targets.cal_per_kg == 27.0


def test_lost_weight_scales_water_off_current_bodyweight():
    rec = recommend(_inputs(current_weight_kg=77.0, starting_weight_kg=80.0))
    assert rec.targets is not None
    # Water ≈ half bodyweight in oz: 77 kg → ~169.8 lb → ~85 oz.
    assert rec.targets.water_oz == round(0.5 * 77.0 * 2.2046226218)


# -- Branch 2: no progress + compliant → knock cal/kg down one point ----------


def test_no_progress_compliant_reduces_one_point():
    rec = recommend(_inputs(current_cal_per_kg=27.0, adherence=0.9))
    assert rec.kind is RecommendationKind.REDUCE_ALLOCATION
    assert rec.optional is False
    assert rec.targets is not None
    assert rec.targets.cal_per_kg == 26.0  # one point down
    assert rec.targets.target_kcal == round(26.0 * 70.0)  # 1820


def test_no_progress_with_slight_gain_still_reduces_if_compliant():
    # A small gain is still "no progress"; compliant → cut one point.
    rec = recommend(_inputs(current_weight_kg=80.2, starting_weight_kg=80.0, adherence=0.85))
    assert rec.kind is RecommendationKind.REDUCE_ALLOCATION


# -- Branch 3: no progress + NOT compliant → diagnostics, not a cut -----------


def test_no_progress_not_compliant_surfaces_diagnostics():
    rec = recommend(_inputs(adherence=0.4, logging_accuracy=0.5, avg_steps=3000))
    assert rec.kind is RecommendationKind.DIAGNOSTICS
    assert rec.targets is None  # critically: NO calorie cut on an unexecuted month
    assert rec.diagnostics  # honest levers surfaced
    text = " ".join(rec.diagnostics).lower()
    assert "log" in text  # logging-accuracy lever
    assert "move" in text or "step" in text  # movement lever


# -- Rail bounds: clamp to the 24–29 cal/kg fat-loss band --------------------


def test_reduce_clamps_to_floor_and_reports():
    # At the floor already; "one point down" would breach 24 → clamp + report.
    rec = recommend(_inputs(current_cal_per_kg=24.0, adherence=0.95))
    assert rec.kind is RecommendationKind.REDUCE_ALLOCATION
    assert rec.targets is not None
    assert rec.targets.cal_per_kg == 24.0  # clamped up to the floor, not 23
    assert rec.clamps  # the clamp is recorded, never hidden


def test_recalibrate_clamps_above_ceiling_and_reports():
    # An out-of-band current allocation gets clamped to the ceiling on recalibration.
    rec = recommend(
        _inputs(current_weight_kg=77.0, starting_weight_kg=80.0, current_cal_per_kg=32.0)
    )
    assert rec.kind is RecommendationKind.RECALIBRATE_IBW
    assert rec.targets is not None
    assert rec.targets.cal_per_kg == 29.0
    assert rec.clamps


def test_reduce_within_band_has_no_clamp():
    rec = recommend(_inputs(current_cal_per_kg=27.0, adherence=0.9))
    assert rec.targets is not None
    assert rec.targets.cal_per_kg == 26.0
    assert rec.clamps == []


# -- Goal gate: the monthly tree is a FAT-LOSS tool (RT-00/09/20/38) ----------


def test_maintain_goal_holds_never_cuts():
    # Flat + compliant would REDUCE_ALLOCATION for a cut goal — but a flat month IS the goal for
    # maintenance, never a cue to cut. The goal gate must HOLD with no calorie targets.
    rec = recommend(_inputs(goal="maintain", current_cal_per_kg=27.0, adherence=0.9))
    assert rec.kind is RecommendationKind.HOLD
    assert rec.targets is None


def test_gain_goal_not_clamped_into_fat_loss_band():
    # A gainer's allocation (e.g. 36 cal/kg) must never be clamped into the 24–29 fat-loss band,
    # and a lost-weight month must not trigger a fat-loss recalibration down. HOLD, no targets.
    rec = recommend(
        _inputs(goal="gain", current_cal_per_kg=36.0, current_weight_kg=77.0, starting_weight_kg=80.0)
    )
    assert rec.kind is RecommendationKind.HOLD
    assert rec.targets is None


def test_cut_goal_still_runs_the_tree():
    # The default/cut goal is unchanged: flat + compliant still reduces one point.
    rec = recommend(_inputs(goal="cut", current_cal_per_kg=27.0, adherence=0.9))
    assert rec.kind is RecommendationKind.REDUCE_ALLOCATION
    assert rec.targets is not None


# -- Serialization is JSON-ready (stored in checkins.recommendation) ----------


def test_recommendation_as_dict_is_jsonable():
    rec = recommend(_inputs(current_weight_kg=77.0, starting_weight_kg=80.0))
    d = rec.as_dict()
    assert d["kind"] == "recalibrate_ibw"
    assert d["targets"]["target_kcal"] == 1890
    assert isinstance(d["clamps"], list)
    assert isinstance(d["diagnostics"], list)
