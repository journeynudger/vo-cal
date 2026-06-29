"""F3: deterministic protocol engine — PRO Training Solutions IP v2.0 (offline, pure).

Every expected number is hand-checked against docs/PROTOCOL_LOGIC.md (the v2.0 IP):
Hamwi IBW (40% toward actual) -> maintenance = ibw_kg × activity factor -> deficit %
-> calorie floor -> protein 2.0/1.6 g/kg IBW -> fat 27% -> carbs remainder -> fiber
11/14 g per 1000 maintenance kcal -> fruit/veg = maintenance/400 -> water 0.5 oz/lb.
If a coefficient in ``engine.DEFAULT_TUNABLES`` changes, these goldens must be
re-derived on purpose — the math IS the product.
"""

from __future__ import annotations

from dataclasses import replace

import pytest

from api.protocols.engine import (
    DEFAULT_TUNABLES,
    compute_protocol,
    compute_targets,
    devine_ibw_kg,
    hamwi_ibw_lb,
    lb_to_kg,
)
from api.protocols.schemas import (
    Goal,
    IntakeProfile,
    MedEffect,
    Occupation,
    Sex,
    StressLevel,
    TrainingLoad,
)
from api.protocols.why import build_whys


def _profile(**overrides) -> IntakeProfile:
    base = {
        "age": 35,
        "sex": Sex.MALE,
        "height_in": 70.0,
        "weight_lb": 200.0,
        "goal": Goal.CUT,
        "work": Occupation.DESK,
        "train": TrainingLoad.NONE,
        "kids": False,
        "med": MedEffect.NONE,
        "stress": StressLevel.MODERATE,
    }
    base.update(overrides)
    return IntakeProfile(**base)


# -- IP worked example: the canonical anchor (PROTOCOL_LOGIC.md §5) -----------


def test_ip_worked_example_exact():
    # Male, 70 in, 200 lb, Moderate activity, 20% deficit (the IP's own worked example).
    # IBW 180 lb · maintenance 2255 · target 1805 · protein 163/131 · fat 54 · carbs 167 ·
    # fruit/veg 6 · fiber 32 (min 25) · water 100.
    c = compute_targets("male", 70.0, 200.0, "Moderate", 20.0)
    t = c.targets
    assert (t.kcal, t.protein, t.protein_min, t.fat, t.carbs) == (1805, 163, 131, 54, 167)
    assert (t.fiber, t.produce_servings, t.water_oz) == (32, 6, 100)
    assert (c.facts.ibw_lb, c.facts.calorie_goal, c.facts.fiber_min) == (180.0, 2255, 25)


# -- IBW formulas -------------------------------------------------------------


def test_hamwi_ibw_male_and_female():
    # Male 70in: base 166, 40% toward 200 -> 166 + 13.6 = 179.6. Female 65in: base 125,
    # 40% toward 140 -> 125 + 6 = 131.0.
    assert hamwi_ibw_lb("male", 70.0, 200.0) == pytest.approx(179.6)
    assert hamwi_ibw_lb("female", 65.0, 140.0) == pytest.approx(131.0)


def test_hamwi_ibw_floors_at_60in():
    # At/under 60in there is no "over 60" term — base only, then 40% toward actual.
    assert hamwi_ibw_lb("male", 60.0, 106.0) == pytest.approx(106.0)
    assert hamwi_ibw_lb("female", 58.0, 100.0) == pytest.approx(100.0)


def test_devine_ibw_retained_for_recalibration():
    # Devine is kept (unused by generate) only so checkin/recommend.py still imports it.
    assert devine_ibw_kg("male", 70) == pytest.approx(73.0)
    assert lb_to_kg(200.0) == pytest.approx(90.7185, abs=1e-3)


# -- Golden personas (compute_protocol: inputs -> inferred activity+deficit) --


def test_persona_male_cut_moderate_equals_worked_example():
    # desk+moderate -> Moderate activity; cut/moderate-stress -> 20% deficit == the IP example.
    t = compute_protocol(_profile(train=TrainingLoad.MODERATE)).targets
    assert (t.kcal, t.protein, t.protein_min, t.protein_max, t.fat, t.carbs, t.fiber) == (
        1805, 163, 131, 163, 54, 167, 32,
    )
    assert (t.water_oz, t.produce_servings, t.meals_per_day, t.version) == (100, 6, 3, 1)


