# Voice consistency — one identity per food, however it is said (2026-09-23)

> Status: Active
> Owner: @lorenzo
> Branch: feature/voice-consistency
> Next: P3
> Source: [`voice-accuracy-handoff-2026-09-23.md`](./voice-accuracy-handoff-2026-09-23.md) (diagnosis, file map, acceptance tests).

## Goal

Make voice logging predictable enough that Lorenzo and Francesco trust it as a source of
truth: the SAME food said any reasonable way prices the same sane number, and a manual
amount edit never changes WHAT food is priced. Touches `services/api/src/api/nutrition/`
(resolver, dictionary, fdc_client, estimator, seed), `parser/` (schemas, router, clarify),
`meals/router.py`, the evals under `services/api/tests/`, `Sources/VoCalCore/ParserContract.swift`
and the item edit sheet in `apps/ios/`.

## P0 findings (live, 2026-09-23, keys in repo-root `.env`, FakeDatabase, server on :8001)

Lorenzo's phrasings through `POST /__dev/capture` (per-item source / grams / kcal):

| phrasing | result | verdict |
|---|---|---|
| "200 g cosmic crisp apple" | **fdc**, 200 g, **322 kcal** | WRONG. USDA search ranked "Desserts, apple crisp, prepared-from-recipe" (161 kcal/100 g) |
| "cosmic crisp apple 200 grams" | fdc, 200 g, 322 kcal | same row, same bug |
| "a cosmic crisp apple" | dictionary (suffix → apple), 182 g, 94.6 kcal | right |
| "200 grams of apple" | dictionary, 200 g, 104 kcal | right |
| "a honeycrisp apple" | dictionary (suffix), 94.6 kcal | right |
| "two slices of sourdough toast" | dictionary (suffix "toast" → white bread), 56 g, 149 kcal | wrong head (alias gap) |
| "2 slices of Dave's Killer Bread" | estimated (4 sources), 90 g, 219.6 kcal | sane |
| "a Chobani strawberry greek yogurt" | estimated (0 sources), 150 g, 139.5 kcal | sane |
| "an Oikos triple zero vanilla yogurt" | estimated (3 sources), 150 g, 120 kcal | sane |
| "a Naked green machine smoothie" | estimated (0 sources), 450 g, 283.5 kcal | sane |
| "a Bolthouse strawberry banana smoothie" | estimated (4 sources), 240 g, 129.6 kcal | sane |

Preview totals equalled stored totals for every case (confirm-time re-resolution did not
drift in this run). **The apple is exactly RC1 + RC2 of the handoff:** the ladder picks the
SOURCE by the amount's unit (a stated mass goes to USDA search first), USDA's full-text
ranking matched "crisp" to the apple-crisp dessert, and nothing checks that the chosen row
names the food. Editing "a cosmic crisp apple" to 200 g re-runs the same ladder and swaps
the food. Direct FDC evidence:

```
POST /foods/search "cosmic crisp apple" (Foundation, SR Legacy, Survey, Branded), ranked by tier:
  Survey   2708023  Crisp, apple                                      215 kcal/100g
  SR       169601   Desserts, apple crisp, prepared-from-recipe        161 kcal/100g   <- chosen
  Branded  2191849  COSMIC CRISP DRIED APPLE SLICES (Tree Top)         333 kcal/100g
```

`scripts/calorie-eval` baseline on `main` (8052929): **49/57**, p50 3.5 s, p95 14.4 s.
The 8 failures are all deterministic and belong to two classes plus band noise:

1. Suffix rescue hijacking a composed name: "turkey sandwich with lettuce, tomato" → head
   **tomato** (22 kcal); "caesar salad with chicken breast" → chicken breast; "chicken
   burrito with rice, beans" → beans. The absorbed-dish name (compose.py) was designed to
   flow to the estimator; the 2026-08-20 suffix rescue intercepts it at the last token.
2. Suffix rescue on a homonym / portion word: "salmon roll" → **dinner roll** × 8 (882 kcal);
   "whole margherita pizza" → one slice (285 kcal); "avocado toast" → one slice of white bread.
3. Band edges: "coffee with a splash of kitkat creamer" 19.9 vs [20, 60]; "a bowl of
   strawberry greek yogurt" 245 (one cup of the flavored variant) vs [120, 220].

## Decisions locked

- **Identity never reads the amount (2026-09-23).** `resolve_identity(item)` uses name,
  brand, variant, fat ratio and prep method only; `price(identity, item)` does the grams.
  The identity is persisted on every parse item and primed into the resolver on refine and
  confirm, so amount/unit/state edits re-price the food the user saw. Name/brand/variant/
  fat-ratio edits re-identify (those edits are SUPPOSED to change the food).
- **Curated head before every live source, for every amount kind.** No FDC override of a
  suffix match (the handoff's prefix-token rule is dropped: it kept USDA on the hot path
  for every novel phrasing and mixed USDA bases with curated portions; the head is shown
  as "priced as" and a name edit re-identifies). "50 g bison bacon" prices as bacon.
