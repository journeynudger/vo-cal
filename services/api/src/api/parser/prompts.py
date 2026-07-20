"""Parser prompt + tool schema, versioned.

``PROMPT_VERSION`` is stored on every ``parses`` row (docs/PARSER_CONTRACT.md
versioning + AGENTS.md raw-capture immutability). Bump it whenever the system
prompt, tool schema, or few-shot set changes, so a re-parse is attributable to
the exact instructions that produced it.

The tool schema mirrors ``parser/schemas.py`` / ``docs/PARSER_CONTRACT.md``. The
LLM is forced to call ``record_parsed_meal`` (tool_choice), so its only output
path is structured JSON validated against the Pydantic contract downstream.

The LLM extracts structure; it never invents numbers (AGENTS.md #6). The system
prompt is explicit: amounts/units/ratios come from the transcript or they are
null + a missing_details candidate.
"""

from __future__ import annotations

PROMPT_VERSION = "vocal-parser-2026-07-19.5"

TOOL_NAME = "record_parsed_meal"

# JSON Schema for the forced tool. Kept in lockstep with parser/schemas.py.
TOOL_SCHEMA: dict = {
    "name": TOOL_NAME,
    "description": (
        "Record the structured items extracted from a meal transcript. "
        "Call this exactly once with everything you parsed."
    ),
    "input_schema": {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "meal_type": {
                "type": "string",
                "enum": ["breakfast", "lunch", "dinner", "snack", "unspecified"],
                "description": "Only set if the user names the meal; otherwise 'unspecified'.",
            },
            "items": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "name": {
                            "type": "string",
                            "description": "Canonical food name, normalized from speech.",
                        },
                        "amount": {
                            "type": ["number", "null"],
                            "description": "Stated quantity, or null if unstated. Never guess.",
                        },
                        "unit": {
                            "type": ["string", "null"],
                            "enum": [
                                "g",
                                "oz",
                                "lb",
                                "cup",
                                "tbsp",
                                "tsp",
                                "piece",
                                "slice",
                                "scoop",
                                "ml",
                                None,
                            ],
                            "description": (
                                "Stated unit. null with a non-null amount means standard "
                                "servings (used for modifiers like 'double'=2, 'light'=0.5)."
                            ),
                        },
                        "state": {
                            "type": "string",
                            "enum": ["raw", "cooked", "unspecified"],
                        },
                        "fat_ratio": {
                            "type": ["string", "null"],
                            "description": 'Lean/fat as spoken, e.g. "93/7". null if unstated.',
                        },
                        "brand": {"type": ["string", "null"]},
                        "prep_method": {"type": ["string", "null"]},
                        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                    },
                    "required": ["name", "confidence"],
                },
            },
            "missing_details": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "field": {
                            "type": "string",
                            "description": 'JSON path of the unknown, e.g. "items[0].fat_ratio".',
                        },
                        "importance": {"type": "string", "enum": ["high", "medium", "low"]},
                        "question": {"type": "string"},
                        # The few-shots teach emitting options (quick-answer chips) and
                        # MissingDetail carries it; with additionalProperties:False, omitting
                        # it here rejects any reply that follows the examples and burns a
                        # schema-retry round-trip.
                        "options": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Quick-answer chips for the UI, e.g. size presets.",
                        },
                    },
                    "required": ["field", "importance", "question"],
                },
            },
        },
        "required": ["meal_type", "items", "missing_details"],
    },
}

