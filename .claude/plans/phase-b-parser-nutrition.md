# Phase B — Parser + Nutrition Engine

> Status: Queued (blocked on Phase A; runs in parallel with Phase C)
> Owner: @lorenzo
> Branch: `phase-b-parser-nutrition`
> Next: B0

## Goal

Build Vo-Cal's actual product risk — transcript → structured items → macros → confidence → at-most-one clarifying question — entirely backend-first, testable with plain-text transcripts before the mic exists. This is P0 items 4, 5, 6, 7 (engine). Without this, voice capture produces audio nobody can act on. The whole phase is pytest-driven against a fixture corpus of messy real speech; the corpus becomes the permanent regression net (doccure SCORES.md pattern). Touches: `services/api/src/api/{parser,nutrition,meals}/`, `services/api/tests/`, `docs/PARSER_CONTRACT.md`.

## Decisions locked

- **Backend-first, zero iOS dependency.** Every task here proves out with pytest. Phase D consumes the finished endpoints.
- **Dictionary-first resolution, USDA second.** The internal food dictionary answers the high-frequency foods with curated conversion factors (raw/cooked, oz/cup→g); USDA FDC covers the long tail. Dictionary hits are higher-confidence than FDC search hits, and that feeds the confidence score.
- **LLM parses; deterministic code calculates.** Claude extracts structure from speech (names, amounts, states, ratios). All macro math, unit conversion, and threshold logic is deterministic Python — auditable and unit-testable. The LLM never invents calorie numbers.
- **The fixture corpus is binding.** A change that regresses corpus accuracy does not merge, same as doccure's real-PDF corpus rule.
- **Parser model `claude-sonnet-4-6` default**, `PARSER_MODEL` env override; evaluate `claude-haiku-4-5-20251001` for latency in B7 and record the verdict in `docs/DECISIONS.md`.

## Context

Depends on Phase A (backend scaffold A5, schema A6, contract doc A2). The clarifying-question threshold (>75 cal or >10g macro swing) is defined once in `docs/PARSER_CONTRACT.md`; this phase implements it. Phase D builds the UX on these endpoints; Phase C's enrichment worker calls `parse` after transcription.

---

## Tasks

### B0. Contract schemas + fixture corpus

The contract in code, plus the test set everything else is measured against.

- [ ] **Step 1.** `parser/schemas.py` — Pydantic models mirroring `docs/PARSER_CONTRACT.md` exactly: `ParsedMeal{meal_type, items[], missing_details[]}`, `ParsedItem{name, amount, unit, state, fat_ratio, brand, prep_method, confidence}`, `MissingDetail{field, importance, question}`. Strict enums for `unit` (g, oz, lb, cup, tbsp, tsp, piece, slice, scoop, ml) and `state` (raw, cooked, unspecified).
- [ ] **Step 2.** `tests/fixtures/transcripts.yaml` — ≥30 utterances spanning: the four canonical examples ("4oz 93/7 beef", "200g cooked jasmine rice", "Chipotle bowl, double chicken, white rice, mild salsa, light cheese", "burger, unknown beef, regular cheddar, mayo"); filler-laden speech ("um so I had like two eggs and uh some toast"); compound meals; brand mentions; ambiguous amounts ("a bowl of rice", "some chicken"); transcription artifacts ("ninety three seven beef", "four ounces"); metric+imperial mixes; multi-item run-ons. Each fixture carries expected key fields (item count, names normalized, amounts where stated, which `missing_details` must fire).
- [ ] **Test:** fixture loader + schema validation round-trip.
- [ ] **Acceptance:** corpus loads; schema rejects malformed contract JSON with field-level errors.
- [ ] **Commit:** `feat(parser): contract schemas + messy-speech fixture corpus`

### B1. Internal food dictionary v1

The curated core that makes common meals accurate and fast.

