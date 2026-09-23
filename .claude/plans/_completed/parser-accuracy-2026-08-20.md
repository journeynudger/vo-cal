# Parser accuracy — brand lines & variant axes (2026-08-20)

> Status: Done. Shipped (TestFlight build 27, 2026-09-23). Unticked boxes below are the original plan as written, not open work.

> Source: customer feedback via Lorenzo, 2026-08-20 — flavored Coffee-mate creamers
> "extremely difficult to track"; Fairlife ultra-filtered milk resolving as Fairlife
> protein shakes; skim/1%/2%/whole "trips it up". General theme: "not logging the
> accurate item." Constraint: fix efficiently, never raising the app's per-parse cost.

## The three failure classes (and the deterministic lever for each)

1. **Curated-brand lines mispriced by the AI-first branded route** (Fairlife → sibling
   products) → `lookup_branded`: "<brand> <name>" dictionary check BEFORE the paid
   estimator, gated so it only accepts entries that themselves mention the brand — the
   2026-07 Chobani AI-first fix stays intact for uncurated brands. Fewer estimator
   calls, not more.
2. **Flavor/brand-line prefixes missing the dictionary** ("kitkat creamer", "strawberry
   greek yogurt") → longest-token-suffix rescue (new `MatchKind.SUFFIX`, confidence-
   discounted) + deterministic prefix→variant pinning (a spoken variant key pins it; a
   spoken flavor pins `flavored`; plain-words block the pin). Ordering: before the
   estimator for non-mass amounts (cost win), after FDC for stated masses (FDC's exact
   row still beats the approximation — "50g bison bacon").
3. **Material variants with no axis or no entry** → seed: Fairlife line (5 entries,
   fat-level axis), 1% milk + one_percent on the milk axis, RTD protein shake
   (standard/high_protein axis; core power/premier/muscle milk aliases), coffee creamer
   (flavored/original/sugar_free axis), diet sodas (zero-cal entries) + regular/diet
   axis on bare soda, greek-yogurt plain/flavored axis, almond-milk sweetened axis,
   oatmeal flavored axis, half & half, heavy cream, chocolate milk (+ Fairlife),
   powdered PB. 170 → 188 entries.

Plus: one few-shot (fat-percent normalizes INTO the name, brand rides separately,
flavors stay in the name) — PROMPT_VERSION `vocal-parser-2026-08-20.8`, ≈250 prompt
tokens/parse, the only recurring cost delta (fractions of a cent; offset by estimator
calls the dictionary now absorbs). iOS: chip labels humanize underscores (display only;
the raw key stays the answer contract).

## Verification

- [x] 102 dictionary/resolver tests incl. 18 new (suffix, brand gate, Chobani
      regression guard, probe renames where "bison bacon"/"idaho potato" became
      legitimately resolvable)
- [x] `scripts/check-api` green (677)
- [x] `scripts/parser-eval`: 35 → 44 fixtures, extraction F1 1.000, field acc 1.000,
      canonical-four PASS, Q precision 0.50 → 0.65 at recall 1.00 (two pre-existing
      fixtures gained justified axis chips; expectations updated with rationale)
- [x] 8 new calorie-corpus bands (49 → 57)
- [x] `bin/ios-app-build` zero warnings
- [x] **Commit:** `feat(parser): curated brand lines, suffix rescue, variant axes`
