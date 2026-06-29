---
name: vocal-nutrition-goals
description: Calculate a client's nutrition-protocol nutrient goals for the Vo-Cal app (calories, protein, macros, fiber, fruit/veg, water) from their sex, height, weight, activity level, and deficit. Use when asked to build a nutrition protocol, compute calorie/macro/fiber/water targets, set up a client's goals, or apply the PRO Training Solutions / Vo-Cal nutrition formulas.
---

# Vo-Cal Nutrition Goals

Compute a client's full set of nutrient goals from the PRO Training Solutions / Vo-Cal protocol (v2.0). CONFIDENTIAL — these formulas are trade-secret IP of PRO Training Solutions LLC. The canonical spec is `docs/PROTOCOL_LOGIC.md`; the production implementation is `services/api/src/api/protocols/engine.py` (deterministic, tested). This skill is the human-facing reference.

## Scope & safety (read first)

These are general fitness-coaching targets, not clinical nutrition advice. Always apply the calorie floor (Step 6) so a target is never set below it. Do not use for pregnancy, minors, or anyone with a medical condition or history of disordered eating — direct them to a qualified professional.

## Inputs

Collect these before calculating. If any required input is missing, leave the dependent output blank.

- **Sex** — Male / Female
- **Height** — inches
- **Current Weight** — pounds (lb)
- **Activity Level** — Low / Moderate / High / Very High
- **Reduce Calories** — deficit percentage (0–25%), chosen by the coach

## Conventions

- Convert pounds to kg with factor `0.453592`.
- Round calories to the nearest 5 kcal; round grams/servings/ounces to the nearest whole number.
- Calorie targets are GROSS intake — never add exercise back; activity is already in the activity factor.
- Energy factors: protein and carbs = 4 kcal/g, fat = 9 kcal/g.

## Calculation steps

**Step 1 — Ideal Bodyweight (lb).** Hamwi base, adjusted 40% toward actual weight.

```
base = (Sex == "Male") ? 106 + 6*max(Height-60, 0)
                       : 100 + 5*max(Height-60, 0)
IdealBodyweight = round(base + (CurrentWeight - base) * 0.4)
```

**Step 2 — Calorie Goal (maintenance).** Activity factor (kcal/kg): Low 25, Moderate 27.6, High 30, Very High 32.

```
ibw_kg = IdealBodyweight * 0.453592
CalorieGoal = round((ibw_kg * perkg) / 5) * 5
```

**Step 3 — Calorie Target (pre-floor).** Apply the deficit.

```
CalorieTargetRaw = round((CalorieGoal * (1 - ReduceCalories/100)) / 5) * 5
```

**Step 4 — Protein.**

```
Protein Ideal (g) = round(IdealBodyweight * 0.453592 * 2.0)
Protein Min   (g) = round(IdealBodyweight * 0.453592 * 1.6)
```

**Step 5 — Fruit/Veg, Fiber, Water.**

```
Fruit/Veg (servings) = round(CalorieGoal / 400)
Fiber Min   (g)      = round((CalorieGoal / 1000) * 11)
Fiber Ideal (g)      = round((CalorieGoal / 1000) * 14)
Water Min   (oz)     = round(CurrentWeight * 0.5)
```

**Step 6 — Calorie Floor (safety).** Defaults: 1,500 male / 1,200 female (configurable). Flag if near the floor.

```
CalorieTarget = max(CalorieTargetRaw, Floor[Sex])
```

**Step 7 — Macros.** Protein anchors to the ideal; fat is a % of calories; carbs are the remainder.

```
Protein (g) = Protein Ideal
Fat (g)     = round(CalorieTarget * FatPct / 9)        // FatPct default 0.27
Carbs (g)   = max(round((CalorieTarget - Protein*4 - Fat*9) / 4), 0)
```

Guardrail: if protein + fat exceed the calorie target, lower FatPct or cap protein so carbs never go negative.

## Weekly auto-adjustment (optional)

Each week, nudge the deficit toward a 0.5–1.0% bodyweight/week loss rate, one 5% step max, then recompute (re-apply the floor):

```
rate = (weight_start - weight_now) / weight_start / weeks_elapsed
if rate < 0.005: ReduceCalories += 5    // too slow
if rate > 0.010: ReduceCalories -= 5    // too fast
ReduceCalories = clamp(ReduceCalories, 0, 25)
```

Recompute the full goal set whenever weight changes ≥ 5 lb or at each weekly check-in.

## Validation

- Treat non-numeric or non-positive height/weight as missing (blank output).
- Plausibility warnings (don't hard-fail): height 48–84 in; weight 70–600 lb.
- Clamp Reduce Calories to 0–25% and flag if it was out of range.

## Output format

Present the goals as a clean list (or table): Calorie Target, Protein (ideal/min), Fat, Carbs, Fruit/Veg, Fiber (min/ideal), Water. Note when the calorie floor was applied.

## Worked example

Male, 70 in, 200 lb, Moderate, 20% deficit → IBW 180 lb · Calorie Goal 2,255 · Calorie Target 1,805 · Protein 163/131 g · Fat 54 g · Carbs 167 g · Fruit/Veg 6 · Fiber 25/32 g · Water 100 oz.
