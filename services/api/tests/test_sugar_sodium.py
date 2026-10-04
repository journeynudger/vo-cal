"""P3 (decision 60): sugar and sodium ride the ladder as optional nutrients, summed only when
known, shown only when the person adds the tile.

Pure tests over the nutrient model, the three food sources' mappings, the day aggregation, the
protocol ceilings and the composer.
"""

from __future__ import annotations

from api.meals.dashboard import compose
from api.meals.today import (
    Consumed,
    Targets,
    consumed_from_day,
    remaining_of,
    targets_from_protocol,
)
from api.nutrition.fatsecret_client import parse_serving
from api.nutrition.fdc_client import profile_from_detail
from api.nutrition.schemas import Macros, NutrientProfile
from api.protocols.engine import DEFAULT_TUNABLES, compute_targets
from api.protocols.schemas import IntakeProfile
from api.protocols.why import build_whys
from api.tracking.projection import projection_for
from api.tracking.schemas import FocusMetric, TrackingMode


def test_unknown_stays_none_and_scales_when_known():
    unknown = NutrientProfile(kcal=100, protein=1, carbs=20, fat=1)
    assert unknown.sugar_g is None
    assert unknown.for_grams(50).sugar_g is None
    known = NutrientProfile(kcal=100, protein=1, carbs=20, fat=1, sugar_g=10, sodium_mg=200)
    half = known.for_grams(50)
    assert half.sugar_g == 5.0
    assert half.sodium_mg == 100.0


def test_a_sum_knows_what_it_knows():
    a = Macros(kcal=100, sugar_g=5.0)
    b = Macros(kcal=100)  # sugar not known
    c = Macros(kcal=100, sugar_g=2.5, sodium_mg=50)
    assert (a + b).sugar_g == 5.0  # the known part, never the unknown as zero
    assert (b + b).sugar_g is None
    assert (a + c).sugar_g == 7.5
    assert (b + c).sodium_mg == 50


def test_fatsecret_reads_sugar_and_sodium_when_stated():
    with_both = parse_serving({"calories": "150", "protein": "3", "carbohydrate": "30", "fat": "2",
                               "fiber": "1", "sugar": "12", "sodium": "180", "serving_description": "1 cup"})
    assert with_both is not None
    assert with_both.profile.sugar_g == 12.0
    assert with_both.profile.sodium_mg == 180.0
    without = parse_serving({"calories": "150", "protein": "3", "carbohydrate": "30", "fat": "2",
                             "serving_description": "1 cup"})
    assert without is not None
    assert without.profile.sugar_g is None
    assert without.profile.sodium_mg is None


def test_fdc_reads_sugar_and_sodium_when_present():
    detail = {"foodNutrients": [
        {"nutrient": {"id": 1008}, "amount": 52.0}, {"nutrient": {"id": 1003}, "amount": 0.3},
        {"nutrient": {"id": 1005}, "amount": 13.8}, {"nutrient": {"id": 1004}, "amount": 0.2},
        {"nutrient": {"id": 2000}, "amount": 10.4}, {"nutrient": {"id": 1093}, "amount": 1.0},
    ]}
    profile = profile_from_detail(detail)
    assert profile.sugar_g == 10.4
    assert profile.sodium_mg == 1.0
    bare = profile_from_detail({"foodNutrients": [{"nutrient": {"id": 1008}, "amount": 52.0}]})
    assert bare.sugar_g is None
    assert bare.sodium_mg is None


def test_the_day_sums_known_items_and_counts_the_rest():
    meals = [{
        "totals": {"kcal": 300, "protein": 10, "carbs": 40, "fat": 8, "fiber": 3},
        "items": [
            {"name": "apple", "grams": 180, "macros": {"kcal": 95, "sugar_g": 19.0, "sodium_mg": 2.0}},
            {"name": "chicken breast", "grams": 100, "macros": {"kcal": 165}},
            {"name": "soda", "grams": 355, "macros": {"kcal": 140, "sugar_g": 39.0}},
        ],
    }]
    consumed = consumed_from_day(meals, 0.0)
    assert consumed.sugar == 58.0
    assert consumed.sugar_unknown_items == 1
    assert consumed.sodium == 2.0
    assert consumed.sodium_unknown_items == 2


def test_the_engine_sets_the_two_ceilings_and_explains_them():
    computation = compute_targets("male", 70.0, 200.0, "Moderate", 20.0)
    t = computation.targets
    assert t.sugar_g_max == round(t.kcal * DEFAULT_TUNABLES.sugar_kcal_fraction_max / 4)
    assert t.sodium_mg_max == 2300
    profile = IntakeProfile.model_validate({
        "age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0, "goal": "cut",
        "work": "desk", "train": "moderate", "kids": False, "med": "none", "stress": "moderate",
    })
    whys = build_whys(profile, computation.facts, t)
    assert str(t.sugar_g_max) in whys["sugar"]
    assert "public-health" in whys["sodium"]


def test_an_old_protocol_derives_its_sugar_ceiling_from_its_calories():
    targets, is_stub = targets_from_protocol({"targets": {"kcal": 1600, "protein": 140}})
    assert not is_stub
    assert targets.sugar == 40.0
    assert targets.sodium == 2300.0


def test_a_sugar_focus_adds_a_ceiling_tile_that_says_what_it_does_not_know():
    targets = Targets(kcal=1805, protein=163, carbs=167, fat=54, fiber=32, produce=6, water=100,
                      sugar=45, sodium=2300)
    consumed = Consumed(kcal=900, sugar=30, sugar_unknown_items=2)
    panels = compose(projection_for(TrackingMode.HABITS), [FocusMetric.SUGAR], targets, consumed,
                     remaining_of(targets, consumed), protein_band=(131, 163), meals_today=2)
    sugar = next(p for p in panels if p.metric == "sugar")
    assert sugar.direction == "stay_under"
    assert sugar.complete is False
    assert sugar.over is False
    assert sugar.unknown_items == 2
    assert sugar.support == "under 45 g · 2 foods not known"
    over = compose(projection_for(TrackingMode.HABITS), [FocusMetric.SUGAR], targets,
                   Consumed(sugar=60), remaining_of(targets, Consumed(sugar=60)),
                   protein_band=(131, 163), meals_today=2)
    assert next(p for p in over if p.metric == "sugar").over is True


def test_no_tile_for_a_target_of_zero():
    targets = Targets(kcal=1805, protein=163, sugar=0)
    panels = compose(projection_for(TrackingMode.CALORIES), [FocusMetric.SUGAR], targets,
                     Consumed(), remaining_of(targets, Consumed()), protein_band=(0, 0), meals_today=0)
    assert [p.metric for p in panels] == ["kcal"]