SYSTEM_PROMPT = """\
You are Vo-Cal's meal parser. You turn a verbatim voice transcript of what \
someone ate into structured food items. You extract structure ONLY; you never \
invent or estimate calorie or macro numbers — deterministic code downstream \
owns all nutrition math.

Call the record_parsed_meal tool exactly once. Follow these rules:

1. EVERY ingredient is its own item. "burger with cheddar and mayo" → three \
items: the burger (a container/dish), cheddar cheese, mayonnaise. A named dish \
that is a container (e.g. "Chipotle bowl", "burger", "sandwich") is kept as its \
own item carrying brand context; its enumerated components are separate items.

2. NEVER guess an unstated amount. If the user did not say how much, set \
amount to null and add a missing_details candidate. A parse with honest nulls \
beats a parse with confident fabrications.

3. Capture what was said: fat ratios ("93/7", "80/20"), brands (Chipotle, \
Chobani), prep methods (grilled, fried in butter), and raw/cooked state. The \
brand field steers nutrition resolution to the right label, so also FILL IN the \
brand a menu item unmistakably implies even when unspoken: "Big Mac" → brand \
"McDonald's", "Whopper" → "Burger King", "Crunchwrap" → "Taco Bell". Keep the \
spoken name as the item name; never swap it for a generic. If the user \
explicitly says the beef is of "unknown" ratio, set fat_ratio to null and add a \
HIGH-importance missing_detail — do not pick a ratio.

4. Normalize spoken numbers and units:
   - "four ounces" → amount 4, unit "oz"; "two hundred grams" → 200, "g".
   - "ninety three seven" / "ninety-three seven" / "93 7" → fat_ratio "93/7".
   - "quarter pound" → 0.25 lb; "half a bagel" → amount 0.5, unit null.

5. Serving modifiers (relative amounts) use unit null and these multipliers:
   "double"→2, "triple"→3, "extra"→1.5, "light"/"easy on the"→0.5, "half"→0.5. \
A bare unmodified component → amount null, unit null (one standard serving).
   Note: "double scoop" keeps the explicit unit ("scoop", amount 2); the \
multiplier convention is only for components with no stated unit.

6. Strip filler ("um", "like", "uh", "I think", "honestly"). Set meal_type \
only when the user names the meal ("logging lunch", "for breakfast"); otherwise \
"unspecified". Do not infer meal type from time of day.

7. missing_details are CANDIDATES. Propose them with an importance prior on \
macro impact; the deterministic engine decides which (at most one) to ask. \
Always propose a candidate for: an unknown fat ratio on ground meat (HIGH), a \
fully unstated amount on a calorie-dense food (HIGH/MEDIUM), and a raw-vs-cooked \
ambiguity on weighed meat (MEDIUM).

8. confidence (0..1) is how sure you are this item is what the user said — high \
for clearly enunciated foods, lower for mumbled or ambiguous mentions.

9. Drinks count — capture water. Plain water is its own item named EXACTLY "water" \
(any container form — "a glass of water", "bottle of water", "sparkling water" — \
still uses name "water"), with the stated amount+unit or amount null / unit null for \
an unmodified serving (rule 5). Never drop water as "not food": a transcript that is \
only water (e.g. "just a big glass of water") must still return that one water item, \
never an empty list. Caloric drinks (juice, soda, milk, sports drinks, coffee with \
add-ins) are their own items by name too — but they are NOT "water".

10. COMPOSED-MEAL GRAMMAR — humans name a structure, then its contents. "I had a \
sandwich with bread, turkey, ham, and cheese" is ONE sandwich MADE OF those things. \
Emit the container ("sandwich", "wrap", "burrito", "bowl", "salad", "burger", \
"omelet", "smoothie", "quesadilla", "nachos", ...) as ONE item AND each described \
component as its own item — the engine prices the components and treats the container \
as a zero-calorie grouping. Component-introducing phrases: "with", "that had", "made \
with", "on it", "in it", "inside", "topped with", "including", "it was". Separate \
foods joined by a plain "and" after the meal ("a sandwich and chips") are separate \
items, NOT components. Never invent components the user didn't say (no implied \
condiments); a bare "turkey sandwich" with nothing listed stays ONE item (the engine \
prices the generic). PIZZA is different: the pizza itself carries the calories — "two \
slices of pepperoni pizza" is ONE item (name "pepperoni pizza", amount 2, unit \
"slice"), never a whole pizza plus slices; "a whole pizza and two extra slices" is \
the rare explicit additive case (two items).

11. DELI-MEAT CONTEXT — in a sandwich/wrap/sub/deli/cold-cut context, bare meat words \
mean SLICED DELI MEAT: "turkey" -> name "turkey" (deli; the engine resolves it to \
turkey breast), "ham" -> deli ham, "roast beef" -> deli roast beef. NEVER propose a \
fat_ratio missing_detail for deli meat. Ground-meat treatment (and the fat-ratio \
candidate of rule 7) applies ONLY when the user says "ground X", "X burger/patty/\
meatball/taco meat/mince", or states a ratio ("93/7 turkey").

12. INTEGRAL DESCRIPTORS fold into the NAME — they are what the food IS, not an \
added component. "a cookie with chocolate chips" -> ONE item "chocolate chip cookie"; \
"a bagel with everything seasoning" -> "everything bagel"; "yogurt with vanilla" -> \
"vanilla yogurt"; "chicken seasoned with herbs" -> "chicken" (prep_method "herb \
seasoned"). Only split a mention into its own item when it is a real ADDED portion of \
food: "oatmeal with chocolate chips" (chips added ON the oatmeal) is two items; \
"chocolate chip cookie" is one. When unsure, ask: would the ingredient list on a \
package name it ("chocolate chip cookie") or would you scoop it on separately?

13. BRANDED/PACKAGED PRODUCTS — preserve the product's identity; do NOT canonicalize \
it away. Put the brand in `brand` and keep every distinguishing label descriptor the \
user spoke (flavor, "light"/"reduced fat"/"zero added sugar", protein grams, product \
form like "drink"/"bar"/"cup") in the item NAME: "Chobani 30 grams of protein zero \
added sugar vanilla yogurt drink" -> name "30g protein zero added sugar vanilla \
yogurt drink", brand "Chobani" — NEVER just name "yogurt" (the engine prices branded \
items from this exact description; stripping it priced users' labeled products as \
wrong generics). One labeled product is ONE item — never split its flavor or protein \
content into separate items. Normalize misheard brand phonetics from speech: "baby \
bell" -> "Babybel", "chobani"/"chibani" -> "Chobani", "fair life" -> "Fairlife", \
"oh wee kos"/"oil coast"/"oy kos" -> "Oikos", "core power" -> "Core Power", "quest" -> "Quest". Do not \
propose missing_details for a labeled product the user described — the label IS the \
answer.
"""

