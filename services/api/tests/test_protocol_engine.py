"""F3: deterministic protocol engine — golden personas + rails (offline, pure).

Every expected number here is hand-checked against PROTOCOL_LOGIC.md's SUPERSEDING
model (decision #35): calories = cal/kg of Devine IBW, band placement shifted by the
human intake, protein ~g/kg bodyweight, fat floor, carbs as the remainder, fiber
14g/1000kcal, water half-bodyweight-oz, produce 5/day. If a coefficient in
``engine.DEFAULT_TUNABLES`` changes, these goldens must be re-derived on purpose —
that is the point of pinning them (the math is the product).
"""

from __future__ import annotations

import math

import pytest

from api.protocols.engine import (
    DEFAULT_TUNABLES,
    compute_protocol,
    devine_ibw_kg,
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


# -- high-BMI cut: macros must reconcile and stay within budget (RT-18/19/40) -


def _high_bmi_cut() -> IntakeProfile:
    # BMI ≈ 51.6 — the spec's high-BMI cut case; protein off raw bodyweight (290 g) alone
    # exceeded the IBW-based kcal budget, overshooting and clamping carbs to 0.
    return _profile(height_in=66.0, weight_lb=320.0, goal=Goal.CUT)


def test_macros_reconcile_for_high_bmi_cut():
    # RT-18: the stored macros must reconcile to the displayed calories (carbs can't be
    # negative, so an overshoot means protein*4 + carbs*4 + fat*9 != kcal).
    t = compute_protocol(_high_bmi_cut()).targets
    macro_kcal = t.protein * 4 + t.carbs * 4 + t.fat * 9
    assert abs(macro_kcal - t.kcal) <= 4


def test_high_bmi_protein_fat_bounded_by_budget():
    # RT-19: protein/fat off ACTUAL bodyweight were unbounded for high-BMI users (protein
    # alone exceeded the whole budget). They must now provably fit the kcal budget.
    comp = compute_protocol(_high_bmi_cut())
    t = comp.targets
    assert t.protein * 4 + t.fat * 9 <= t.kcal
    assert comp.facts.protein_capped is True  # the raw 2.0 g/kg target was capped to fit
    assert t.protein_max <= t.protein  # the optimal band can't sit above the capped protein


def test_normal_weight_cut_not_capped():
    # A normal-weight cut is unaffected: protein at target, fat at floor, carbs the remainder.
    comp = compute_protocol(_profile(height_in=70.0, weight_lb=200.0, goal=Goal.CUT))
    assert comp.facts.protein_capped is False
    assert comp.targets.carbs > 0


def test_carbs_why_surfaces_overshoot_when_capped():
    # RT-40: when protein is capped and carbs floored to 0, the why must disclose that
    # protein+fat used the full budget — not the false "whatever calories are left".
    profile = _high_bmi_cut()
    comp = compute_protocol(profile)
    whys = build_whys(profile, comp.facts, comp.targets)
    assert comp.facts.protein_capped is True
    assert "budget" in whys["carbs"].lower()
    assert "whatever calories are left" not in whys["carbs"].lower()


# -- Devine IBW ---------------------------------------------------------------


def test_devine_ibw_male_and_female():
    # 70 in male: 50 + 2.3*10 = 73.0; 65 in female: 45.5 + 2.3*5 = 57.0.
    assert devine_ibw_kg("male", 70) == pytest.approx(73.0)
    assert devine_ibw_kg("female", 65) == pytest.approx(57.0)


def test_devine_ibw_floors_at_60in():
    # At or below 60 in there is no "over 60" term — base only, never negative.
    assert devine_ibw_kg("male", 60) == pytest.approx(50.0)
    assert devine_ibw_kg("female", 58) == pytest.approx(45.5)


def test_lb_to_kg_is_exact():
    assert lb_to_kg(200.0) == pytest.approx(90.7185, abs=1e-3)


# -- Golden personas (hand-checked) -------------------------------------------


def test_persona_male_cut_moderate():
    # ibw 73, calkg 26.5 mid + 0.5 (moderate training) = 27.0 (no clamp).
    # kcal 73*27 = 1971. protein 2.0*90.7185 = 181.4 -> 181. fat 0.6*90.7185 = 54.4 -> 54.
    # carbs (1971 - 181*4 - 54*9)/4 = (1971-724-486)/4 = 761/4 = 190.25 -> 190.
    # fiber 14*1971/1000 = 27.594 -> 28. water 200/2 = 100. produce 5. meals 3.
    p = _profile(train=TrainingLoad.MODERATE)
    t = compute_protocol(p).targets
    assert (t.kcal, t.protein, t.fat, t.carbs, t.fiber) == (1971, 181, 54, 190, 28)
    assert (t.water_oz, t.produce_servings, t.meals_per_day) == (100, 5, 3)
    assert t.version == 1


def test_persona_female_maintain_active():
    # ibw 57, band 29-34 mid 31.5; shifts: stress low -1, train heavy +1, on_feet +0.5 = 32.0.
    # kcal 57*32 = 1824. protein 1.6*63.503 = 101.6 -> 102. fat 0.8*63.503 = 50.8 -> 51.
    # carbs (1824 - 408 - 459)/4 = 957/4 = 239.25 -> 239. fiber 14*1824/1000 = 25.5 -> 26. water 70.
    p = _profile(
        sex=Sex.FEMALE,
        age=28,
        height_in=65.0,
        weight_lb=140.0,
        goal=Goal.MAINTAIN,
        work=Occupation.ON_FEET,
        train=TrainingLoad.HEAVY,
        stress=StressLevel.LOW,
    )
    t = compute_protocol(p).targets
    assert (t.kcal, t.protein, t.fat, t.carbs, t.fiber) == (1824, 102, 51, 239, 26)
    assert t.water_oz == 70


def test_persona_male_gain_young():
    # ibw 50+2.3*12 = 77.6, band 34-39 mid 36.5; stress low -1 + train heavy +1 = 36.5.
    # kcal 77.6*36.5 = 2832.4 -> 2832. protein 1.6*81.647 = 130.6 -> 131.
    # fat 0.8*81.647 = 65.3 -> 65. carbs (2832 - 524 - 585)/4 = 430.75 -> 431.
    # fiber 39.6 -> 40. water 90.
    p = _profile(
        age=24,
        height_in=72.0,
        weight_lb=180.0,
        goal=Goal.GAIN,
        train=TrainingLoad.HEAVY,
        stress=StressLevel.LOW,
    )
    t = compute_protocol(p).targets
    assert (t.kcal, t.protein, t.fat, t.carbs, t.fiber) == (2832, 131, 65, 431, 40)
    assert t.water_oz == 90


def test_persona_female_cut_high_stress_clamps_to_band_top():
    # Every gentling factor maxed: stress high +2, train heavy +1, manual +1, hunger-up +1.5,
    # kids +1, age>=50 +1 = +7.5. raw = 26.5 + 7.5 = 34.0, CLAMPED to the cut band top 29.0.
    # ibw 45.5+2.3*3 = 52.4. kcal 52.4*29 = 1519.6 -> 1520 (above the 1400 floor).
    p = _profile(
        sex=Sex.FEMALE,
        age=52,
        height_in=63.0,
        weight_lb=160.0,
        goal=Goal.CUT,
        work=Occupation.MANUAL,
        train=TrainingLoad.HEAVY,
        kids=True,
        med=MedEffect.HUNGER_INCREASING,
        stress=StressLevel.HIGH,
    )
    comp = compute_protocol(p)
    assert comp.facts.placement.raw_cal_per_kg == pytest.approx(34.0)
    assert comp.facts.placement.cal_per_kg == pytest.approx(29.0)
    assert comp.facts.placement.clamped is True
    assert comp.facts.floored is False
    assert comp.targets.kcal == 1520


def test_persona_female_cut_aggressive_hits_calorie_floor():
    # Aggressive: stress low -1, train none -0.5, hunger-suppress -1.5. raw = 26.5-3.0 = 23.5,
    # CLAMPED to the cut band bottom 24.0. ibw 45.5 (60in). 45.5*24 = 1092 < 1400 floor -> 1400.
    p = _profile(
        sex=Sex.FEMALE,
        age=22,
        height_in=60.0,
        weight_lb=110.0,
        goal=Goal.CUT,
        train=TrainingLoad.NONE,
        med=MedEffect.HUNGER_SUPPRESSING,
        stress=StressLevel.LOW,
    )
    comp = compute_protocol(p)
    assert comp.facts.placement.raw_cal_per_kg == pytest.approx(23.5)
    assert comp.facts.placement.cal_per_kg == pytest.approx(24.0)
    assert comp.facts.placement.clamped is True
    assert comp.facts.floored is True
    assert comp.facts.calorie_floor == DEFAULT_TUNABLES.calorie_floor_female
    assert comp.targets.kcal == 1400


def test_meals_per_day_preference_respected_and_clamped():
    # Stated 5 -> kept (inside 2..6). produce always 5 in the starting model.
    p = _profile(meals_per_day=5)
    assert compute_protocol(p).targets.meals_per_day == 5
    # 12 -> clamped down to the 6 max; 1 -> clamped up to the 2 min.
    assert compute_protocol(_profile(meals_per_day=12)).targets.meals_per_day == 6
    assert compute_protocol(_profile(meals_per_day=1)).targets.meals_per_day == 2
    # None -> the default (3).
    assert compute_protocol(_profile()).targets.meals_per_day == 3


# -- Rails / invariants -------------------------------------------------------


def test_male_floor_is_higher_than_female_floor():
    assert DEFAULT_TUNABLES.calorie_floor_male == 1600
    assert DEFAULT_TUNABLES.calorie_floor_female == 1400


def test_placement_never_escapes_the_band():
    # Sweep extremes for every goal; cal_per_kg must always stay within [low, high].
    extremes = [
        {"stress": StressLevel.HIGH, "med": MedEffect.HUNGER_INCREASING, "kids": True, "age": 70},
        {"stress": StressLevel.LOW, "med": MedEffect.HUNGER_SUPPRESSING, "train": TrainingLoad.NONE},
    ]
    for goal in Goal:
        band = DEFAULT_TUNABLES.bands[goal]
        for extra in extremes:
            comp = compute_protocol(_profile(goal=goal, **extra))
            assert band.low <= comp.facts.placement.cal_per_kg <= band.high


def test_targets_are_integers():
    t = compute_protocol(_profile()).targets
    for value in (t.kcal, t.protein, t.carbs, t.fat, t.fiber, t.water_oz, t.produce_servings):
        assert isinstance(value, int)


def test_protein_optimal_band_brackets_target():
    # Protein is a BOUNDED goal (decision: not more-is-merrier — too little and too much are
    # both suboptimal), so the engine emits a band centered on the target: +-0.2 g/kg of body-
    # weight. Male cut moderate, bw 90.7185 kg, 2.0 g/kg center:
    #   min round(1.8*90.7185)=163, target round(2.0*90.7185)=181, max round(2.2*90.7185)=200.
    t = compute_protocol(_profile(train=TrainingLoad.MODERATE)).targets
    assert (t.protein_min, t.protein, t.protein_max) == (163, 181, 200)
    assert t.protein_min < t.protein < t.protein_max
    assert isinstance(t.protein_min, int)
    assert isinstance(t.protein_max, int)


def test_protein_band_brackets_target_across_goals():
    # Whatever the goal's g/kg center, the band always straddles the target with a positive
    # width — the bar can never render an inverted or zero-width range from a real protocol.
    for goal in (Goal.CUT, Goal.MAINTAIN, Goal.GAIN):
        t = compute_protocol(_profile(goal=goal)).targets
        assert t.protein_min < t.protein < t.protein_max


def test_carbs_never_negative_when_floored():
    # A tiny floored woman: kcal pinned to 1400, protein+fat must still leave carbs >= 0.
    t = compute_protocol(
        _profile(sex=Sex.FEMALE, height_in=60.0, weight_lb=90.0, med=MedEffect.HUNGER_SUPPRESSING)
    ).targets
    assert t.carbs >= 0


def test_macros_reconcile_to_kcal_within_rounding():
    # protein*4 + carbs*4 + fat*9 should land within a few kcal of the calorie target
    # (carbs absorb protein/fat rounding by construction).
    t = compute_protocol(_profile(train=TrainingLoad.MODERATE)).targets
    macro_kcal = t.protein * 4 + t.carbs * 4 + t.fat * 9
    assert abs(macro_kcal - t.kcal) <= 4


def test_pure_deterministic_repeatable():
    p = _profile(train=TrainingLoad.MODERATE, kids=True, stress=StressLevel.HIGH)
    first = compute_protocol(p).targets.model_dump()
    second = compute_protocol(p).targets.model_dump()
    assert first == second


def test_formula_pluggable_tunables_swap_changes_output():
    # The whole point of decision #35: swapping the data structure changes the result
    # with no logic change. Halve the fat-loss band ceiling and calories must drop.
    from dataclasses import replace

    from api.protocols.engine import CalPerKgBand

    p = _profile(train=TrainingLoad.MODERATE)
    baseline = compute_protocol(p).targets.kcal
    tuned = replace(
        DEFAULT_TUNABLES,
        bands={**DEFAULT_TUNABLES.bands, Goal.CUT: CalPerKgBand(low=18.0, high=20.0)},
    )
    lowered = compute_protocol(p, tunables=tuned).targets.kcal
    assert lowered < baseline


# -- Deterministic "why" references the actual inputs -------------------------


def test_why_references_inputs_and_numbers():
    p = _profile(train=TrainingLoad.MODERATE)
    comp = compute_protocol(p)
    whys = build_whys(p, comp.facts, comp.targets)
    # One sentence per dashboard target, all non-empty.
    for key in ("kcal", "protein", "carbs", "fat", "fiber", "water", "produce", "meals"):
        assert whys[key].strip()
    # The kcal "why" interpolates the engine numbers verbatim (no re-derivation).
    assert str(comp.targets.kcal) in whys["kcal"]
    assert "ideal body weight" in whys["kcal"]
    # Training was the only shift -> it must be named in the kcal why.
    assert "training" in whys["kcal"].lower()
    # Protein why names the bodyweight basis.
    assert str(comp.targets.protein) in whys["protein"]
    assert "bodyweight" in whys["protein"].lower()
    # Water why states half-bodyweight and the actual lb figure.
    assert str(comp.targets.water_oz) in whys["water"]
    assert "200" in whys["water"]


def test_why_surfaces_calorie_floor_clamp():
    p = _profile(
        sex=Sex.FEMALE,
        age=22,
        height_in=60.0,
        weight_lb=110.0,
        goal=Goal.CUT,
        med=MedEffect.HUNGER_SUPPRESSING,
        stress=StressLevel.LOW,
    )
    comp = compute_protocol(p)
    whys = build_whys(p, comp.facts, comp.targets)
    # A safety rail must be surfaced, never hidden (PROTOCOL_LOGIC.md §3).
    assert "floor" in whys["kcal"].lower()
    assert str(comp.facts.calorie_floor) in whys["kcal"]


def test_why_surfaces_band_clamp_without_floor():
    p = _profile(
        sex=Sex.FEMALE,
        age=52,
        height_in=63.0,
        weight_lb=160.0,
        goal=Goal.CUT,
        work=Occupation.MANUAL,
        train=TrainingLoad.HEAVY,
        kids=True,
        med=MedEffect.HUNGER_INCREASING,
        stress=StressLevel.HIGH,
    )
    comp = compute_protocol(p)
    whys = build_whys(p, comp.facts, comp.targets)
    assert comp.facts.placement.clamped
    assert not comp.facts.floored
    assert "band" in whys["kcal"].lower()


def test_why_never_introduces_a_number_absent_from_facts():
    # Sanity: every integer in the kcal why is one of the engine's emitted figures.
    p = _profile(train=TrainingLoad.MODERATE)
    comp = compute_protocol(p)
    whys = build_whys(p, comp.facts, comp.targets)
    allowed = {
        comp.targets.kcal,
        int(comp.facts.placement.cal_per_kg),
        round(comp.facts.ibw_kg),
        int(comp.facts.placement.band_low),
        int(comp.facts.placement.band_high),
        comp.facts.calorie_floor,
        1000,  # appears only in the fiber why, not kcal — guard anyway
    }
    found = [int(tok) for tok in _ints(whys["kcal"])]
    for n in found:
        assert n in allowed or any(math.isclose(n, a, abs_tol=1) for a in allowed)


def _ints(text: str) -> list[str]:
    out, cur = [], ""
    for ch in text:
        if ch.isdigit():
            cur += ch
        elif cur:
            out.append(cur)
            cur = ""
    if cur:
        out.append(cur)
    return out
