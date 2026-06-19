"""Phase G: situational nudge engine (offline, pure-Python, no DB).

Asserts each bank rule fires on its signal, mid-week-before-midpoint detection,
and that exactly one nudge fires per evaluation (no double-firing).
"""

from __future__ import annotations

from api.checkin.nudge import NudgeSignals, NudgeTrigger, select_nudge

# Weekday constants (Mon=0..Sun=6). Mon/Tue/Wed are "before the midpoint".
MON, TUE, WED, THU, FRI = 0, 1, 2, 3, 4


# A baseline "all good" signal set: logging daily, logged recently, on targets.
# Individual tests perturb one field so exactly one rule should fire.
def _good(**over) -> NudgeSignals:
    base = {
        "weekday": WED,
        "days_logged_this_week": 3,
        "last_log_age_hours": 2.0,
        "avg_kcal_vs_target": 1.0,
        "water_adherence": 1.0,
        "produce_adherence": 1.0,
        "stress_flag": False,
    }
    base.update(over)
    return NudgeSignals(**base)


# -- is_mid_week (before-the-midpoint detection) ------------------------------


def test_mid_week_true_before_midpoint():
    for day in (MON, TUE, WED):
        assert _good(weekday=day).is_mid_week is True


def test_mid_week_false_at_and_after_midpoint():
    for day in (THU, FRI, 5, 6):
        assert _good(weekday=day).is_mid_week is False


# -- each bank rule fires on the right signal ---------------------------------


def test_no_log_today_fires_when_never_logged():
    nudge = select_nudge(_good(last_log_age_hours=None, days_logged_this_week=0))
    assert nudge.trigger is NudgeTrigger.NO_LOG_TODAY
    assert nudge.branch_options  # branch present for the "rough day?" fork


def test_no_log_today_fires_when_stale():
    nudge = select_nudge(_good(last_log_age_hours=20.0))
    assert nudge.trigger is NudgeTrigger.NO_LOG_TODAY


def test_stress_slipping_fires_before_midpoint():
    # Stress + thin days + early week → the stress branch (outranks plain slipping).
    nudge = select_nudge(
        _good(weekday=TUE, days_logged_this_week=1, stress_flag=True, last_log_age_hours=2.0)
    )
    assert nudge.trigger is NudgeTrigger.STRESS_SLIPPING
    assert "perfectly" in nudge.message  # the zero-friction "repeat a day" move


def test_mid_week_slipping_fires_without_stress():
    nudge = select_nudge(
        _good(weekday=WED, days_logged_this_week=1, stress_flag=False, last_log_age_hours=2.0)
    )
    assert nudge.trigger is NudgeTrigger.MID_WEEK_SLIPPING
    assert "Repeat my best day" in nudge.branch_options


def test_water_behind_fires():
    nudge = select_nudge(_good(water_adherence=0.4))
    assert nudge.trigger is NudgeTrigger.WATER_BEHIND
    assert "water" in nudge.message.lower()


def test_produce_behind_fires():
    nudge = select_nudge(_good(produce_adherence=0.2))
    assert nudge.trigger is NudgeTrigger.PRODUCE_BEHIND


def test_under_target_fires():
    nudge = select_nudge(_good(avg_kcal_vs_target=0.5))
    assert nudge.trigger is NudgeTrigger.UNDER_TARGET


def test_all_clear_when_nothing_fires():
    nudge = select_nudge(_good())
    assert nudge.trigger is NudgeTrigger.ALL_CLEAR
    assert nudge.branch_options == []


# -- mid-week gating: slipping rules only fire before the midpoint ------------


def test_slipping_does_not_fire_after_midpoint():
    # Same thin-day signal on Thursday: the slipping rules are gated off; with
    # everything else healthy, nothing fires (recent log keeps no-log-today quiet).
    nudge = select_nudge(_good(weekday=THU, days_logged_this_week=1, last_log_age_hours=2.0))
    assert nudge.trigger is NudgeTrigger.ALL_CLEAR


def test_stress_does_not_fire_after_midpoint():
    nudge = select_nudge(
        _good(weekday=FRI, days_logged_this_week=1, stress_flag=True, last_log_age_hours=2.0)
    )
    assert nudge.trigger is NudgeTrigger.ALL_CLEAR


# -- no double-firing: exactly one nudge per evaluation -----------------------


def test_no_log_outranks_slipping_and_water():
    # All three situations true at once → only the highest-priority (no-log) fires.
    nudge = select_nudge(
        NudgeSignals(
            weekday=TUE,
            days_logged_this_week=0,
            last_log_age_hours=None,
            water_adherence=0.1,
            stress_flag=True,
        )
    )
    assert nudge.trigger is NudgeTrigger.NO_LOG_TODAY


def test_stress_outranks_plain_slipping():
    nudge = select_nudge(
        _good(weekday=MON, days_logged_this_week=0, stress_flag=True, last_log_age_hours=2.0)
    )
    # Only one trigger; stress beats the plain mid-week-slipping rule.
    assert nudge.trigger is NudgeTrigger.STRESS_SLIPPING


def test_selection_returns_single_trigger_always():
    # Sweep a spread of signal combinations; every result is exactly one Nudge
    # with a valid trigger and no exceptions (selection is total).
    for weekday in range(7):
        for days in range(8):
            for age in (None, 1.0, 30.0):
                nudge = select_nudge(
                    NudgeSignals(
                        weekday=weekday,
                        days_logged_this_week=days,
                        last_log_age_hours=age,
                    )
                )
                assert isinstance(nudge.trigger, NudgeTrigger)
