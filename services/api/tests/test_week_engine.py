"""Weekly budget engine unit tests — pure math, no app, no clock.

Every case pins deterministic numbers (AGENTS.md #6). Fixed calendar: the week
of Monday 2026-08-10 .. Sunday 2026-08-16.
"""

from __future__ import annotations

from datetime import date, timedelta

from api.weekbudget.engine import FLOOR_KCAL, compute_week

MON = date(2026, 8, 10)  # a Monday (weekday() == 0)
DAYS = [MON + timedelta(days=i) for i in range(7)]
B = 2000.0


def _flat_plan(kcal: float = B) -> dict[date, float]:
    return dict.fromkeys(DAYS, kcal)


def _adjusted(week) -> dict[date, int]:
    return {d.day: d.adjusted for d in week.days}


# -- carry direction ----------------------------------------------------------


def test_overeat_yesterday_spreads_cut_across_remaining_days():
    # Mon on-plan, Tue +700 over; from Wed the 5 remaining days each absorb -140.
    week = compute_week(
        week_start=MON,
        today=DAYS[2],
        baseline=B,
        planned=_flat_plan(),
        consumed={DAYS[0]: 2000.0, DAYS[1]: 2700.0},
        logged={DAYS[0], DAYS[1]},
    )
    assert week.carry == -700.0
    adjusted = _adjusted(week)
    for d in DAYS[2:]:
        assert adjusted[d] == 1860  # 2000 - 700/5
    # Past days never move.
    assert adjusted[DAYS[0]] == 2000
    assert adjusted[DAYS[1]] == 2000
    assert week.fully_rebalanced is True
    assert week.leftover_kcal == 0.0


def test_undereat_banks_headroom_for_remaining_days():
    week = compute_week(
        week_start=MON,
        today=DAYS[2],
        baseline=B,
        planned=_flat_plan(),
        consumed={DAYS[0]: 2000.0, DAYS[1]: 1500.0},
        logged={DAYS[0], DAYS[1]},
    )
    assert week.carry == 500.0
    adjusted = _adjusted(week)
    for d in DAYS[2:]:
        assert adjusted[d] == 2100  # 2000 + 500/5


def test_unlogged_past_day_contributes_zero_carry():
    # Monday has NO meal logs: treating it as "ate nothing" would bank a fake
    # +2000 surplus and tell the user to overeat. It must contribute exactly 0.
    week = compute_week(
        week_start=MON,
        today=DAYS[2],
        baseline=B,
        planned=_flat_plan(),
        consumed={DAYS[1]: 2700.0},  # Monday absent entirely
        logged={DAYS[1]},
    )
    assert week.carry == -700.0  # only Tuesday's overage, no Monday windfall
    assert week.days[0].logged is False
    assert week.days[0].adjusted == 2000


# -- clamps -------------------------------------------------------------------


def test_floor_1200_holds_under_massive_deficit():
    # Sat+Sun remain, both planned near the floor; a huge overage cannot push
    # any adjusted target below 1200.
    planned = _flat_plan()
    planned[DAYS[5]] = 1300.0
    planned[DAYS[6]] = 1300.0
    consumed = dict.fromkeys(DAYS[:5], 4000.0)  # -2000/day over Mon..Fri
    week = compute_week(
        week_start=MON,
        today=DAYS[5],
        baseline=B,
        planned=planned,
        consumed=consumed,
        logged=set(DAYS[:5]),
    )
    for d in DAYS[5:]:
        assert _adjusted(week)[d] == int(FLOOR_KCAL)
    assert week.fully_rebalanced is False
    assert week.leftover_kcal < 0  # the unabsorbable part of the deficit, reported


def test_floor_clamp_waterfalls_residual_onto_open_days():
    # Fri/Sat/Sun remain. Friday is planned low (1400 → floor 1200, only 200 of
    # room); a -900 carry gives each day -300, Friday pins at 1200 and its
    # unabsorbed -100 waterfalls equally onto Sat+Sun (-50 each).
    planned = _flat_plan()
    planned[DAYS[4]] = 1400.0
    week = compute_week(
        week_start=MON,
        today=DAYS[4],
        baseline=B,
        planned=planned,
        consumed=dict.fromkeys(DAYS[:4], 2225.0),  # 4 × -225 = -900
        logged=set(DAYS[:4]),
    )
    adjusted = _adjusted(week)
    assert adjusted[DAYS[4]] == 1200  # pinned at the floor
    assert adjusted[DAYS[5]] == 1650  # 2000 - 300 - 50
    assert adjusted[DAYS[6]] == 1650
    # Post-clamp invariant: remaining adjusted == remaining planned + carry.
    assert sum(adjusted[d] for d in DAYS[4:]) == 1400 + 2000 + 2000 - 900
    assert week.fully_rebalanced is True


