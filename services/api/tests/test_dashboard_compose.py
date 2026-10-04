"""P2: meals/dashboard.py — Today composed for a mode (decision 60).

Pure tests over the composer: which panels each mode gets, in what order; completion rules
(calories land in a window, protein inside its band, micros reach the target); habits prints
no calories; a focus metric adds a tile the mode does not already print; a metric the nutrient
model does not carry is skipped rather than shown as zero.
"""

from __future__ import annotations

from api.meals.dashboard import compose
from api.meals.today import Consumed, Targets, remaining_of
from api.tracking.projection import extra_metrics, projection_for
from api.tracking.schemas import FocusMetric, TrackingMode

TARGETS = Targets(kcal=1805, protein=163, carbs=167, fat=54, fiber=32, produce=6, water=100)
BAND = (131.0, 163.0)


def _compose(mode: TrackingMode, consumed: Consumed, *, focus=(), meals=1):
    remaining = remaining_of(TARGETS, consumed)
    return compose(
        projection_for(mode), list(focus), TARGETS, consumed, remaining,
        protein_band=BAND, meals_today=meals,
    )


def _metrics(panels):
    return [p.metric for p in panels]


def test_five_is_todays_dashboard_in_order():
    panels = _compose(TrackingMode.FIVE, Consumed())
    assert _metrics(panels) == ["kcal", "protein", "produce", "water", "fiber"]
    assert panels[0].kind == "calories_left"
    assert all(p.kind == "metric_tile" for p in panels[1:])
    assert panels[3].can_add  # water alone has the plus
    assert not panels[2].can_add


def test_habits_prints_no_calories_and_has_three_tiles():
    panels = _compose(TrackingMode.HABITS, Consumed(water=48, produce=2), meals=2)
    assert _metrics(panels) == ["logged", "water", "produce"]
    assert panels[0].kind == "habit_tile"
    assert panels[0].complete
    assert panels[0].support == "2 meals"
    assert "kcal" not in _metrics(panels)
    assert not projection_for(TrackingMode.HABITS).prints_numbers
    assert not projection_for(TrackingMode.HABITS).checks_enabled


def test_habits_logged_tile_says_not_yet_on_an_empty_day():
    panels = _compose(TrackingMode.HABITS, Consumed(), meals=0)
    assert panels[0].support == "Not yet"
    assert not panels[0].complete


def test_calories_is_one_card():
    panels = _compose(TrackingMode.CALORIES, Consumed(kcal=1200))
    assert _metrics(panels) == ["kcal"]
    assert panels[0].support == "of 1,805 today"
    assert panels[0].remaining == 605


def test_macros_are_tiles_not_rings():
    panels = _compose(TrackingMode.MACROS, Consumed())
    assert _metrics(panels) == ["kcal", "protein", "carbs", "fat"]
    assert {p.kind for p in panels[1:]} == {"metric_tile"}


def test_calories_land_inside_the_window():
    low = _compose(TrackingMode.CALORIES, Consumed(kcal=1500))[0]
    inside = _compose(TrackingMode.CALORIES, Consumed(kcal=1700))[0]
    over = _compose(TrackingMode.CALORIES, Consumed(kcal=2000))[0]
    assert not low.complete
    assert not low.over
    assert inside.complete
    assert not inside.over
    assert not over.complete
    assert over.over


def test_protein_completes_inside_its_band():
    panels = _compose(TrackingMode.FIVE, Consumed(protein=140))
    protein = panels[1]
    assert protein.direction == "land"
    assert protein.band_low == 131
    assert protein.band_high == 163
    assert protein.complete
    assert protein.support == "131 to 163 g today"
    assert not _compose(TrackingMode.FIVE, Consumed(protein=100))[1].complete
    assert _compose(TrackingMode.FIVE, Consumed(protein=180))[1].over


def test_micros_reach_their_target():
    panels = _compose(TrackingMode.FIVE, Consumed(water=100, produce=3))
    water = next(p for p in panels if p.metric == "water")
    produce = next(p for p in panels if p.metric == "produce")
    assert water.complete
    assert water.support == "of 100 oz"
    assert not produce.complete
    assert produce.support == "of 6 a day"


def test_focus_metric_adds_a_tile_the_mode_lacks():
    panels = _compose(TrackingMode.CALORIES, Consumed(), focus=[FocusMetric.FIBER, FocusMetric.WATER])
    assert _metrics(panels) == ["kcal", "fiber", "water"]
    assert panels[2].can_add


def test_focus_metric_the_mode_already_prints_is_not_doubled():
    panels = _compose(TrackingMode.FIVE, Consumed(), focus=[FocusMetric.WATER, FocusMetric.CARBS])
    assert _metrics(panels) == ["kcal", "protein", "produce", "water", "fiber", "carbs"]
    assert extra_metrics(TrackingMode.FIVE, [FocusMetric.WATER, FocusMetric.CARBS]) == [FocusMetric.CARBS]


def test_metric_the_model_does_not_carry_is_skipped_not_zeroed():
    # Sugar and sodium land with P3; until Targets carries them a focus on them adds nothing,
    # and never a tile that reads 0 as if it were known.
    panels = _compose(TrackingMode.HABITS, Consumed(), focus=[FocusMetric.SUGAR])
    assert "sugar" not in _metrics(panels)


def test_reveal_keys_per_mode():
    assert projection_for(TrackingMode.HABITS).reveal_keys == ("water", "produce")
    assert projection_for(TrackingMode.CALORIES).reveal_keys == ("kcal",)
    assert projection_for(TrackingMode.FIVE).reveal_keys == ("kcal", "protein", "water", "fiber", "produce")
    assert projection_for(TrackingMode.MACROS).reveal_keys == ("kcal", "protein", "carbs", "fat", "fiber")