- [ ] **Step 1.** Seed data (`nutrition/dictionary_seed.json` → `food_dictionary` table): 150–300 entries covering ground meats by fat ratio (70/30→97/3), poultry cuts, eggs, common fish, rice/pasta/potato (raw AND cooked variants with conversion factors), breads/tortillas, dairy + cheeses by type, oils/butters, condiments (mayo, ketchup, salsa, dressings with "light/regular" variants), common bowl components (beans, corn, guac), protein powder. Per entry: canonical name, aliases (incl. spoken forms: "ninety three seven" → 93/7), per-100g macros (kcal, P, C, F, fiber), unit conversions (e.g. 1 cup cooked jasmine rice = 158g), raw↔cooked factor where applicable.
- [ ] **Step 2.** `nutrition/dictionary.py` — normalized lookup: lowercase/strip, alias resolution, fat-ratio parameterized lookup for ground meats, "light/double/extra" quantity modifiers (light cheese = 0.5×, double chicken = 2× the standard serving).
- [ ] **Test:** lookups for every canonical fixture food; modifier math; alias hits.
- [ ] **Acceptance:** all four canonical examples resolve fully from the dictionary without touching USDA.
- [ ] **Commit:** `feat(nutrition): internal food dictionary v1 + lookup module`

### B2. USDA FoodData Central client

Long-tail coverage with caching, never on the hot path of common foods.

- [ ] **Step 1.** `nutrition/fdc_client.py` — async httpx client: `GET /v1/foods/search` (SR Legacy + Foundation data types preferred over Branded), `GET /v1/food/{fdcId}`; map nutrient IDs → canonical `NutrientProfile` (kcal, protein, carbs, fat, fiber per 100g); API-key env, timeout + retry, graceful degradation (FDC down ⇒ item resolves as low-confidence with a `missing_details` entry, never a 500).
- [ ] **Step 2.** `usda_cache` read-through (search-term and fdc_id keyed) so repeat foods cost zero FDC calls.
- [ ] **Test:** recorded-response fixtures (no live FDC in CI); cache-hit path; degradation path.
- [ ] **Acceptance:** "spanakopita" (not in dictionary) resolves via FDC fixtures; second call hits cache.
- [ ] **Commit:** `feat(nutrition): USDA FDC client with read-through cache`

### B3. LLM parse step

Speech structure extraction with Claude, schema-enforced.

- [ ] **Step 1.** `parser/llm.py` — Anthropic client, tool-forced structured output against the B0 schema (tool `record_parsed_meal`, `tool_choice` forced). System prompt encodes the logging lingo: every ingredient is its own item; capture fat ratios, brands, prep methods, raw/cooked; never guess unstated amounts — emit a `missing_details` entry instead; normalize spoken numbers ("four ounces" → 4 oz). 4–6 few-shot examples drawn from the corpus.
- [ ] **Step 2.** Post-validation: Pydantic parse of the tool output; one retry with the validation error appended on schema mismatch; reject empty-item parses. Prompt text versioned in `parser/prompts.py` with a `prompt_version` string stored on every `parses` row.
- [ ] **Test:** corpus subset against recorded LLM responses (live-call tests behind a `-m live` marker, excluded from CI).
- [ ] **Acceptance:** canonical four parse correctly: "Chipotle bowl..." yields 5 items with modifiers; "burger, unknown beef..." yields beef item with `fat_ratio=null` + missing_detail for it.
- [ ] **Commit:** `feat(parser): Claude structured-output parse step with prompt versioning`

### B4. Resolution + macro calculation

Deterministic bridge from parsed items to numbers.

- [ ] **Step 1.** `nutrition/resolver.py` — per item: dictionary lookup → (miss) FDC search → quantity normalization to grams (unit conversions; count-based units via per-piece weights; raw/cooked factor applied when `state` says so) → `NutrientProfile` × grams → item macros. Meal totals = Σ items.
- [ ] **Step 2.** Resolution metadata per item: source (`dictionary` | `fdc` | `unresolved`), match score, grams used — stored for the admin panel and confidence scoring.
- [ ] **Test:** property tests on conversion math (round-trips, monotonicity); golden macro assertions for the canonical four (e.g. 4oz 93/7 beef ≈ 170 kcal / 24P / 0 C / 8F within tolerance).
- [ ] **Acceptance:** corpus items resolve with correct grams and macros within ±5% of hand-checked values.
- [ ] **Commit:** `feat(nutrition): item resolution + deterministic macro calculation`

### B5. Confidence + clarifying-question engine

P0 items 6 and 7. The trust arithmetic.