def test_cap_holds_and_surplus_beyond_every_cap_is_reported():
    # Cap headroom above plan is uniform (0.25·B for every day), so a share
    # larger than the cap pins ALL remaining days at planned + 0.25·B in one
    # pass — the residual has nowhere to go and must be reported, not hidden.
    week = compute_week(
        week_start=MON,
        today=DAYS[4],
        baseline=B,
        planned=_flat_plan(),
        consumed=dict.fromkeys(DAYS[:4], 1550.0),  # 4 × +450 = +1800; share 600 > 500
        logged=set(DAYS[:4]),
    )
    adjusted = _adjusted(week)
    for d in DAYS[4:]:
        assert adjusted[d] == 2500  # 2000 + 0.25·2000, never above
    assert week.fully_rebalanced is False
    assert round(week.leftover_kcal, 1) == 300.0  # 1800 - 3×500


def test_all_clamped_deficit_reports_leftover():
    week = compute_week(
        week_start=MON,
        today=DAYS[5],
        baseline=B,
        planned=_flat_plan(),
        consumed=dict.fromkeys(DAYS[:5], 4000.0),  # -10000 carry, 2 days remain
        logged=set(DAYS[:5]),
    )
    assert week.fully_rebalanced is False
    # Two days can absorb -500 each (floor at 1500 = 2000 - 0.25·B); the rest is leftover.
    assert round(week.leftover_kcal, 1) == -9000.0


# -- degenerate weeks ---------------------------------------------------------


def test_entirely_past_week_is_not_rebalanced():
    week = compute_week(
        week_start=MON,
        today=DAYS[6] + timedelta(days=1),  # next Monday
        baseline=B,
        planned=_flat_plan(),
        consumed={DAYS[1]: 2700.0},
        logged={DAYS[1]},
    )
    assert all(d.state == "past" for d in week.days)
    assert _adjusted(week) == dict.fromkeys(DAYS, 2000)  # adjusted == planned
    assert week.remaining_kcal == 0.0
    assert week.fully_rebalanced is True


def test_entirely_future_week_has_zero_carry():
    week = compute_week(
        week_start=MON,
        today=MON - timedelta(days=3),
        baseline=B,
        planned=_flat_plan(),
        consumed={},
        logged=set(),
    )
    assert week.carry == 0.0
    assert all(d.state == "future" for d in week.days)
    assert _adjusted(week) == dict.fromkeys(DAYS, 2000)


# -- rounding + determinism ---------------------------------------------------


def test_rounding_keeps_week_total_exact():
    # +1000 over 3 remaining days = 333.33… each; naive rounding loses a kcal.
    # The last remaining day absorbs the rounding so the total is exact.
    week = compute_week(
        week_start=MON,
        today=DAYS[4],
        baseline=B,
        planned=_flat_plan(),
        consumed=dict.fromkeys(DAYS[:4], 1750.0),  # 4 × +250 = +1000
        logged=set(DAYS[:4]),
    )
    adjusted = _adjusted(week)
    assert sum(adjusted[d] for d in DAYS[4:]) == 3 * 2000 + 1000  # exact
    assert adjusted[DAYS[4]] == 2333
    assert adjusted[DAYS[5]] == 2333
    assert adjusted[DAYS[6]] == 2334  # the last day carries the remainder


def test_same_inputs_same_output():
    kwargs = {
        "week_start": MON,
        "today": DAYS[3],
        "baseline": B,
        "planned": _flat_plan(),
        "consumed": {DAYS[0]: 1801.5, DAYS[1]: 2444.25, DAYS[2]: 1999.0},
        "logged": {DAYS[0], DAYS[1], DAYS[2]},
    }
    assert compute_week(**kwargs) == compute_week(**kwargs)
