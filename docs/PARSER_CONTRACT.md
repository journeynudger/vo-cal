# Parser Contract

Canonical JSON contract between the transcript and everything downstream. `Sources/VoCalCore` types, the FastAPI parser schemas, and the fixture corpus (`scripts/parser-eval`) all mirror this file exactly. If they disagree, this file wins; fix the code.

Authored fresh for Vo-Cal (no Serein/Beacon source). Frozen decisions #9, #10, #11, #12 govern this contract.

## Principles

1. **The LLM extracts structure. It never invents numbers.** Amounts, units, ratios come from the transcript or they are `null`. All macro math, unit conversion, and threshold logic is deterministic, tested Python downstream of the parse. **Brands: stated, or unmistakably implied by a menu-item name.** "A Big Mac" fills `brand: "McDonald's"` even though the word was never spoken — the brand is part of the food's identity and routes it AI-first with real serving sizes (2026-07-19 integrity fix: brand-less "Big Mac" fell to a per-100g row and logged 234 kcal). Implication must be unmistakable ("a whopper" → Burger King); a generic "burger" stays `null`.
2. **Unstated amounts become `missing_details`, not guesses.** A parse with honest nulls and a candidate question beats a parse with confident fabrications.
3. **Spoken-number normalization is the parser's job.** "four ounces" → `amount: 4, unit: "oz"`. "ninety three seven" / "ninety-three seven" / "93 7" → `fat_ratio: "93/7"`. "two hundred grams" → `amount: 200, unit: "g"`.
4. **Modifier math is fixed:** "double" → `amount: 2`, "triple" → `3`, "light"/"easy on the" → `0.5`, "extra" → `1.5`, "half" → `0.5` — always in units of the food's standard serving (`unit: null`). The parser records the multiplier; the nutrition resolver owns what a standard serving weighs (dictionary-first, USDA FDC second).
5. **A parse failure is never a capture failure.** The audio and transcript remain intact; reparsing produces a new immutable `parses` record. Corrections are append-only records referencing the parse.
6. **Drinks are extracted too — water especially.** Plain water is an item named exactly `water` (every container form — "a glass of water", "bottle of water", "sparkling water" — normalizes to `water`), with the stated amount+unit or `amount: null, unit: null` for an unmodified serving. The parser must never drop water as "not food": a water-only transcript ("just a big glass of water") returns that one `water` item, never an empty list (an empty parse is a `ParseError`). The client routes `water` items to the hydration tally (`POST /meals/water`, oz) and out of the meal_log — so water never adds calories but always feeds the Today water pillar. Caloric drinks (juice, soda, milk, sports drinks) are their own items by name and stay in the meal; only zero-calorie plain water is hydration.

## Input

A meal transcript: one string, the verbatim transcription of a single voice capture.

```json
{ "transcript": "4oz 93/7 beef and 200g cooked jasmine rice" }
```

## Output

```json
{
  "meal_type": "breakfast | lunch | dinner | snack | unspecified",
  "items": [
    {
      "name": "string — canonical food name, normalized from speech",
      "amount": "number | null — null when unstated",
      "unit": "g | oz | lb | cup | tbsp | tsp | piece | slice | scoop | ml | null — null with a non-null amount means standard servings",
      "state": "raw | cooked | unspecified",
      "fat_ratio": "string | null — lean/fat as spoken, e.g. \"93/7\", \"80/20\"",
      "brand": "string | null — resolution context and audit only; no restaurant DB lookup",
      "prep_method": "string | null — e.g. \"grilled\", \"fried in butter\"",
      "confidence": "number 0..1 — parser's confidence this item is what the user said",
      "variant": "string | null — chosen variant key (e.g. \"fat_free\") once a clarify answer picks one; the ENGINE fills this, the LLM always omits it"
    }
  ],
  "missing_details": [
    {
      "field": "string — JSON path of the unknown, e.g. \"items[0].state\"",
      "importance": "high | medium | low",
      "question": "string — a single user-facing question that would resolve it",
      "options": "string[] | optional — quick-answer chips for the UI (variant keys, size presets)"
    }
  ]
}
```

Notes:

- `meal_type` is `unspecified` unless the user says it ("logging lunch…"). Time-of-day inference happens downstream, never in the parser.
- `missing_details` is a list of **candidates**. The parser proposes; the deterministic question engine disposes (see below). Importance is the parser's prior on macro impact, not a promise that a question will fire.
- Unknown fields added by the server must be tolerated by clients (Codable unknown-field tolerance is part of the contract).