def test_persona_female_maintain_active():
    # on_feet+heavy -> High (30); maintain -> 0% deficit. IBW 131 lb.
    p = _profile(
        sex=Sex.FEMALE, age=28, height_in=65.0, weight_lb=140.0, goal=Goal.MAINTAIN,
        work=Occupation.ON_FEET, train=TrainingLoad.HEAVY, stress=StressLevel.LOW,
    )
    t = compute_protocol(p).targets
    assert (t.kcal, t.protein, t.fat, t.carbs, t.fiber, t.water_oz) == (1785, 119, 54, 206, 25, 70)


def test_persona_male_gain_young():
    # desk+heavy -> High (30); gain -> 10% surplus (app extension beyond the fat-loss IP).
    p = _profile(
        age=24, height_in=72.0, weight_lb=180.0, goal=Goal.GAIN,
        train=TrainingLoad.HEAVY, stress=StressLevel.LOW,
    )
    t = compute_protocol(p).targets
    assert (t.kcal, t.protein, t.fat, t.carbs, t.fiber, t.water_oz) == (2680, 162, 80, 328, 34, 90)


def test_persona_female_cut_high_stress_gentler_deficit():
    # Every gentling factor (high stress -5, hunger-up -5, kids -5, age>=50 -5) drops the cut
    # deficit from 20% to the 10% floor; manual+heavy -> Very High activity (32).
    p = _profile(
        sex=Sex.FEMALE, age=52, height_in=63.0, weight_lb=160.0, goal=Goal.CUT,
        work=Occupation.MANUAL, train=TrainingLoad.HEAVY, kids=True,
        med=MedEffect.HUNGER_INCREASING, stress=StressLevel.HIGH,
    )
    comp = compute_protocol(p)
    assert comp.facts.reduce_pct == pytest.approx(10.0)
    assert comp.facts.activity_level == "Very High"
    assert comp.targets.kcal == 1735
    assert comp.facts.floored is False


def test_persona_female_cut_aggressive_hits_calorie_floor():
    # Low appetite + low stress push the deficit to the 25% cap; desk+none -> Low (25).
    # IBW 60in/110 -> 104 lb -> maintenance 1180; ×0.75 = 885 -> floored to the 1200 female floor.
    p = _profile(
        sex=Sex.FEMALE, age=22, height_in=60.0, weight_lb=110.0, goal=Goal.CUT,
        train=TrainingLoad.NONE, med=MedEffect.HUNGER_SUPPRESSING, stress=StressLevel.LOW,
    )
    comp = compute_protocol(p)
    assert comp.facts.reduce_pct == pytest.approx(25.0)
    assert comp.facts.floored is True
    assert comp.facts.calorie_floor == DEFAULT_TUNABLES.calorie_floor_female
    assert comp.targets.kcal == 1200


def test_high_bmi_cut_not_capped_protein_off_ideal_weight():
    # IP improvement: protein scales off IDEAL weight, so a high-BMI cut no longer overshoots
    # the budget the way an actual-weight basis did (the old RT-18/19 failure mode).
    comp = compute_protocol(_profile(height_in=66.0, weight_lb=320.0))
    assert comp.facts.protein_capped is False
    assert comp.targets.carbs > 0
    assert comp.targets.protein * 4 + comp.targets.fat * 9 <= comp.targets.kcal


# -- Activity + deficit inference (the app's automated "coach" inputs) --------


def test_activity_level_inferred_from_work_and_training():
    from api.protocols.engine import _activity_level

    assert _activity_level(_profile(work=Occupation.DESK, train=TrainingLoad.NONE), DEFAULT_TUNABLES) == "Low"
    assert _activity_level(_profile(work=Occupation.DESK, train=TrainingLoad.MODERATE), DEFAULT_TUNABLES) == "Moderate"
    assert _activity_level(_profile(work=Occupation.ON_FEET, train=TrainingLoad.HEAVY), DEFAULT_TUNABLES) == "High"
    assert _activity_level(_profile(work=Occupation.MANUAL, train=TrainingLoad.HEAVY), DEFAULT_TUNABLES) == "Very High"


def test_cut_deficit_clamped_between_floor_and_max():
    from api.protocols.engine import _reduce_pct

    # A cut is never gentler than the 10% floor nor steeper than the 25% IP cap, whatever the mix.
    gentle = _profile(goal=Goal.CUT, kids=True, age=70, med=MedEffect.HUNGER_INCREASING, stress=StressLevel.HIGH)
    steep = _profile(goal=Goal.CUT, med=MedEffect.HUNGER_SUPPRESSING, stress=StressLevel.LOW)
    assert _reduce_pct(gentle, DEFAULT_TUNABLES) == pytest.approx(10.0)
    assert _reduce_pct(steep, DEFAULT_TUNABLES) == pytest.approx(25.0)
    assert _reduce_pct(_profile(goal=Goal.MAINTAIN), DEFAULT_TUNABLES) == pytest.approx(0.0)