- **Long-tail identity has one owner.** With an estimator configured it identifies unknown
  foods for every amount kind (it carries serving/per-piece data); USDA FDC is the
  fallback when the estimator is absent or declines, and can price a stated mass only.
- **Branded stays AI-first** (2026-07 Chobani decision) behind a sanity band against the
  curated generic head (P3), with the cache key normalized so phrasings share one answer.
- **The estimator prices formulation changes** ("sugar free", "zero sugar", "fat free",
  "light") that the curated head cannot express as a variant: the suffix rescue declines
  those prefixes instead of pricing the sugared/full-fat head.
- **No em dashes in user-facing copy.** Server questions and iOS strings.

---

## Tasks

### P0. Reproduce live
- [x] `.env` with ANTHROPIC + USDA keys (user-supplied), live server on :8001, preflight live
- [x] calorie-eval baseline 49/57 (`.tmp/calorie-eval.json`), phrasings table above, FDC evidence
- [x] **Commit:** `docs(plans): voice-consistency sub-plan with P0 live findings`

### P1. Separate identity from pricing (RC1)
- [x] `FoodIdentity` value type (`nutrition/schemas.py`), `Resolver.resolve_identity` +
      module-level `price()`; identity memo keyed by identity fields; `Resolver.prime()`
- [x] Persist `identity` + `priced_as` on `ParseResultItem` (optional, additive); stamp
      `identity` on `ConfirmedItem` at confirm; prime from the parse row in `/parse/refine`
      and from the parse row + stored meal row in meals confirm/update/append (server rows
      only; a client-sent identity is never trusted)
- [x] `/__dev/refine` (local-only) so the live evals can exercise the edit flow without a JWT
- [x] **Test:** amount edit keeps identity (resolver + API); unknown food identifies once for
      any amount kind; FDC identity cannot price a count; prime reuse skips the estimator
- [x] **Commit:** `feat(nutrition): resolve identity once, price separately, prime on refine/confirm`

### P2. Deterministic-first identity (RC2, RC4)
- [x] FDC: no Branded rows for brand-less items; relevance gate (every query token in the
      chosen description; first relevant row wins); branded fallback searches "brand name"
- [x] Suffix rescue: never across composed names ("with", ","); declines formulation
      prefixes the entry cannot express; "whole/entire" + sliced head declines (pizza)
- [x] Seed: cultivar/descriptor aliases (apple, tomato, potato, banana), "sourdough toast",
      smoothie family, sushi roll, avocado toast, rye/multigrain bread, Dave's Killer Bread line
- [x] **Test:** dictionary + fdc suites; calorie corpus bands honest (splash, yogurt bowl)
- [x] **Commit:** `feat(nutrition): curated head first, relevant USDA rows only, seed gaps`

### P3. Estimator consistency (RC3)
- [ ] Sanity band for branded estimates against the curated head (declined → head)
- [ ] `estimate_cache_key`: sorted token set of brand + name, articles dropped
- [ ] `ESTIMATOR_VERSION` 5 → 6
- [ ] **Commit:** `feat(nutrition): estimator sanity band and phrasing-proof cache key`

### P4. Prove it
- [ ] calorie corpus: the P0 phrasings with honest bands
- [ ] `tests/consistency_eval.py` + `scripts/consistency-eval`: phrasing groups within 15%
      of each other and inside the band; includes the refine-to-200-g edit
- [ ] parser-eval no regression (SCORES.md)
- [ ] **Commit:** `test(nutrition): consistency eval and corpus additions`

### P5. iOS
- [ ] Name field in `MealItemEditSheet` → `items[i].name` refine answer; server `_apply` name branch
- [ ] "priced as" on the item card when the head differs from what was said
- [ ] Swift mirror: `pricedAs` optional, tolerant decode
- [ ] **Commit:** `feat(ios): edit the food name before logging, show what was priced`

### P6. Ship
- [ ] scripts/check, parser-eval, calorie-eval, consistency-eval, ios-app-build zero warnings
- [ ] merge → main, push, `gh workflow run Deploy --ref main`, publish lane (API-key flags)

---

## Exit Criteria

- ✅ "200 g cosmic crisp apple", "a cosmic crisp apple", "cosmic crisp apple 200 grams" and
  "an apple, 200 grams" all price the curated apple; the refine edit to 200 g keeps it
- ✅ calorie-eval 57+/57+, consistency-eval green, parser-eval no regression
- ✅ Every eval green on the shipped build; Deploy and TestFlight uploaded

## Progress log

| Task | Status | SHA |
|---|---|---|
| P0 | done | 16cedf9 |
| P1 | done | fe01752 |
| P2 | done | — |
| P3 | not started | — |
| P4 | not started | — |
| P5 | not started | — |
| P6 | not started | — |
