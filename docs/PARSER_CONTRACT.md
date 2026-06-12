# Parser Contract

Canonical JSON contract between the transcript and everything downstream. `Sources/VoCalCore` types, the FastAPI parser schemas, and the fixture corpus (`scripts/parser-eval`) all mirror this file exactly. If they disagree, this file wins; fix the code.

Authored fresh for Vo-Cal (no Serein/Beacon source). Frozen decisions #9, #10, #11, #12 govern this contract.

## Principles

1. **The LLM extracts structure. It never invents numbers.** Amounts, units, ratios, and brands come from the transcript or they are `null`. All macro math, unit conversion, and threshold logic is deterministic, tested Python downstream of the parse.
2. **Unstated amounts become `missing_details`, not guesses.** A parse with honest nulls and a candidate question beats a parse with confident fabrications.
3. **Spoken-number normalization is the parser's job.** "four ounces" → `amount: 4, unit: "oz"`. "ninety three seven" / "ninety-three seven" / "93 7" → `fat_ratio: "93/7"`. "two hundred grams" → `amount: 200, unit: "g"`.
4. **Modifier math is fixed:** "double" → `amount: 2`, "triple" → `3`, "light"/"easy on the" → `0.5`, "extra" → `1.5`, "half" → `0.5` — always in units of the food's standard serving (`unit: null`). The parser records the multiplier; the nutrition resolver owns what a standard serving weighs (dictionary-first, USDA FDC second).
5. **A parse failure is never a capture failure.** The audio and transcript remain intact; reparsing produces a new immutable `parses` record. Corrections are append-only records referencing the parse.

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
      "confidence": "number 0..1 — parser's confidence this item is what the user said"
    }
  ],
  "missing_details": [
    {
      "field": "string — JSON path of the unknown, e.g. \"items[0].state\"",
      "importance": "high | medium | low",
      "question": "string — a single user-facing question that would resolve it"
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

## The clarifying-question rule (single source of truth)

This is the only place this rule is defined. The engine implements it; no prompt, screen, or doc may restate it with different numbers.

- A question **fires only when the missing detail could shift the meal by more than 75 kcal or more than 10 g of any macro** (protein, carbs, or fat), as computed deterministically by the nutrition engine across the plausible range of the unknown.
- **At most ONE question per meal.** When multiple candidates clear the threshold, the one with the highest macro impact wins. The rest are dropped silently.
- The question is **skippable**. Skipping logs the meal with the engine's documented default for that unknown and the confidence discounted accordingly. A skipped question never blocks logging.
- Questions must be **answerable**: ask only what the user can plausibly know ("raw or cooked?", "what fat ratio?"). Never ask for restaurant gram weights the user cannot know — inherent serving variance is priced into confidence instead.

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
- `missing_details` must include a **high-importance** candidate on the beef fat ratio — e.g. `{"field": "items[1].fat_ratio", "importance": "high", "question": "What was the fat ratio of the beef — like 80/20 or 93/7?"}` — because 70/30 vs 93/7 shifts fat well past 10 g.
- Mayo amount is a second candidate (medium). The one-question rule selects the beef question (highest macro impact); the mayo candidate is dropped, its uncertainty priced into confidence.
- The parser does not invent a fat ratio because the user explicitly said "unknown".

## Versioning

Every `parses` row records `model` and `prompt_version`. Contract changes are additive where possible; breaking changes bump the contract version here and in `VoCalCore` simultaneously, and the fixture corpus must be re-scored before merge.