def test_meals_per_day_preference_respected_and_clamped():
    assert compute_protocol(_profile(meals_per_day=5)).targets.meals_per_day == 5
    assert compute_protocol(_profile(meals_per_day=12)).targets.meals_per_day == 6
    assert compute_protocol(_profile(meals_per_day=1)).targets.meals_per_day == 2
    assert compute_protocol(_profile()).targets.meals_per_day == 3


# -- Rails / invariants -------------------------------------------------------


def test_calorie_floors_match_ip():
    assert DEFAULT_TUNABLES.calorie_floor_male == 1500
    assert DEFAULT_TUNABLES.calorie_floor_female == 1200


def test_kcal_never_below_floor_across_extremes():
    for p in (
        _profile(sex=Sex.FEMALE, height_in=60.0, weight_lb=90.0, med=MedEffect.HUNGER_SUPPRESSING),
        _profile(sex=Sex.MALE, height_in=64.0, weight_lb=120.0),
    ):
        comp = compute_protocol(p)
        floor = DEFAULT_TUNABLES.calorie_floor_male if p.sex == Sex.MALE else DEFAULT_TUNABLES.calorie_floor_female
        assert comp.targets.kcal >= floor


def test_targets_are_integers():
    t = compute_protocol(_profile()).targets
    for value in (t.kcal, t.protein, t.carbs, t.fat, t.fiber, t.water_oz, t.produce_servings):
        assert isinstance(value, int)


def test_protein_band_floor_to_ideal():
    # Protein min (1.6 g/kg IBW) < target == max (2.0 g/kg IBW): a floor-to-ideal optimal band.
    t = compute_protocol(_profile(train=TrainingLoad.MODERATE)).targets
    assert (t.protein_min, t.protein, t.protein_max) == (131, 163, 163)
    assert t.protein_min < t.protein <= t.protein_max


def test_carbs_never_negative_and_macros_reconcile():
    for p in (_profile(train=TrainingLoad.MODERATE), _profile(sex=Sex.FEMALE, height_in=60.0, weight_lb=90.0)):
        t = compute_protocol(p).targets
        assert t.carbs >= 0
        macro_kcal = t.protein * 4 + t.carbs * 4 + t.fat * 9
        assert abs(macro_kcal - t.kcal) <= 4


def test_pure_deterministic_repeatable():
    p = _profile(train=TrainingLoad.MODERATE, kids=True, stress=StressLevel.HIGH)
    assert compute_protocol(p).targets.model_dump() == compute_protocol(p).targets.model_dump()


def test_formula_pluggable_tunables_swap_changes_output():
    # Decision #35: swapping the data changes the result with no logic change. A bigger fat
    # fraction must raise fat and (budget fixed) lower carbs.
    p = _profile(train=TrainingLoad.MODERATE)
    base = compute_protocol(p).targets
    tuned = compute_protocol(p, tunables=replace(DEFAULT_TUNABLES, fat_pct=0.40)).targets
    assert tuned.fat > base.fat
    assert tuned.carbs < base.carbs


# -- Deterministic "why" references the actual inputs -------------------------


def test_why_references_inputs_and_numbers():
    p = _profile(train=TrainingLoad.MODERATE)
    comp = compute_protocol(p)
    whys = build_whys(p, comp.facts, comp.targets)
    for key in ("kcal", "protein", "carbs", "fat", "fiber", "water", "produce", "meals"):
        assert whys[key].strip()
    assert str(comp.targets.kcal) in whys["kcal"]
    assert "ideal weight" in whys["kcal"].lower()
    assert "moderate" in whys["kcal"].lower()  # the inferred activity level is named
    assert "deficit" in whys["kcal"].lower()
    assert str(comp.targets.protein) in whys["protein"]
    assert str(comp.targets.water_oz) in whys["water"]
    assert "200" in whys["water"]


def test_why_surfaces_calorie_floor():
    p = _profile(
        sex=Sex.FEMALE, age=22, height_in=60.0, weight_lb=110.0, goal=Goal.CUT,
        med=MedEffect.HUNGER_SUPPRESSING, stress=StressLevel.LOW,
    )
    comp = compute_protocol(p)
    whys = build_whys(p, comp.facts, comp.targets)
    assert comp.facts.floored is True
    assert "floor" in whys["kcal"].lower()
    assert str(comp.facts.calorie_floor) in whys["kcal"]