- [ ] **Step 1.** `parser/confidence.py` — per-item confidence ∈ [0,1] composed from: LLM extraction confidence × resolution match quality (dictionary exact > dictionary alias > FDC top-hit > fuzzy) × amount specificity (stated grams > stated count > inferred serving). Calibration table documented in the module docstring; meal-level confidence = weighted-by-calories mean.
- [ ] **Step 2.** `parser/clarify.py` — for each `missing_details` candidate, compute the macro spread across plausible interpretations (e.g. unknown beef ratio: evaluate 70/30 vs 93/7; unknown rice amount: 0.5 vs 1.5 cups; "some cheese": 0.5 vs 2 slices). If max spread > 75 kcal OR > 10g of any macro → question fires. **Select exactly one**: highest macro-impact candidate. Otherwise: no question, log with stated confidence.
- [ ] **Step 3.** Answer-merge path: applying a user answer re-resolves only the affected item (no full re-parse).
- [ ] **Test:** threshold boundary cases — "93/7 specified" must NOT ask; "unknown beef on a burger" MUST ask (spread ≈ 90 kcal); two candidates → only the bigger one asked; answer-merge updates macros correctly.
- [ ] **Acceptance:** question precision on corpus: every fixture's expected ask/no-ask flag matches.
- [ ] **Commit:** `feat(parser): confidence scoring + single-clarifying-question engine`

### B6. API endpoints + persistence

The contract surface Phase C's worker and Phase D's UI consume.

- [ ] **Step 1.** `parser/router.py` — `POST /parse` (transcript in → full `ParsedMeal` + per-item macros + confidence + zero-or-one question out; persists `parses` row); `POST /parse/refine` (parse_id + answers → re-resolved result, new immutable `parses` row referencing the original).
- [ ] **Step 2.** `meals/router.py` — `POST /meals` (parse_id + confirmed items → `meal_logs` row; every field-level divergence parsed-vs-confirmed persisted to `corrections`; optional `save_as_usual` → `saved_meals`); `GET /meals?date=` (tz-aware day window); `DELETE /meals/{id}` (tombstone, not hard delete — INVARIANTS rule).
- [ ] **Step 3.** RLS-scoped stores per Beacon's store.py pattern; metrics counters (parse latency, question rate, correction count) on every path.
- [ ] **Test:** API tests: full parse→refine→confirm→corrections flow; RLS probe; tombstone semantics.
- [ ] **Acceptance:** end-to-end pytest: transcript string in → confirmed meal_log with corrections recorded, all rows immutable where the schema says so.
- [ ] **Commit:** `feat(api): parse/refine/meals endpoints with append-only corrections`

### B7. Parse quality harness (regression net)

The binding corpus score, doccure-style.

- [ ] **Step 1.** `scripts/parser-eval` — runs the full corpus through parse→resolve→confidence, reports: item-extraction F1, field accuracy (amount/unit/state/fat_ratio/brand), macro MAE vs hand-checked values, question precision/recall, p50/p95 latency per model. Writes `tests/fixtures/SCORES.md`.
- [ ] **Step 2.** Run for `claude-sonnet-4-6` and `claude-haiku-4-5-20251001`; record the model verdict (accuracy vs latency) in `docs/DECISIONS.md`.
- [ ] **Step 3.** AGENTS.md rule: parser/nutrition changes must re-run `scripts/parser-eval`; a SCORES regression does not merge.
- [ ] **Acceptance:** SCORES.md baseline committed; the four canonical examples at 100% field accuracy; corpus item-extraction ≥90%.
- [ ] **Commit:** `feat(parser): corpus eval harness + SCORES baseline`

---

## Exit Criteria

- ✅ Plain-text transcript → parsed items → macros → confidence → ≤1 question, fully via API, RLS-scoped, all under pytest.
- ✅ Canonical four examples: correct structure, correct macros (±5%), correct ask/no-ask behavior.
- ✅ Corrections persist append-only; refine creates new immutable parse rows.
- ✅ SCORES.md regression net committed and wired into AGENTS.md as a merge gate.

## Amendments

*(none yet)*

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| B0 Contract schemas + corpus | not started | — |
| B1 Food dictionary v1 | not started | — |
| B2 USDA FDC client | not started | — |
| B3 LLM parse step | not started | — |
| B4 Resolution + macro calc | not started | — |
| B5 Confidence + clarify engine | not started | — |
| B6 API endpoints + persistence | not started | — |
| B7 Quality harness | not started | — |