## Full example

Transcript: `"4oz 93/7 beef and 200g cooked jasmine rice"`

```json
{
  "meal_type": "unspecified",
  "items": [
    {
      "name": "ground beef",
      "amount": 4,
      "unit": "oz",
      "state": "unspecified",
      "fat_ratio": "93/7",
      "brand": null,
      "prep_method": null,
      "confidence": 0.96
    },
    {
      "name": "jasmine rice",
      "amount": 200,
      "unit": "g",
      "state": "cooked",
      "fat_ratio": null,
      "brand": null,
      "prep_method": null,
      "confidence": 0.97
    }
  ],
  "missing_details": [
    {
      "field": "items[0].state",
      "importance": "medium",
      "question": "Was the 4oz of beef weighed raw or cooked?"
    }
  ]
}
```

The user said "cooked" for the rice, so its state is known. They did not say it for the beef, so the parser records `unspecified` plus a candidate question — it does not assume.

## Resolution identity (server output, additive)

Every item in a `/parse` and `/parse/refine` response carries, besides its `grams`,
`macros`, `source` and `match_score`, two additive optional fields:

- `identity` — WHAT food was priced, independent of how much: a per-100 g profile, its
  portion data (serving grams, per-unit weights), basis state, provenance (`source`,
  `match_kind`, `match_score`), variant axis, estimate flag and web sources, plus a stable
  `key` (`dictionary:apple`, `fdc:169601`, `est:…`). `null` for unresolved items and for
  composed-meal groupings.
- `priced_as` — what the resolver actually priced when it is not literally what was said:
  the curated head of a suffix or alias match (`"apple"` for "cosmic crisp apple") or a USDA
  row description. Clients show it so a wrong identity is visible before logging.

The rule these fields enforce (2026-09-23): **identity never depends on the amount.** The
resolver identifies a food from its name, brand, variant, fat ratio and prep method only,
persists the identity with the parse, and `/parse/refine` plus meals confirm re-PRICE that
identity for amount, unit and state answers. Only name, brand, variant and fat-ratio answers
re-identify. Clients never author an identity: one sent on a confirmed item is ignored and
the server stamps its own from the parse row.

## Personal foods (server output, additive)

