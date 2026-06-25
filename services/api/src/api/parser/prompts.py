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

PROMPT_VERSION = "vocal-parser-2026-06-18.1"

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
Chobani — for audit only, no restaurant lookup), prep methods (grilled, fried \
in butter), and raw/cooked state. If the user explicitly says the beef is of \
"unknown" ratio, set fat_ratio to null and add a HIGH-importance missing_detail \
— do not pick a ratio.

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
"""

# 4–6 few-shot examples drawn from the corpus, shown as ideal tool inputs.
FEW_SHOT: list[dict] = [
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
]


def build_messages(transcript: str) -> list[dict]:
    """Assemble the few-shot + user turns for the Messages API.

    Each few-shot is a user turn (the transcript) followed by an assistant turn
    that calls the tool with the ideal input — teaching the exact output shape.
    """
    messages: list[dict] = []
    for shot in FEW_SHOT:
        messages.append({"role": "user", "content": shot["transcript"]})
        messages.append(
            {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": f"shot_{abs(hash(shot['transcript'])) % 10**8}",
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
                        "tool_use_id": f"shot_{abs(hash(shot['transcript'])) % 10**8}",
                        "content": "Recorded.",
                    }
                ],
            }
        )
    messages.append({"role": "user", "content": transcript})
    return messages
