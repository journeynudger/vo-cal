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

import itertools
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
    # produce (fruits included — they are the components of fruit salads, smoothies,
    # parfaits, and yogurt bowls; missing them broke "fruit salad with watermelon and grapes")
    "lettuce", "tomato", "onion", "onions", "pickles", "peppers", "spinach",
    "avocado", "cucumber", "mushrooms", "banana", "berries", "strawberries",
    "blueberries", "corn", "jalapenos", "cilantro", "kale", "greens", "sprouts",
    "carrots", "olives", "watermelon", "grapes", "apple", "orange", "mango",
    "pineapple", "peach", "melon", "cantaloupe", "honeydew", "grapefruit",
    "raspberries", "blackberries", "kiwi", "cherries", "fruit", "mixed fruit",
    # condiments / sauces / dressings / add-ins
    "mayo", "mayonnaise", "mustard", "ketchup", "ranch", "dressing", "vinaigrette",
    "salsa", "guacamole", "guac", "sour cream", "hummus", "pesto", "sriracha",
    "honey", "syrup", "butter", "peanut butter", "almond butter", "jelly", "jam",
    "sauce", "marinara", "aioli", "tzatziki", "oil", "olive oil",
    # dairy / liquid bases / boosters / mix-ins (smoothies, bowls, oatmeal, parfaits)
    "yogurt", "greek yogurt", "milk", "almond milk", "oat milk", "protein powder",
    "whey", "ice", "juice", "chia seeds", "flax", "sugar", "brown sugar", "cream",
    "half and half", "whipped cream", "cinnamon", "vanilla", "chocolate chips",
    "raisins", "coconut", "pecans", "cashews", "seeds",
})

# Side-dish phrasings: when the transcript says items came ON THE SIDE, they are NOT the
# container's contents — "a sandwich with rice and beans on the side" is a sandwich PLUS
# sides, and zeroing the sandwich would undercount the meal.
_SIDE_PHRASES = ("on the side", "side of", "as a side", "and a side", "with a side")

# Collective nouns that appear inside container names ("FRUIT salad", "mixed GREENS
# bowl") — they describe the components as a class, so stated fruits/greens satisfy
# them; they are never a distinct ingredient whose absence signals partial enumeration.
_GENERIC_QUALIFIERS: frozenset[str] = frozenset({"fruit", "mixed fruit", "greens"})

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

    # Indices (into the input item list) of items whose calories must be suppressed —
    # either containers whose contents the user fully described (display groupings),
    # or, when ``absorbed_by`` is set, components already included in a named dish.
    suppressed_indices: frozenset[int]
    # Human-readable audit trail (certainty assumptions + debug logs).
    suppressed_names: tuple[str, ...]
    # When set: the enumeration was PARTIAL (an ingredient named inside the container —
    # "CHICKEN burrito" — or the shell was never stated), so the CONTAINER keeps its
    # generic dish price and ``suppressed_names`` are the unquantified components it
    # already includes. None = classic container suppression.
    absorbed_by: str | None = None


def _qualifier_ingredients(container_name: str) -> set[str]:
    """Component-word tokens embedded in a container's qualifier ("CHICKEN burrito").

    The final container word/phrase is stripped; remaining single words and word pairs
    that name component-type foods are the ingredients the user put INSIDE the dish's
    name — they must be restated as components for the enumeration to count as full.
    """
    words = _norm(container_name).split()
    for phrase in _CONTAINER_PHRASES:
        p = phrase.split()
        if words[-len(p):] == p:
            words = words[: -len(p)]
            break
    else:
        if words and words[-1] in _CONTAINER_WORDS:
            words = words[:-1]
    found = {w for w in words if w in _COMPONENT_WORDS}
    found.update(
        " ".join(pair) for pair in itertools.pairwise(words) if " ".join(pair) in _COMPONENT_WORDS
    )
    return found - _GENERIC_QUALIFIERS


def _linked_in_transcript(container_name: str, transcript_norm: str) -> bool:
    """Did the user actually attach contents to THIS container ("salad WITH chicken")?

    Component-ness by lexicon alone zeroed unrelated dishes (field bugs 2026-07: "a
    cheeseburger, a banana, and an orange" logged 167 kcal — the fruits are component
    words, so the burger was suppressed; "a burger and a caesar salad with chicken"
    zeroed BOTH). The containment signal is in the transcript: the container word
    followed within a couple of words by a linking phrase. No transcript (or the
    container word isn't findable in it) → default LINKED, preserving the conservative
    suppression the confirm path and older callers rely on.
    """
    last = _norm(container_name).split()[-1]
    if not re.search(rf"\b{re.escape(last)}s?\b", transcript_norm):
        return True  # transcription drift — absence of evidence is not evidence
    return bool(
        re.search(
            rf"\b{re.escape(last)}s?\b(?:\s+\w+){{0,2}}\s+(?:with|containing|has|topped|loaded|made)\b",
            transcript_norm,
        )
    )


