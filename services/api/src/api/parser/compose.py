"""Composed-meal grammar — the container/component suppression pass (deterministic).

Humans describe meals as a STRUCTURE plus its CONTENTS: "a sandwich with two slices of
low-carb bread, turkey, ham, and provolone" is ONE sandwich made of those things — not a
generic 450-kcal sandwich PLUS bread PLUS turkey PLUS ham PLUS cheese. The field bug this
fixes: the parser correctly extracted container + components, but the resolver priced the
generic container too, double-counting every composed meal (sandwiches, wraps, bowls,
salads, burgers, smoothies, omelets, …).

The rule (product spec 2026-07): if the user names a composed meal AND describes its
contents, the named meal becomes the PARENT — a display grouping, not a calorie-bearing
line. Precision hierarchy: ingredient-level detail always beats a generic composed-meal
estimate; the two are never stacked.

When the container is the ONLY item ("I had a turkey sandwich"), it keeps its generic
dictionary calories — a vague log is still a successful log, and a generic estimate is
the honest price for it.

Sides stay separate: "a sandwich and chips" must NOT suppress the sandwich — chips are
not a sandwich component. Component-ness is decided by a lexicon of ingredient-type
foods (breads, deli meats, cheeses, produce, condiments, bases), not by mere adjacency.

Pizza is deliberately EXCLUDED: "two slices of pizza" makes pizza itself the quantified
calorie carrier (contract example 3 pattern) — suppressing it would zero the meal.

This pass runs BEFORE resolution (parse) and inside re-resolution (meals confirm), so the
suppression cannot be undone by the confirm path re-pricing the container — and so the
estimator is never even called for a suppressed container (no paid call for a grouping).
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# Lexicons (data, not a rule engine)
# ---------------------------------------------------------------------------

# Composed-meal structures. Matching is by the FINAL word(s) of the item name, so
# "turkey sandwich", "breakfast burrito", "chicken caesar wrap" all match. Pizza is
# intentionally absent (see module docstring); pasta/oatmeal/ramen/curry are absent
# because they are calorie-bearing BASES, not empty structures.
_CONTAINER_WORDS: frozenset[str] = frozenset({
    "sandwich", "wrap", "burrito", "taco", "tacos", "quesadilla", "burger",
    "cheeseburger", "hamburger", "salad", "bowl", "plate", "omelet", "omelette",
    "smoothie", "shake", "sub", "hoagie", "panini", "pita", "gyro", "parfait",
    "nachos", "sandwiches", "wraps", "burritos", "bowls",
})
# Multi-word container names that end in a non-container word.
_CONTAINER_PHRASES: tuple[str, ...] = (
    "avocado toast", "breakfast plate", "yogurt bowl", "burrito bowl", "rice bowl",
    "grain bowl", "poke bowl", "protein shake", "bagel sandwich",
)

# Foods that plausibly LIVE INSIDE a container — the signal that the user described the
# meal's contents. Deliberately broad but ingredient-shaped; whole composed dishes and
# obvious sides (chips, fries, soda, cookie, fruit as a side) are NOT here.
_COMPONENT_WORDS: frozenset[str] = frozenset({
    # breads / bases / shells
    "bread", "bun", "roll", "tortilla", "shell", "bagel", "toast", "croissant",
    "english muffin", "pita bread", "lettuce wrap", "rice", "beans", "quinoa",
    "noodles", "oats", "oatmeal", "granola",
    # proteins (incl. deli context)
    "turkey", "deli turkey", "turkey breast", "ham", "chicken", "chicken breast",
    "beef", "steak", "roast beef", "salami", "pastrami", "bacon", "sausage", "egg",
    "eggs", "egg white", "tofu", "tempeh", "salmon", "tuna", "shrimp", "patty",
    "ground beef", "ground turkey", "ground chicken", "ground pork", "meatballs",
    "pepperoni", "prosciutto", "pork", "carnitas", "barbacoa", "chorizo",
    # cheeses
    "cheese", "cheddar", "provolone", "swiss", "mozzarella", "american", "feta",
    "parmesan", "pepper jack", "blue cheese", "cream cheese", "cotija", "queso",
    # produce
    "lettuce", "tomato", "onion", "onions", "pickles", "peppers", "spinach",
    "avocado", "cucumber", "mushrooms", "banana", "berries", "strawberries",
    "blueberries", "corn", "jalapenos", "cilantro", "kale", "greens", "sprouts",
    "carrots", "olives",
    # condiments / sauces / dressings / add-ins
    "mayo", "mayonnaise", "mustard", "ketchup", "ranch", "dressing", "vinaigrette",
    "salsa", "guacamole", "guac", "sour cream", "hummus", "pesto", "sriracha",
    "honey", "syrup", "butter", "peanut butter", "almond butter", "jelly", "jam",
    "sauce", "marinara", "aioli", "tzatziki", "oil", "olive oil",
    # dairy / liquid bases / boosters (smoothies, bowls, oatmeal)
    "yogurt", "greek yogurt", "milk", "almond milk", "oat milk", "protein powder",
    "whey", "ice", "juice", "chia seeds", "flax",
})

_NON_ALNUM = re.compile(r"[^a-z0-9 ]+")


def _norm(name: str) -> str:
    return _NON_ALNUM.sub(" ", name.lower()).strip()


def is_container(name: str) -> bool:
    """Does this item NAME a composed-meal structure (possibly qualified: 'turkey sandwich')?"""
    n = _norm(name)
    if not n:
        return False
    if n in _CONTAINER_PHRASES or any(n.endswith(p) for p in _CONTAINER_PHRASES):
        return True
    return n.split()[-1] in _CONTAINER_WORDS


def is_component(name: str) -> bool:
    """Could this item plausibly be a container's CONTENT (ingredient-shaped food)?"""
    n = _norm(name)
    if not n or is_container(n):
        return False
    if n in _COMPONENT_WORDS:
        return True
    words = n.split()
    # "healthy life low carb bread" -> bread; "krakus ham" -> ham; "2 percent milk" -> milk
    return words[-1] in _COMPONENT_WORDS or (len(words) > 1 and " ".join(words[-2:]) in _COMPONENT_WORDS)


@dataclass(frozen=True)
class Composition:
    """The composition verdict for one parsed meal."""

    # Indices (into the input item list) of containers whose generic calories must be
    # suppressed because the user described their contents.
    suppressed_indices: frozenset[int]
    # Human-readable audit trail (certainty assumptions + debug logs).
    suppressed_names: tuple[str, ...]


def analyze(names_amounts: list[tuple[str, float | None]]) -> Composition:
    """Decide which container items are display groupings, not calorie lines.

    Input: (name, amount) per item, in order. A container is suppressed when the meal
    also carries component-shaped items — at least 2, or 1 that the user QUANTIFIED
    (an explicit amount signals ingredient-level precision, which always beats a
    generic estimate). A container that is the only item, or accompanied only by
    non-component foods (sides: chips, a drink, fruit), keeps its generic calories.
    """
    containers = [i for i, (n, _) in enumerate(names_amounts) if is_container(n)]
    if not containers:
        return Composition(frozenset(), ())

    component_idx = [
        i for i, (n, _) in enumerate(names_amounts) if i not in containers and is_component(n)
    ]
    quantified = [i for i in component_idx if names_amounts[i][1] is not None]

    if len(component_idx) >= 2 or len(quantified) >= 1:
        return Composition(
            frozenset(containers),
            tuple(names_amounts[i][0] for i in containers),
        )
    return Composition(frozenset(), ())