A person can declare a food no database has: from its label (`POST /foods/personal`, per
serving as printed, calories computed with the Atwater factors 4, 4, 9 only when the label's
figure is not given) or from a batch they cooked (`POST /foods/personal/batch`: the confirmed
items of a parse, re-resolved by the confirm engine, summed, divided by the servings it
makes; the serving weight follows). From then on the resolver consults the person's own foods
BEFORE the dictionary, the estimator and USDA: if you named it, you meant it. "My chili
recipe", "a serving of chili" and "chili" are one key; aliases add more. Such an item carries
`source: "manual"` (the contract's word for declared numbers), `is_estimate: false`, a
persisted identity keyed `personal:<id>`, and the additive `personal_food_id`. A weight prices
through the serving weight when the food has one; a serving whose weight is unknown is
carried as 100 g internally and prices by servings only.

## The clarifying-question rule (single source of truth)

This is the only place this rule is defined. The engine implements it; no prompt, screen, or doc may restate it with different numbers.

- A question **fires only when the missing detail could shift the meal by more than 75 kcal or more than 10 g of any macro** (protein, carbs, or fat), as computed deterministically by the nutrition engine across the plausible range of the unknown.
- **Per-material-ingredient questions (decision #29).** Every ingredient whose unknown clears the threshold gets its own question, ordered highest-impact first and capped (≤4); a fully specified meal asks nothing. (This supersedes the original one-question-per-meal rule — the engine ships multi-question; see `parser/clarify.py` and `test_parse_api.py::test_burger_fires_per_ingredient_checks`.)
- The question is **skippable**. Skipping logs the meal with the engine's documented default for that unknown and the confidence discounted accordingly. A skipped question never blocks logging.
- Questions must be **answerable**: ask only what the user can plausibly know ("raw or cooked?", "what fat ratio?"). Never ask for restaurant gram weights the user cannot know — inherent serving variance is priced into confidence instead.

## Refine answers (`POST /parse/refine`)

Each answer names a field (`items[N].amount`, `.unit`, `.state`, `.fat_ratio`, `.name`,
`.variant`, or `items[N].removed`) and carries a value. The amount answer's grammar is
`"<amount> <unit>"`: a positive decimal, optional whitespace, then an optional contract unit
or one of its aliases (`grams`, `ounce`, `cups`); a bare number keeps the amount unit-less.
One address per side: the app composes it through `RefineAmountAnswer` (`Sources/VoCalCore`)
and the server parses it with `clarify._AMOUNT_ANSWER_RE`; each side's test carries the
same table, so the two cannot drift apart unnoticed.

## Composed-meal grammar (the container/component pass)

Humans name a STRUCTURE and then its CONTENTS: "a sandwich with bread, turkey, ham, and
provolone" is one sandwich made of those things — never a generic sandwich PLUS the
ingredients. The parser emits the container as one item and each component as its own item
(rule 1 as before); the deterministic composition pass (`parser/compose.py`, applied on
`/parse`, `/parse/refine`, AND the meals-confirm re-resolution) then decides:

- Container + ≥2 component-shaped items (or ≥1 with an explicit amount) → the container is
  a **zero-calorie display grouping**; the components carry the meal. Ingredient-level
  precision always beats a generic composed-meal estimate; the two are never stacked.
- Container alone ("I had a turkey sandwich") → keeps its generic dictionary calories
  (a vague log is still a successful log; generic containers are non-zero in the seed).
- Container + non-component foods only ("a sandwich and chips") → NOT suppressed; sides
  stay separate items.
- Pizza is exempt: the pizza item itself is the quantified calorie carrier ("2 slices of
  pepperoni pizza" = one item, amount 2, unit slice — never whole pizza plus slices).

Deli-meat context: bare "turkey"/"ham" resolve as SLICED DELI meat (canonical entries);
the ground-meat family — and its fat-ratio question — applies only to "ground X",
patty/burger/meatball/mince phrasing, or a stated ratio. The clarify engine refuses a
fat-ratio candidate for any item that does not itself resolve to the ground family.

## Canonical messy-speech examples

These four are the seed of the binding fixture corpus (decision #22). Expected behavior, not aspiration.

### 1. "4oz 93/7 beef"

- One item: `name: "ground beef"`, `amount: 4`, `unit: "oz"`, `fat_ratio: "93/7"`, `state: "unspecified"`.
- "ninety three seven" in speech normalizes to `"93/7"`.
- Candidate `missing_detail` on raw-vs-cooked weight basis. Whether it fires is the engine's threshold call — fat ratio is already known, so no fat-ratio question.

### 2. "200g cooked jasmine rice"

- One item, fully specified: `amount: 200`, `unit: "g"`, `state: "cooked"`.
- `missing_details: []`. No question. High confidence. This is the lingo tutorial's gold-standard utterance.

### 3. "Chipotle bowl, double chicken, white rice, mild salsa, light cheese"

- **Five items.** The dish container is retained as an item carrying brand context; the enumerated components carry the nutrition:

| # | name | amount | unit | brand | note |
|---|------|--------|------|-------|------|
| 0 | burrito bowl | null | null | Chipotle | container; resolves to zero nutrition itself |
| 1 | chicken | 2 | null | Chipotle | "double" = 2× standard serving |
| 2 | white rice | null | null | Chipotle | unmodified component → 1× standard serving |
| 3 | mild salsa | null | null | Chipotle | |
| 4 | cheese | 0.5 | null | Chipotle | "light" = 0.5× standard serving |

- `brand` is recorded for resolution context and audit; resolution still goes dictionary-first (standard-serving entries for common spoken patterns), never a restaurant database (hard out of scope).
- No question fires: the user already specified relative amounts in the only vocabulary available to them ("double", "light"); exact restaurant grams are unanswerable, so remaining variance is reflected in per-item confidence, not a question.

### 4. "burger, unknown beef, regular cheddar, mayo"

- Items: burger (dish), ground beef patty with **`fat_ratio: null`**, cheddar cheese, mayo (amount null).
- `missing_details` must include a **high-importance** candidate on the beef fat ratio — e.g. `{"field": "items[1].fat_ratio", "importance": "high", "question": "What was the fat ratio of the beef, like 80/20 or 93/7?"}` — because 70/30 vs 93/7 shifts fat well past 10 g.
- Mayo amount is a second candidate (medium). Per-material-ingredient questions (decision #29, §3 above): BOTH candidates ship, ordered beef first (highest macro impact) — the old one-question rule that dropped the mayo candidate is superseded.
- The parser does not invent a fat ratio because the user explicitly said "unknown".

## Versioning

Every `parses` row records `model` and `prompt_version`. Contract changes are additive where possible; breaking changes bump the contract version here and in `VoCalCore` simultaneously, and the fixture corpus must be re-scored before merge.