def _components_cover(container_name: str, component_names: list[str]) -> bool:
    """Do the stated components plausibly account for the WHOLE container?

    Completeness signal: every ingredient embedded in the container's own name
    ("CHICKEN burrito", "TURKEY sandwich") is restated as a component — else that
    ingredient's calories vanish with the suppressed container. An unqualified
    container ("a sandwich", "a bowl") makes no such promise, so the caller's
    component thresholds alone decide (the product spec's ingredient-detail-beats-
    generic rule, unchanged). Known accepted gap: a fully-suppressed shell container
    still loses an UNSTATED bread/tortilla — a smaller, pre-existing under-count.
    """
    component_words = {w for n in component_names for w in _norm(n).split()}
    return all(
        set(token.split()) <= component_words for token in _qualifier_ingredients(container_name)
    )


def analyze(
    names_amounts: list[tuple[str, float | None]], transcript: str = ""
) -> Composition:
    """Decide which container items are display groupings, not calorie lines.

    Input: (name, amount) per item, in order. A container is suppressed when the meal
    also carries component-shaped items — at least 2, or 1 that the user QUANTIFIED
    (an explicit amount signals ingredient-level precision, which always beats a
    generic estimate). A container that is the only item, or accompanied only by
    non-component foods (sides: chips, a drink, fruit), keeps its generic calories.

    PARTIAL enumeration inverts the verdict (field bug 2026-07: "chicken burrito with
    rice and beans" → 377 kcal — the zeroed burrito took the chicken and the tortilla
    with it). When the components do NOT cover the container (_components_cover), the
    container keeps its generic dish price — that estimate already includes typical
    contents — and the UNQUANTIFIED components are suppressed as absorbed into it.
    Components the user quantified stay priced: stated precision is never discarded.

    ``transcript``: when the user SAID the items came "on the side", they are sides,
    not contents — the bar rises (≥3 components or ≥2 quantified) so a sandwich with
    a side of rice and beans is not zeroed. The meals-confirm path re-analyzes WITHOUT
    a transcript (it isn't stored on the confirm request); that asymmetry deliberately
    errs toward suppression — under-counting a rare side-phrase meal is a smaller harm
    than re-introducing the generic-container double count at store time.
    """
    all_containers = [i for i, (n, _) in enumerate(names_amounts) if is_container(n)]
    if not all_containers:
        return Composition(frozenset(), ())

    # Only containers the transcript LINKS to contents participate; a dish merely eaten
    # alongside component-shaped foods ("a cheeseburger, a banana, and an orange") keeps
    # its generic price.
    t_norm = _norm(transcript)
    containers = [
        i for i in all_containers if not t_norm or _linked_in_transcript(names_amounts[i][0], t_norm)
    ]
    if not containers:
        return Composition(frozenset(), ())

    component_idx = [
        i for i, (n, _) in enumerate(names_amounts) if i not in all_containers and is_component(n)
    ]
    quantified = [i for i in component_idx if names_amounts[i][1] is not None]

    sided = any(p in transcript.lower() for p in _SIDE_PHRASES)
    needed_components, needed_quantified = (3, 2) if sided else (2, 1)

    if len(component_idx) < needed_components and len(quantified) < needed_quantified:
        return Composition(frozenset(), ())

    component_names = [names_amounts[i][0] for i in component_idx]
    covered = [i for i in containers if _components_cover(names_amounts[i][0], component_names)]
    if covered == containers:
        return Composition(
            frozenset(containers),
            tuple(names_amounts[i][0] for i in containers),
        )

    # Partial enumeration: the container(s) keep their generic dish price; unquantified
    # components fold into it. (With several containers and mixed coverage — vanishingly
    # rare speech — err toward the dish price for all: over-counting a shared component
    # is a smaller harm than double-zeroing.)
    absorbed = [i for i in component_idx if names_amounts[i][1] is None]
    if not absorbed:
        # Everything the user listed was quantified — stated precision all stays priced,
        # and the dish keeps its generic price too (the over-count is the honest reading
        # of "a chicken burrito with 200g of rice": a dish plus a measured add-on).
        return Composition(frozenset(), ())
    return Composition(
        frozenset(absorbed),
        tuple(names_amounts[i][0] for i in absorbed),
        absorbed_by=names_amounts[containers[0]][0],
    )