# 4–6 few-shot examples drawn from the corpus, shown as ideal tool inputs.
FEW_SHOT: list[dict] = [
    {
        # Branded/packaged fidelity (rule 13): the label descriptors stay in the name, the
        # brand rides in `brand`, phonetic spellings normalize, and NO missing_details —
        # the user read the label; the engine prices it from this exact description.
        "transcript": (
            "I had my Chobani 30 grams of protein zero added sugar vanilla yogurt drink "
            "and two light baby bell cheeses"
        ),
        "tool_input": {
            "meal_type": "unspecified",
            "items": [
                {"name": "30g protein zero added sugar vanilla yogurt drink", "amount": None,
                 "unit": None, "state": "unspecified", "fat_ratio": None, "brand": "Chobani",
                 "prep_method": None, "confidence": 0.96},
                {"name": "light cheese", "amount": 2, "unit": "piece", "state": "unspecified",
                 "fat_ratio": None, "brand": "Babybel", "prep_method": None, "confidence": 0.95},
            ],
            "missing_details": [],
        },
    },
    {
        # Restaurant menu items (rule 3): the implied brand is filled in even though the
        # user never says "McDonald's" — it steers resolution to the real menu nutrition
        # (field bug 2026-07-19: brand-less "Big Mac" priced as 100 g of a generic per-100g
        # row → 234 kcal). The menu item itself is self-defining (one sandwich), so no
        # amount candidate for it; the drink's SIZE is genuinely unstated and material.
        "transcript": "I had a Big Mac and a Sprite",
        "tool_input": {
            "meal_type": "unspecified",
            "items": [
                {"name": "Big Mac", "amount": None, "unit": None, "state": "unspecified",
                 "fat_ratio": None, "brand": "McDonald's", "prep_method": None,
                 "confidence": 0.97},
                {"name": "Sprite", "amount": None, "unit": None, "state": "unspecified",
                 "fat_ratio": None, "brand": "Sprite", "prep_method": None,
                 "confidence": 0.95},
            ],
            "missing_details": [
                {"field": "items[1].amount", "importance": "medium",
                 "question": "What size Sprite — a can, a bottle, or a medium fountain drink?",
                 "options": ["12 oz can", "20 oz bottle", "Medium (21 oz)", "Large (30 oz)"]},
            ],
        },
    },
    {
        # Composed-meal grammar (rule 10) + deli-meat context (rule 11): container kept as
        # ONE item, components carry the nutrition, NO fat-ratio candidate for deli turkey.
        "transcript": (
            "I had a sandwich with two slices of Healthy Life low-carb bread, "
            "two and a half ounces of turkey, one and a half ounces of Krakus ham, "
            "and two ounces of provolone cheese"
        ),
        "tool_input": {
            "meal_type": "unspecified",
            "items": [
                {"name": "sandwich", "amount": None, "unit": None, "state": "unspecified",
                 "fat_ratio": None, "brand": None, "prep_method": None, "confidence": 0.97},
                {"name": "low carb bread", "amount": 2, "unit": "slice", "state": "unspecified",
                 "fat_ratio": None, "brand": "Healthy Life", "prep_method": None, "confidence": 0.95},
                {"name": "turkey", "amount": 2.5, "unit": "oz", "state": "unspecified",
                 "fat_ratio": None, "brand": None, "prep_method": None, "confidence": 0.95},
                {"name": "ham", "amount": 1.5, "unit": "oz", "state": "unspecified",
                 "fat_ratio": None, "brand": "Krakus", "prep_method": None, "confidence": 0.95},
                {"name": "provolone cheese", "amount": 2, "unit": "oz", "state": "unspecified",
                 "fat_ratio": None, "brand": None, "prep_method": None, "confidence": 0.96},
            ],
            "missing_details": [],
        },
    },
    {
        "transcript": "4oz 93/7 beef and 200g cooked jasmine rice",
        "tool_input": {
            "meal_type": "unspecified",
            "items": [
                {
                    "name": "ground beef",
                    "amount": 4,
                    "unit": "oz",
                    "state": "unspecified",
                    "fat_ratio": "93/7",
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.96,
                },
                {
                    "name": "jasmine rice",
                    "amount": 200,
                    "unit": "g",
                    "state": "cooked",
                    "fat_ratio": None,
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.97,
                },
            ],
            "missing_details": [
                {
                    "field": "items[0].state",
                    "importance": "medium",
                    "question": "Was the 4oz of beef weighed raw or cooked?",
                }
            ],
        },
    },
    {
        "transcript": "Chipotle bowl, double chicken, white rice, mild salsa, light cheese",
        "tool_input": {
            "meal_type": "unspecified",
            "items": [
                {
                    "name": "burrito bowl",
                    "amount": None,
                    "unit": None,
                    "state": "unspecified",
                    "fat_ratio": None,
                    "brand": "Chipotle",
                    "prep_method": None,
                    "confidence": 0.9,
                },
                {
                    "name": "chicken",
                    "amount": 2,
                    "unit": None,
                    "state": "cooked",
                    "fat_ratio": None,
                    "brand": "Chipotle",
                    "prep_method": None,
                    "confidence": 0.92,
                },
                {
                    "name": "white rice",
                    "amount": None,
                    "unit": None,
                    "state": "cooked",
                    "fat_ratio": None,
                    "brand": "Chipotle",
                    "prep_method": None,
                    "confidence": 0.9,
                },
                {
                    "name": "mild salsa",
                    "amount": None,
                    "unit": None,
                    "state": "unspecified",
                    "fat_ratio": None,
                    "brand": "Chipotle",
                    "prep_method": None,
                    "confidence": 0.9,
                },
                {
                    "name": "cheese",
                    "amount": 0.5,
                    "unit": None,
                    "state": "unspecified",
                    "fat_ratio": None,
                    "brand": "Chipotle",
                    "prep_method": None,
                    "confidence": 0.9,
                },
            ],
            "missing_details": [],
        },
    },
    {
        "transcript": "burger, unknown beef, regular cheddar, mayo",
        "tool_input": {
            "meal_type": "unspecified",
            "items": [
                {
                    "name": "burger",
                    "amount": None,
                    "unit": None,
                    "state": "unspecified",
                    "fat_ratio": None,
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.88,
                },
                {
                    "name": "ground beef",
                    "amount": None,
                    "unit": None,
                    "state": "unspecified",
                    "fat_ratio": None,
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.85,
                },
                {
                    "name": "cheddar cheese",
                    "amount": None,
                    "unit": None,
                    "state": "unspecified",
                    "fat_ratio": None,
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.9,
                },
                {
                    "name": "mayonnaise",
                    "amount": None,
                    "unit": None,
                    "state": "unspecified",
                    "fat_ratio": None,
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.9,
                },
            ],
            "missing_details": [
                {
                    "field": "items[1].fat_ratio",
                    "importance": "high",
                    "question": "What was the fat ratio of the beef — like 80/20 or 93/7?",
                },
                {
                    "field": "items[3].amount",
                    "importance": "medium",
                    "question": "About how much mayo — a teaspoon, a tablespoon, or more?",
                },
            ],
        },
    },
    {
        "transcript": "um so I had like two eggs and uh some toast",
        "tool_input": {
            "meal_type": "unspecified",
            "items": [
                {
                    "name": "egg",
                    "amount": 2,
                    "unit": "piece",
                    "state": "cooked",
                    "fat_ratio": None,
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.9,
                },
                {
                    "name": "toast",
                    "amount": None,
                    "unit": None,
                    "state": "unspecified",
                    "fat_ratio": None,
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.82,
                },
            ],
            "missing_details": [
                {
                    "field": "items[1].amount",
                    "importance": "low",
                    "question": "How many slices of toast?",
                }
            ],
        },
    },
    {
        "transcript": "four ounces of ninety three seven ground beef",
        "tool_input": {
            "meal_type": "unspecified",
            "items": [
                {
                    "name": "ground beef",
                    "amount": 4,
                    "unit": "oz",
                    "state": "unspecified",
                    "fat_ratio": "93/7",
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.95,
                },
            ],
            "missing_details": [
                {
                    "field": "items[0].state",
                    "importance": "medium",
                    "question": "Was the beef weighed raw or cooked?",
                }
            ],
        },
    },
    {
        "transcript": "grilled chicken breast and a glass of water",
        "tool_input": {
            "meal_type": "unspecified",
            "items": [
                {
                    "name": "chicken breast",
                    "amount": None,
                    "unit": None,
                    "state": "cooked",
                    "fat_ratio": None,
                    "brand": None,
                    "prep_method": "grilled",
                    "confidence": 0.93,
                },
                {
                    "name": "water",
                    "amount": None,
                    "unit": None,
                    "state": "unspecified",
                    "fat_ratio": None,
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.97,
                },
            ],
            "missing_details": [],
        },
    },
    {
        "transcript": "just a big glass of water",
        "tool_input": {
            "meal_type": "unspecified",
            "items": [
                {
                    "name": "water",
                    "amount": None,
                    "unit": None,
                    "state": "unspecified",
                    "fat_ratio": None,
                    "brand": None,
                    "prep_method": None,
                    "confidence": 0.97,
                },
            ],
            "missing_details": [],
        },
    },
]


def build_messages(transcript: str) -> list[dict]:
    """Assemble the few-shot + user turns for the Messages API.

    Each few-shot is a user turn (the transcript) followed by an assistant turn
    that calls the tool with the ideal input — teaching the exact output shape.
    """
    messages: list[dict] = []
    # Shot ids use the loop index, not hash(): str hashes are salted per process
    # (PYTHONHASHSEED), so hash-based ids made the assembled prompt differ across
    # processes/restarts — needless cache-key churn for a value that only has to be
    # unique per shot and matched between tool_use and tool_result.
    for i, shot in enumerate(FEW_SHOT):
        messages.append({"role": "user", "content": shot["transcript"]})
        messages.append(
            {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": f"shot_{i}",
                        "name": TOOL_NAME,
                        "input": shot["tool_input"],
                    }
                ],
            }
        )
        messages.append(
            {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": f"shot_{i}",
                        "content": "Recorded.",
                    }
                ],
            }
        )
    messages.append({"role": "user", "content": transcript})
    return messages
