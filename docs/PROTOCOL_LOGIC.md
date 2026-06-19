# Protocol Logic

Deterministic specification for protocol generation. Every number a user sees is computed by tested Python implementing this file — never by a model. The AI's only role is phrasing the "why" from structured engine output it cannot override (decision #10). Safety rails live in the engine, not the prompt (decision #18).

Authored fresh for Vo-Cal. Protocol versions are immutable rows with a `supersedes` FK; revisions (weekly check-ins) re-run this same pipeline with the same rails (decision #19).

## Pipeline

intake answers → BMR → TDEE → goal adjustment (railed) → macro split → meal structure → behavioral rules → "why" slots → disclaimer. Each stage's output is structured and logged so the protocol is fully explainable.

## 1. BMR — Mifflin-St Jeor

With weight `W` in kg, height `H` in cm, age `A` in years:

- **Male:** `BMR = 10·W + 6.25·H − 5·A + 5`
- **Female:** `BMR = 10·W + 6.25·H − 5·A − 161`

## 2. TDEE — activity × occupation

`TDEE = BMR × (activity multiplier + occupation adjustment)`

| Activity (training/leisure) | Multiplier |
|---|---|
| Sedentary (little/no exercise) | 1.2 |
| Lightly active (1–3 sessions/week) | 1.375 |
| Moderately active (3–5 sessions/week) | 1.55 |
| Very active (6–7 sessions/week) | 1.725 |

| Occupation | Adjustment to the multiplier |
|---|---|
| Desk | +0.00 |
| On-feet (retail, teaching, nursing) | +0.05 |
| Manual labor | +0.10 |

Occupation is asked separately from training precisely because the standard multipliers conflate them; this is part of pillar ① (a real personalized protocol).

## 3. Goal adjustment + safety rails

Intake captures goal direction (cut / maintain / gain) and desired rate in kg/week.

- **Rate → daily kcal delta:** `delta = rate_kg_per_week × 7700 / 7` (≈ 1100 kcal/day per kg/week).
- `target_kcal = TDEE − delta` (cut) or `TDEE + delta` (gain).

**Safety rails (hard, engine-enforced, clamps recorded for the "why"):**

1. **Max rate:** |rate| is clamped to the equivalent of **1% of bodyweight per week** (i.e. max daily delta = `0.01 × W × 7700 / 7 = 11 × W` kcal/day).
2. **Absolute calorie floors:** target_kcal is clamped to **≥ 1400 kcal (female)** / **≥ 1600 kcal (male)**, regardless of requested rate.
3. When a rail clamps the request, the engine emits a `clamp` fact (what was requested, what was granted, which rail) — the "why" must explain it; the UI may not hide it.

## 4. Macro split

Computed in order; later macros take the remainder.

**Protein (g/kg bodyweight), keyed on goal + training age:**

| | Novice (< 2 years lifting) | Trained (≥ 2 years) |
|---|---|---|
| Cut | 2.0 | **2.2** (high end — muscle retention in a deficit) |
| Maintain | 1.6 | 1.8 |
| Gain | 1.6 | 1.8 |

Range is bounded 1.6–2.2 g/kg. For BMI ≥ 30 the engine uses an adjusted weight basis (midpoint of current and top-of-healthy-BMI weight) so protein targets stay sane.

**Fat floor:** 0.6–0.8 g/kg — **0.6** on a cut (minimum for hormonal health), **0.8** otherwise. Fat may rise above the floor only by taking from carbs, never from protein.

**Carbs = remainder:** `carbs_g = (target_kcal − protein_g×4 − fat_g×9) / 4`. If the remainder goes negative, the engine reduces the rate (rail 1 re-applies) rather than breaking the protein or fat bounds.

**Fiber:** `14 g per 1000 kcal` of target intake, rounded to the nearest gram.

## 5. Meal structure

From schedule preferences in intake (meals/day, fasting window, training time):

- Eating window = waking day minus declared fasting window; meals are placed inside it.
- Per-meal protein: distribute evenly, aiming ≥ 0.4 g/kg per meal where meals/day allows.
- If a training time is given, place a meal within ~2 hours before and after it.
- Meal structure is a scaffold, not a rule: meal logs are never judged against it, and the Today screen never shames timing.

## 6. Behavioral rules library

Deterministic rules keyed on intake answers. The engine selects the triggered subset (typically 3–6 per user); each carries a trigger, a prescription, and a "why" slot. The library:

| # | Rule | Trigger (intake answer) | Prescription |
|---|------|------------------------|--------------|
| 1 | Hunger-window pre-logging | Hunger history names a daily danger window (e.g. evenings) | Voice-log the meal for that window earlier in the day, before hunger decides |
| 2 | Weigh-in cadence | Goal = cut/gain; no weigh-in aversion flagged | Daily morning weigh-in, after bathroom, before food; the weekly average is the only number that counts |
| 3 | Reduced weigh-in cadence | Weigh-in aversion / scale-anxiety flagged | 3×/week, same conditions; weekly average still the signal |
| 4 | Protein-first plating | Protein target ≥ 1.8 g/kg or history of missing protein | Plate and eat protein first at every meal; everything else fills what's left |
| 5 | Log-before-first-bite | Always on (the product thesis) | Speak the meal before eating it — the plate is in front of you and fully known |
| 6 | Restaurant component speech | Eats out ≥ 2×/week | Speak components, not dish names: protein, carb, fats, sauces — the lingo tutorial pattern |
| 7 | Alcohol budgeting | Drinks/week > 0 | Count drinks as carbs/fat displacement within the day's targets; never "off the books" |
| 8 | Weekend drift guard | Adherence history flags weekends | Fix breakfast Sat/Sun to a pre-logged usual; decide the first meal in advance, not in the moment |
| 9 | Sleep floor | Reported sleep < 6.5 h | No deficit increase until sleep stabilizes ≥ 7 h; appetite regulation comes first |
| 10 | Step floor | Sedentary occupation + sedentary activity | Daily step target (engine-set from baseline) before any cardio is added |
| 11 | Fasting-window alignment | Fasting preference declared | First meal at window open carries ≥ 0.4 g/kg protein |
| 12 | Planned dessert slot | Sweet-cravings flag | A fixed ~150 kcal dessert slot inside targets, logged like everything else |

Rules are versioned with the protocol; a check-in can add or retire rules in v(n+1) but never silently edit v(n).

## 7. The "why" slots

Every target and every triggered rule has a **"why" slot**: the engine emits structured facts — inputs used, formula stage, clamps applied, rule trigger — and the AI phrases them as one or two plain-English sentences.

Hard constraints on the phrasing step:

- The AI **may not alter, round, re-derive, or introduce numbers**. Numbers in prose are interpolated from engine output fields verbatim.
- The AI may not contradict a clamp fact or soften a safety rail.
- If phrasing fails, the protocol ships with the structured facts rendered plainly. A missing "why" sentence never blocks protocol generation.

## 8. Check-in revisions

Weekly check-ins (self-reported weight, adherence, hunger, energy) feed observed rate-of-change vs. expected back into this pipeline. The engine proposes v(n+1); acceptance creates a new immutable protocol row with `supersedes` pointing at v(n). The same rails apply to every revision — there is no path to a target that bypasses §3.

## 9. Required disclaimer

This exact obligation is part of the spec: **a not-medical-advice disclaimer must appear on the intake flow and on every protocol screen.** Canonical copy:

> Vo-Cal provides general nutrition information and is not medical advice. Consult a physician before changing your diet, especially if you are pregnant, nursing, under 18, or have a medical condition or history of disordered eating.

The disclaimer is not dismissible-forever, not buried in settings, and its presence is asserted by UI tests. The calorie floors and rate caps in §3 are the engine-side half of the same health posture (App Review included).

---

## 2026-06-18 — SUPERSEDING UPDATE (cofounder call; decisions #35–37)

The Mifflin-St Jeor → TDEE model above is **replaced** by Francesco's coaching method. Keep this section authoritative until his Notion formulas (NDA) arrive and are encoded.

- **Target = calories per kg of IDEAL body weight.** Fat loss ≈ **24–29 cal/kg IBW**. IBW from gender/height/weight (body comp refines). Placement within the 24–29 band is **set by the human intake**, not the user: high stress / single parent / hunger-raising meds → lighter deficit (higher end); low appetite / hunger-suppressing meds → more aggressive (lower end); also age, menopausal status, training load.
- **Protein** scales with bodyweight. **Water** ≈ half bodyweight in ounces. **Fiber** ∝ calorie intake. **Produce** = servings/day target. These five (calories, protein, produce, fiber, water) are the dashboard.
- **Activity is inferred, never asked** (#36) — derive from occupation + routine + obligations + steps, because self-reported activity is systematically over-rated.
- **Formula-pluggable engine.** Build the protocol engine so the decision-tree thresholds/coefficients are data, not hardcoded — Francesco's real tree drops in without a rewrite. The 24–29 band + the scaling rules above are the documented starting model.
- **Monthly recalibration (later, design for it):** recalibrate to adjusted IBW on weight change; no-progress-but-compliant → knock cal/kg down one point; surface honest diagnostics on "why no progress?" (movement, logging accuracy). Decision-tree, not judgment.
- The deep intake also exists to make the user **feel seen** — a retention driver, not only accuracy.
