# Protocol Logic — PRO Training Solutions Nutrition IP v2.0

> **CONFIDENTIAL — TRADE SECRET.** Proprietary to PRO Training Solutions LLC (Francesco
> Provinzano). Covered by the parties' NDA. Dated June 20, 2026.

Deterministic specification for protocol generation. Every number a user sees is computed by
tested Python (`services/api/src/api/protocols/engine.py`) implementing this file — never by a
model (AGENTS.md #6 / decision #10). The AI's only role is phrasing the "why" from structured
engine output it cannot override. Safety rails (the calorie floor, §3.1) live in the engine.

This v2.0 IP **supersedes** the earlier Mifflin / Devine cal-per-kg-band model. Protocol versions
are immutable rows with a `supersedes` FK; weekly check-ins re-run the pipeline with the same
rails (decision #19). The engine is "formula-pluggable" (decision #35): every coefficient lives
in `ProtocolTunables`, so a revised IP drops in by swapping that object.

---

## 0. Purpose, Scope & Safety

These targets are general fitness-coaching guidance, not clinical or medical nutrition therapy.
All calorie targets are subject to the minimum floor (§3.1) and must never be set below it. Not
for pregnancy, minors, or anyone with a medical condition or history of disordered eating —
direct such users to a qualified professional. The app surfaces a not-medical-advice disclaimer
on the intake flow: not dismissible-forever, not buried in settings, and its presence is asserted
by UI tests (App Review health posture).

## 1. Inputs, Units & Conventions

**Client inputs:** Sex (Male/Female) · Height (in) · Current Weight (lb) · Activity Level
(Low/Moderate/High/Very High) · Reduce Calories (deficit %, coach-selected, 0–25%).

- Weight → kg with factor `0.453592`.
- Calories round to nearest 5 kcal; grams/servings/oz round to nearest whole number.
- Calorie targets are GROSS intake — exercise is never added back (activity is in the factor).
- Any goal returns blank when a required input is missing.

**Vo-Cal mapping (no coach in-app, activity inferred — decision #36):** `_activity_level` maps
occupation + training to the four Activity Levels; `_reduce_pct` picks the deficit from the goal
(cut 20% base / maintain 0% / gain −10% surplus extension), gentled by stress / appetite meds /
kids / age, stepped to 5% and clamped to [10%, 25%] for a cut.

## 2. Foundation Formulas

**2.1 Ideal Bodyweight (lb)** — Hamwi base (M: 106 + 6/in over 60″; F: 100 + 5/in over 60″),
adjusted 40% toward actual weight: `round(base + (CurrentWeight − base) × 0.4)`.

**2.2 Calorie Goal (maintenance)** — `round(ibw_kg × perkg / 5) × 5`, perkg =
{Low 25, Moderate 27.6, High 30, Very High 32}.

**2.3 Calorie Target (after deficit)** — `round(CalorieGoal × (1 − ReduceCalories/100) / 5) × 5`
(floor applied per §3.1).

**2.4 Protein** — Ideal `round(ibw_kg × 2.0)`; Min `round(ibw_kg × 1.6)`.

**2.5 Fruit & Veg (servings)** — `round(CalorieGoal / 400)`.

**2.6 Fiber** — Min `round(CalorieGoal/1000 × 11)`; Ideal `round(CalorieGoal/1000 × 14)`.

**2.7 Water (oz)** — `round(CurrentWeight × 0.5)`.

## 3. Version 2.0 Extensions

**3.1 Calorie Floor (safety) [configurable]** — final target never below the floor. Defaults
1,500 (M) / 1,200 (F): `max(CalorieTargetRaw, Floor[Sex])`. Sourced from the engine tunables so
generate and recalibration share one value.

**3.2 Macronutrient Targets** — Protein anchors to §2.4 ideal; Fat = `round(CalorieTarget ×
FatPct / 9)` (FatPct default 0.27 [configurable]); Carbs = `max(round((CalorieTarget − Protein×4
− Fat×9) / 4), 0)`. Guardrail: if protein + fat exceed the target, cap protein so carbs never go
negative (never display a negative macro).

**3.3 Weekly Auto-Adjustment (titration) [configurable]** — compare avg weight change to a
0.5–1.0%/week target; too slow `ReduceCalories += 5`, too fast `−= 5`; clamp 0–25%, one 5% step
per week, re-apply the §3.1 floor. *(Recalibration currently runs the prior cal/kg-band tree in
`checkin/recommend.py`; aligning it to this §3.3 model is a tracked follow-up — it shares the
§3.1 floor today.)*

**3.4 Recalculation Cadence** — recompute when Current Weight changes ≥ 5 lb or at each weekly
check-in.

## 4. Validation & Edge Cases

- Reject non-numeric / non-positive height/weight (blank output).
- Plausibility warnings (don't hard-fail): height 48–84 in; weight 70–600 lb.
- Clamp Reduce Calories to 0–25% and flag if out of range.

## 5. Worked Example

Male, 70 in, 200 lb, Moderate, 20% → IBW 180 lb · maintenance 2,255 · target 1,805 · protein
163/131 g · fat 54 g · carbs 167 g · fruit/veg 6 · fiber 25/32 g · water 100 oz. *(Pinned as the
golden test `test_ip_worked_example_exact`.)*
