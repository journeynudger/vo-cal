"""Certainty score — the confidence-aware logging layer (deterministic, AGENTS.md #6).

"We logged what you said, estimated what we could, and here is how confident we are."
Log first. Score second. Coach third. A vague log is still a successful log — this module
NEVER blocks anything: it runs after a successful parse and only annotates it.

The score (0-100) blends two independent qualities:

  1. DETAIL  — how much useful information the user gave (portions, sauces, brands,
     prep, hedging). This is what the user can improve, so it dominates (60%).
  2. RESOLUTION — how well the deterministic engine priced what they said (the existing
     ``meal_confidence`` blend). An unresolved side dish honestly drags this down (40%).

Blending matters: "pasta with marinara" must score HIGHER than "pasta" even when our
dictionary prices marinara imperfectly — the user did their part, and the score is the
lever that teaches them to keep doing it (the 37% -> 61% moment). Category caps then
keep known-treacherous meals (coffee without size/milk, "dinner" alone) honest.

Copy rules (the spec's banned list): never "poor", "bad", "invalid", "failed",
"insufficient", "incomplete". The score is a transparency layer, not a grade — and
never a healthiness judgment.

The clarify engine still owns MATERIAL questions (>75 kcal / 10 g, decision #29).
This layer coaches on everything else, non-blocking, max 3 tips, category-aware.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING

from pydantic import BaseModel

from ..nutrition.schemas import ResolutionSource

if TYPE_CHECKING:  # runtime import would cycle: schemas -> certainty -> resolver -> schemas
    from ..nutrition.resolver import ResolvedItem

# ---------------------------------------------------------------------------
# Response block (additive on ParseResult; shipped clients tolerate unknown fields)
# ---------------------------------------------------------------------------


class Certainty(BaseModel):
    """The certainty annotation for one parsed/logged meal."""

    score: int  # 0-100; never 100 (an estimate is never a measurement)
    label: str  # rough_estimate | limited_detail | good_estimate | high_confidence
    display_label: str  # calm human copy for the label
    category: str  # primary MealCategory value
    missing_details: list[str] = []  # controlled MissingDetail vocabulary
    assumptions: list[str] = []  # what the estimate is based on (honest, not defensive)
    tips: list[str] = []  # max 3, highest-impact first, category-aware
    should_show_coaching: bool = False


# Label thresholds + calm display copy (spec ranges).
_LABELS: list[tuple[int, str, str]] = [
    (85, "high_confidence", "High confidence"),
    (70, "good_estimate", "Good estimate"),
    (50, "limited_detail", "Limited detail"),
    (0, "rough_estimate", "Rough estimate"),
]

# ---------------------------------------------------------------------------
# Internal projection — buildable from a live ResolvedItem OR a stored meal_logs
# item dict, so the weekly summary can re-score history with no migration.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CertaintyItem:
    name: str
    amount: float | None
    unit: str | None  # contract unit value ("g", "cup", ...) or None
    brand: str | None
    prep_method: str | None
    is_estimate: bool
    unresolved: bool
    kcal: float


def item_from_resolved(resolved: ResolvedItem) -> CertaintyItem:
    item = resolved.item
    return CertaintyItem(
        name=item.name,
        amount=item.amount,
        unit=item.unit.value if item.unit else None,
        brand=item.brand,
        prep_method=item.prep_method,
        is_estimate=resolved.is_estimate,
        unresolved=resolved.source is ResolutionSource.UNRESOLVED,
        kcal=resolved.macros.kcal,
    )


def item_from_stored(row: dict) -> CertaintyItem:
    """Adapter for a stored meal_logs item (ConfirmedItem shape) — weekly re-scoring."""
    macros = row.get("macros") or {}
    return CertaintyItem(
        name=str(row.get("name") or ""),
        amount=row.get("amount"),
        unit=row.get("unit"),
        brand=row.get("brand"),
        prep_method=row.get("prep_method"),
        is_estimate=bool(row.get("is_estimate")),
        unresolved=(row.get("source") == "unresolved"),
        kcal=float(macros.get("kcal") or 0.0),
    )


# ---------------------------------------------------------------------------
# Category detection — ordered keyword table (data, not a rule engine).
# First matching bucket wins per item; the meal's primary category is the
# highest-priority category any item hit (specific dishes outrank staples).
# ---------------------------------------------------------------------------

_CATEGORY_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    # (category, keywords) — ordered most-specific first.
    ("coffee_tea", ("coffee", "latte", "espresso", "cappuccino", "matcha", "cold brew", "tea", "americano", "macchiato", "mocha")),
    ("smoothie_shake", ("smoothie", "shake", "protein shake")),
    ("alcohol", ("beer", "wine", "cocktail", "margarita", "whiskey", "vodka", "seltzer hard", "hard seltzer")),
    ("pizza", ("pizza",)),
    ("taco_burrito_mexican", ("taco", "burrito", "quesadilla", "nachos", "enchilada", "fajita")),
    ("soup_stew_chili", ("soup", "stew", "chili", "broth", "bisque", "chowder")),
    ("sandwich_wrap_burger", ("sandwich", "burger", "wrap", "sub", "hoagie", "blt", "panini", "hot dog", "sliders")),
    ("salad", ("salad", "greens", "slaw")),
    ("pasta_noodles", ("pasta", "spaghetti", "noodle", "ramen", "penne", "lasagna", "mac and cheese", "fettuccine", "linguine", "pad thai", "lo mein", "rigatoni", "orzo", "gnocchi", "ravioli", "tortellini")),
    ("yogurt_parfait", ("yogurt", "parfait", "skyr")),
    ("oatmeal_cereal", ("oatmeal", "cereal", "granola", "overnight oats", "porridge", "muesli")),
    ("eggs", ("egg", "omelet", "omelette", "frittata", "scramble")),
    ("fruit_bowl", ("fruit bowl", "fruit plate", "berries", "watermelon", "cantaloupe", "honeydew", "grapes", "banana", "apple", "orange", "mixed fruit", "grapefruit", "strawberr", "blueberr", "raspberr", "blackberr", "mango", "pineapple", "peach", "melon")),
    ("dessert", ("ice cream", "cake", "cookie", "brownie", "dessert", "frozen yogurt", "donut", "doughnut", "pie", "chocolate", "candy", "pastry", "croissant", "muffin")),
    ("chips_crackers", ("chips", "crackers", "popcorn", "pretzel")),
    ("snack_packaged", ("protein bar", "granola bar", "bar", "snack", "trail mix", "jerky", "rice cake")),
    ("beverage", ("juice", "soda", "milk", "sports drink", "energy drink", "lemonade", "kombucha", "water")),
    ("rice_grain_bowl", ("bowl", "poke", "grain bowl", "fried rice", "burrito bowl")),
    ("vegetarian_vegan", ("tofu", "tempeh", "lentil", "beans", "chickpea", "veggie burger", "seitan", "edamame", "hummus")),
    ("meat_seafood", ("chicken", "beef", "steak", "salmon", "shrimp", "pork", "turkey", "fish", "tuna", "cod", "tilapia", "lamb", "bacon", "sausage", "ham", "ribeye", "sirloin", "mahi", "sardine", "rotisserie")),
    ("condiment_sauce", ("ranch", "ketchup", "mayo", "mustard", "dressing", "sauce", "olive oil", "butter", "peanut butter", "syrup", "honey", "salsa", "guacamole", "hummus", "cream cheese", "sriracha")),
    ("breakfast_plate", ("breakfast", "pancake", "waffle", "french toast", "hash brown", "bagel", "toast", "english muffin")),
    ("generic_meal", ("dinner", "lunch", "meal", "food", "snacked", "something")),
]

# Priority when a meal spans several buckets: the DISH identity beats its components
# (a "burrito bowl with chicken and rice" is a bowl, not meat_seafood).
_CATEGORY_PRIORITY: list[str] = [
    "pizza", "taco_burrito_mexican", "soup_stew_chili", "sandwich_wrap_burger", "salad",
    "pasta_noodles", "smoothie_shake", "rice_grain_bowl", "yogurt_parfait", "oatmeal_cereal",
    "breakfast_plate", "eggs", "fruit_bowl", "dessert", "chips_crackers", "snack_packaged",
    "coffee_tea", "alcohol", "beverage", "protein_with_sides", "meat_seafood",
    "vegetarian_vegan", "condiment_sauce", "generic_meal", "unknown",
]
_PRIORITY_RANK = {c: i for i, c in enumerate(_CATEGORY_PRIORITY)}


# Bare grains are a WEAK signal: "chicken with rice and broccoli" is a protein plate,
# not a grain bowl — but "I had rice" alone still reads as one. Dish words ("bowl",
# "poke", "fried rice") stay strong in the main table above.
_WEAK_GRAIN_WORDS = ("rice", "quinoa", "couscous", "grits", "farro", "barley")


def _category_for_text(text: str) -> str | None:
    t = text.lower()
    for category, keywords in _CATEGORY_KEYWORDS:
        if any(k in t for k in keywords):
            return category
    return None


def detect_category(items: list[CertaintyItem], transcript: str) -> str:
    hits: set[str] = set()
    weak_grain = False
    for item in items:
        cat = _category_for_text(item.name)
        if cat:
            hits.add(cat)
        elif any(w in item.name.lower() for w in _WEAK_GRAIN_WORDS):
            weak_grain = True
    if not hits and not weak_grain:
        cat = _category_for_text(transcript)
        if cat:
            hits.add(cat)
        elif any(w in transcript.lower() for w in _WEAK_GRAIN_WORDS):
            weak_grain = True
    # Protein + sides framing beats a bare grain; a bare grain alone is still a grain meal.
    if {"meat_seafood", "vegetarian_vegan"} & hits and len(items) >= 2:
        dishy = {
            c for c in hits
            if _PRIORITY_RANK.get(c, 99) <= _PRIORITY_RANK["oatmeal_cereal"]
        }
        if not dishy:
            return "protein_with_sides"
    if not hits:
        return "rice_grain_bowl" if weak_grain else "unknown"
    return min(hits, key=lambda c: _PRIORITY_RANK.get(c, 99))


# ---------------------------------------------------------------------------
# Transcript signals — hedging + negation (deterministic keyword scans).
# ---------------------------------------------------------------------------

_STRONG_HEDGES = ("i think", "maybe", "not sure", "i guess", "probably", "no idea")
_SOFT_HEDGES = ("about", "some ", "roughly", "kind of", "a bit of", "around")


def _hedging_penalty(transcript: str) -> int:
    t = f" {transcript.lower()} "
    if any(h in t for h in _STRONG_HEDGES):
        return 8
    if any(h in t for h in _SOFT_HEDGES):
        return 4
    return 0


# Negations suppress coaching on the excluded thing: never ask about what the user
# explicitly ruled out ("no cheese", "black coffee", "unsweetened").
_NEGATION_TARGETS: dict[str, tuple[str, ...]] = {
    "cheese_or_toppings": ("cheese", "toppings", "croutons", "granola", "nuts"),
    "sauce_or_dressing": ("sauce", "dressing", "mayo", "ranch"),
    "milk_or_creamer": ("milk", "cream", "creamer"),
    "sweetener_or_syrup": ("sugar", "sweetener", "syrup", "honey"),
    "carb_type": ("bun", "bread", "tortilla"),
}
_NEGATION_RE = re.compile(r"\b(?:no|without|hold the|minus|skip(?:ped)? the)\s+(\w+(?:\s\w+)?)")


def negated_details(transcript: str) -> set[str]:
    t = transcript.lower()
    suppressed: set[str] = set()
    negated_words = " ".join(m.group(1) for m in _NEGATION_RE.finditer(t))
    for detail, words in _NEGATION_TARGETS.items():
        if any(w in negated_words for w in words):
            suppressed.add(detail)
    if "black coffee" in t:
        suppressed.update({"milk_or_creamer", "sweetener_or_syrup"})
    if "unsweetened" in t or "sugar-free" in t or "sugar free" in t:
        suppressed.add("sweetener_or_syrup")
    if "plain" in t or "dry" in t:
        suppressed.add("sauce_or_dressing")
    return suppressed


# ---------------------------------------------------------------------------
# Missing-detail synthesis — per-category playbooks (controlled vocabulary).
# Each rule: (detail_kind, lexicon that satisfies it, tip copy). A detail is
# missing when the category cares about it, nothing the user said satisfies it,
# and the user didn't explicitly negate it.
# ---------------------------------------------------------------------------

_SAUCE_WORDS = ("sauce", "marinara", "alfredo", "pesto", "dressing", "vinaigrette", "ranch", "caesar", "mayo", "salsa", "gravy", "aioli", "bbq", "soy sauce", "sriracha", "ketchup", "mustard")
_CHEESE_TOPPING_WORDS = ("cheese", "parmesan", "cheddar", "mozzarella", "feta", "topping", "crouton", "granola", "nuts", "walnut", "almond", "avocado", "guac", "sour cream", "honey", "seeds", "bacon bits")
_PROTEIN_WORDS = ("chicken", "beef", "turkey", "steak", "salmon", "shrimp", "pork", "tofu", "tempeh", "egg", "tuna", "fish", "ham", "bacon", "sausage", "meatball", "lamb")
_MILK_WORDS = ("milk", "cream", "creamer", "oat milk", "almond milk", "half and half")
_SWEET_WORDS = ("sugar", "sweetener", "syrup", "honey", "vanilla", "caramel", "stevia")
_OIL_WORDS = ("oil", "butter", "olive oil", "avocado oil", "coconut oil")
_METHOD_WORDS = ("grilled", "fried", "baked", "roasted", "steamed", "scrambled", "poached", "boiled", "air fried", "pan", "raw", "seared", "sauteed", "sautéed")

# category -> ordered (detail, satisfied_by_lexicon, tip)
_PLAYBOOK: dict[str, list[tuple[str, tuple[str, ...] | None, str]]] = {
    "pasta_noodles": [
        ("portion_size", None, 'mention portion size — like "two cups" or "a small bowl"'),
        ("sauce_or_dressing", _SAUCE_WORDS, "mention the sauce and roughly how much"),
        ("cheese_or_toppings", _CHEESE_TOPPING_WORDS, "mention cheese or toppings"),
        ("protein_type", _PROTEIN_WORDS, "mention any protein in it"),
    ],
    "rice_grain_bowl": [
        ("bowl_or_plate_size", None, "mention the bowl size or rice amount"),
        ("protein_type", _PROTEIN_WORDS, "mention the protein and roughly how much"),
        ("sauce_or_dressing", _SAUCE_WORDS, "mention sauces or dressings"),
        ("cheese_or_toppings", _CHEESE_TOPPING_WORDS, "mention toppings like cheese, guac, or sour cream"),
    ],
    "salad": [
        ("sauce_or_dressing", _SAUCE_WORDS, "mention the dressing and roughly how much"),
        ("protein_type", _PROTEIN_WORDS, "mention any protein"),
        ("cheese_or_toppings", _CHEESE_TOPPING_WORDS, "mention cheese, nuts, avocado, or croutons"),
        ("portion_size", None, "mention the salad size"),
    ],
    "sandwich_wrap_burger": [
        ("portion_size", None, "mention the size"),
        ("protein_type", _PROTEIN_WORDS, "mention the protein"),
        ("cheese_or_toppings", _CHEESE_TOPPING_WORDS, "mention cheese and toppings"),
        ("sauce_or_dressing", _SAUCE_WORDS, "mention sauces like mayo"),
    ],
    "taco_burrito_mexican": [
        ("serving_count", None, "mention how many"),
        ("protein_type", _PROTEIN_WORDS, "mention the protein"),
        ("cheese_or_toppings", _CHEESE_TOPPING_WORDS, "mention cheese, sour cream, or guac"),
    ],
    "pizza": [
        ("serving_count", None, "mention the number of slices"),
        ("cheese_or_toppings", _CHEESE_TOPPING_WORDS, "mention the toppings"),
        ("brand_or_restaurant", None, "mention if it was homemade, frozen, or from a restaurant"),
    ],
    "soup_stew_chili": [
        ("bowl_or_plate_size", None, "mention the bowl or cup size"),
        ("main_ingredients", None, "mention the soup type — creamy or broth-based"),
    ],
    "eggs": [
        ("serving_count", None, "mention how many eggs"),
        ("cooking_method", _METHOD_WORDS, "mention how they were cooked"),
        ("oil_or_butter", _OIL_WORDS, "mention butter or oil"),
    ],
    "breakfast_plate": [
        ("serving_count", None, "mention counts — eggs, slices, pancakes"),
        ("oil_or_butter", _OIL_WORDS, "mention butter or oil"),
        ("sweetener_or_syrup", _SWEET_WORDS, "mention syrup or sweet toppings"),
    ],
    "oatmeal_cereal": [
        ("portion_size", None, "mention the serving size"),
        ("milk_or_creamer", _MILK_WORDS, "mention the milk type"),
        ("cheese_or_toppings", _CHEESE_TOPPING_WORDS, "mention toppings like fruit, nuts, or nut butter"),
    ],
    "yogurt_parfait": [
        ("portion_size", None, "mention the serving size"),
        ("cheese_or_toppings", _CHEESE_TOPPING_WORDS, "mention granola, fruit, honey, or nuts"),
        ("brand_or_restaurant", None, "mention the brand or type — like plain Greek"),
    ],
    "fruit_bowl": [
        ("bowl_or_plate_size", None, "mention the bowl size or roughly how much of each fruit"),
        ("main_ingredients", None, "mention which fruits were in it"),
        ("cheese_or_toppings", _CHEESE_TOPPING_WORDS, "mention add-ons like yogurt, honey, or granola"),
    ],
    "smoothie_shake": [
        ("drink_size", None, "mention the size"),
        ("main_ingredients", None, "mention what went in it"),
        ("milk_or_creamer", _MILK_WORDS, "mention the milk or juice base"),
    ],
    "coffee_tea": [
        ("drink_size", None, "mention the size"),
        ("milk_or_creamer", _MILK_WORDS, "mention milk or creamer"),
        ("sweetener_or_syrup", _SWEET_WORDS, "mention sweetener or syrup"),
    ],
    "beverage": [
        ("drink_size", None, "mention the size — bottle, can, or glass"),
        ("brand_or_restaurant", None, "mention the brand, or whether it was diet or regular"),
    ],
    "snack_packaged": [
        ("brand_or_restaurant", None, "mention the brand"),
        ("package_size", None, "mention the package size"),
        ("ate_fraction", None, "mention whether you ate all, half, or part of it"),
    ],
    "chips_crackers": [
        ("portion_size", None, "mention roughly how much — a handful, a snack bag"),
        ("brand_or_restaurant", None, "mention the brand or bag size"),
        ("sauce_or_dressing", _SAUCE_WORDS, "mention dips like salsa or guac"),
    ],
    "dessert": [
        ("serving_count", None, "mention pieces, scoops, or slice size"),
        ("cheese_or_toppings", _CHEESE_TOPPING_WORDS, "mention toppings"),
    ],
    "protein_with_sides": [
        ("protein_amount", None, "mention the protein amount — grams or ounces work best"),
        ("cooking_method", _METHOD_WORDS, "mention the cooking method"),
        ("oil_or_butter", _OIL_WORDS, "mention oil or butter"),
        ("portion_size", None, "mention side portions"),
    ],
    "meat_seafood": [
        ("protein_amount", None, "mention the amount — grams or ounces work best"),
        ("cooking_method", _METHOD_WORDS, "mention the cooking method"),
        ("oil_or_butter", _OIL_WORDS, "mention oil or butter"),
    ],
    "vegetarian_vegan": [
        ("protein_amount", None, "mention the amount"),
        ("cooking_method", _METHOD_WORDS, "mention the cooking method"),
        ("oil_or_butter", _OIL_WORDS, "mention oil or sauce it was cooked in"),
    ],
    "condiment_sauce": [
        ("sauce_amount", None, "mention the amount — a tablespoon, a drizzle, a packet"),
    ],
    "alcohol": [
        ("alcohol_amount", None, "mention the count and size"),
        ("sweetener_or_syrup", _SWEET_WORDS, "mention mixers"),
    ],
    "generic_meal": [
        ("unclear_food", None, "mention what you ate and roughly how much"),
        ("main_ingredients", None, "mention the main components"),
    ],
    "unknown": [
        ("unclear_food", None, "mention what the food was and roughly how much"),
    ],
}

# Categories where an unstated amount is priced as "one standard serving" — the single
# most common missing detail, and the weekly summary's usual focus tip.
_PORTION_DETAILS = {"portion_size", "serving_count", "weight_or_volume", "bowl_or_plate_size", "drink_size", "protein_amount", "alcohol_amount", "sauce_amount"}


def _mentions(items: list[CertaintyItem], transcript: str, lexicon: tuple[str, ...]) -> bool:
    blob = (" ".join(i.name for i in items) + " " + transcript).lower()
    return any(w in blob for w in lexicon)


def _satisfied(
    detail: str, lexicon: tuple[str, ...] | None, items: list[CertaintyItem], transcript: str
) -> bool:
    """Did the user already cover this detail? (Missing = category cares AND unsaid AND un-negated.)"""
    if detail in _PORTION_DETAILS:
        return not _all_amounts_inferred(items)
    if detail == "main_ingredients":
        return len(items) >= 2  # components were actually named
    if detail == "brand_or_restaurant":
        return any(i.brand for i in items)
    if detail == "package_size":
        return any(i.amount is not None for i in items)
    if detail == "ate_fraction":
        return any(i.amount is not None for i in items)
    if detail == "unclear_food":
        return not any(i.is_estimate or i.unresolved for i in items) and bool(items)
    if lexicon is not None:
        return _mentions(items, transcript, lexicon)
    return False


def _all_amounts_inferred(items: list[CertaintyItem]) -> bool:
    return all(i.amount is None for i in items) if items else True


def _any_stated_mass_or_volume(items: list[CertaintyItem]) -> bool:
    return any(i.amount is not None and i.unit in ("g", "oz", "lb", "ml", "cup", "tbsp", "tsp") for i in items)


# ---------------------------------------------------------------------------
# The scorer
# ---------------------------------------------------------------------------

# Category caps: (cap, details that must ALL be satisfied/negated to lift it).
_CATEGORY_CAPS: dict[str, tuple[int, tuple[str, ...]]] = {
    "coffee_tea": (69, ("drink_size", "milk_or_creamer")),
    "pasta_noodles": (69, ("portion_size", "sauce_or_dressing")),
    "salad": (69, ("sauce_or_dressing",)),
    "smoothie_shake": (69, ("drink_size", "main_ingredients")),
    "rice_grain_bowl": (74, ("bowl_or_plate_size",)),
    "generic_meal": (45, ()),
    "unknown": (45, ()),
}


def _detail_score(items: list[CertaintyItem], transcript: str, missing: list[str]) -> int:
    """How much useful detail the user gave (the improvable half of the score)."""
    if not items:
        return 30  # "I ate dinner" — recognizable intent, no food identified
    score = 50  # recognizable item(s), vague quantity — the spec's middle baseline
    if _any_stated_mass_or_volume(items):
        score += 20  # weighed/measured — the strongest signal
    elif any(i.amount is not None for i in items):
        score += 10  # counts / serving multipliers
    if len(items) >= 2:
        score += 8  # multiple components clearly named
    if len(items) >= 4:
        score += 4
    if any(i.brand for i in items):
        score += 8
    if any(i.prep_method for i in items):
        score += 5
    if _mentions(items, transcript, _SAUCE_WORDS):
        score += 6
    if _mentions(items, transcript, _OIL_WORDS):
        score += 4
    # Every unaddressed category-relevant detail is a small honest deduction.
    score -= 4 * min(len(missing), 4)
    score -= _hedging_penalty(transcript)
    if any(i.is_estimate or i.unresolved for i in items):
        score -= 6  # we had to guess (or blank) at least one component
    return max(5, min(score, 96))


def build_certainty(
    items: list[CertaintyItem],
    meal_confidence: float,
    transcript: str,
) -> Certainty:
    category = detect_category(items, transcript)
    suppressed = negated_details(transcript)

    # Missing details: category playbook, minus anything said or negated.
    missing: list[str] = []
    tips: list[str] = []
    for detail, lexicon, tip in _PLAYBOOK.get(category, _PLAYBOOK["unknown"]):
        if detail in suppressed:
            continue
        if _satisfied(detail, lexicon, items, transcript):
            continue
        missing.append(detail)
        tips.append(tip)
    if any(i.is_estimate or i.unresolved for i in items) and "unclear_food" not in missing:
        missing.append("unclear_food")

    detail = _detail_score(items, transcript, missing)
    resolution = round(meal_confidence * 100)
    # No identified food → the resolution axis is meaningless; score is pure detail
    # (a vague-but-successful log sits ~30, per the spec's "I ate dinner" band).
    score = detail if not items else round(0.6 * detail + 0.4 * resolution)

    # Category caps: known-treacherous meals stay honest until essentials are covered.
    cap_entry = _CATEGORY_CAPS.get(category)
    if cap_entry:
        cap, essentials = cap_entry
        if not essentials or any(d in missing for d in essentials):
            score = min(score, cap)
    score = max(5, min(score, 99))  # never 0 (we logged something), never 100 (honesty)

    label, display = next((lbl, disp) for floor, lbl, disp in _LABELS if score >= floor)

    assumptions = _assumptions(items, missing)
    tips = tips[:3]
    should_coach = score < 75 and bool(tips)

    return Certainty(
        score=score,
        label=label,
        display_label=display,
        category=category,
        missing_details=missing,
        assumptions=assumptions,
        tips=tips,
        should_show_coaching=should_coach,
    )


def _assumptions(items: list[CertaintyItem], missing: list[str]) -> list[str]:
    out: list[str] = []
    if items and _all_amounts_inferred(items):
        out.append("Estimated from standard serving sizes.")
    unpriced = [i.name for i in items if i.unresolved]
    if unpriced:
        out.append(f"{unpriced[0].title()} isn't priced yet, so it isn't counted — tap it to fix.")
    guessed = [i.name for i in items if i.is_estimate]
    if guessed:
        out.append(f"{guessed[0].title()} is a best-guess estimate — tap to correct it.")
    said_nothing_about = [d for d in missing if d in ("sauce_or_dressing", "cheese_or_toppings", "milk_or_creamer", "sweetener_or_syrup")]
    if said_nothing_about:
        out.append("Only what you mentioned is counted — nothing was assumed.")
    return out[:2]


# ---------------------------------------------------------------------------
# Weekly aggregation helper (used by GET /meals/summary; no DB migration —
# stored meal items are re-scored deterministically).
# ---------------------------------------------------------------------------


def weekly_focus(details_per_meal: list[list[str]]) -> tuple[str | None, str | None]:
    """The most common missing detail across a week + its example-phrase focus tip."""
    counts: dict[str, int] = {}
    for details in details_per_meal:
        for d in details:
            counts[d] = counts.get(d, 0) + 1
    if not counts:
        return None, None
    top = max(counts, key=lambda k: (counts[k], k in _PORTION_DETAILS))
    tip = _FOCUS_TIPS.get(top, "Next week, add one more detail when you log — it sharpens every estimate.")
    return top, tip


_FOCUS_TIPS: dict[str, str] = {
    "portion_size": 'Next week, try adding a portion — "a medium bowl," "about two cups," "one plate."',
    "bowl_or_plate_size": 'Next week, try naming the bowl size — "a small bowl," "a big dinner plate."',
    "serving_count": 'Next week, try adding counts — "two eggs," "three slices."',
    "drink_size": 'Next week, try adding drink sizes — "a large iced coffee," "a 12-ounce can."',
    "protein_amount": "Next week, try adding protein amounts — grams or ounces work best.",
    "sauce_or_dressing": "Next week, try mentioning sauces and dressings — they change estimates a lot.",
    "cheese_or_toppings": "Next week, try mentioning cheese and toppings.",
    "milk_or_creamer": "Next week, try mentioning milk or creamer in your drinks.",
    "unclear_food": "Next week, try naming each food — even roughly — when you log.",
}
