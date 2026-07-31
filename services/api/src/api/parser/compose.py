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
    "carne asada", "al pastor", "brisket", "pulled pork",
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
    "whey", "protein", "ice", "juice", "chia seeds", "flax", "sugar", "brown sugar",
    "cream", "half and half", "whipped cream", "cinnamon", "vanilla", "chocolate chips",
    "raisins", "coconut", "pecans", "cashews", "seeds",
})

# Blended drinks are BASE-priced: the name itself prices powder+liquid (a protein
# shake) or fruit+liquid (a smoothie); "with X" usually lists ADD-INS or a partial
# recipe, not the whole drink. Suppressing on add-ins alone zeroed the base — "a
# protein shake with a banana and peanut butter" logged 293 kcal with the powder and
# milk gone (eval 2026-07-30). These containers only compose when a stated component
# can BE the base (a liquid or the powder itself).
_BLENDED_CONTAINERS: frozenset[str] = frozenset({"shake", "smoothie", "milkshake"})
_BLEND_BASES: frozenset[str] = frozenset({
    "milk", "almond milk", "oat milk", "soy milk", "coconut milk", "yogurt",
    "greek yogurt", "juice", "orange juice", "water", "ice cream",
    "protein powder", "whey", "whey protein", "protein",
})


# The dish's FILLING: one linked protein alone ("street tacos with carne asada",
# "burrito with chicken") is enough evidence the user described contents — but never
# full coverage, so it absorbs (dish keeps its price) rather than suppresses. Condiment
# singletons ("toast with butter") stay ADDITIVE: generic toast has no butter in it.
_PROTEIN_COMPONENTS: frozenset[str] = frozenset({
    "turkey", "deli turkey", "turkey breast", "ham", "chicken", "chicken breast",
    "beef", "steak", "roast beef", "salami", "pastrami", "bacon", "sausage", "egg",
    "eggs", "egg white", "tofu", "tempeh", "salmon", "tuna", "shrimp", "patty",
    "ground beef", "ground turkey", "ground chicken", "ground pork", "meatballs",
    "pepperoni", "prosciutto", "pork", "carnitas", "barbacoa", "chorizo", "carne asada",
})

# Milk-inclusive coffee drinks: the drink's milk is its IDENTITY, not a beverage beside
# it. The parser folds "latte with 2% milk" into one item (prompt rule 12), but when a
# split still arrives, the milk-family item absorbs into the drink (its estimate already
# includes milk). Field eval 2026-07-30: latte + separate "2% milk" logged 324 kcal.
_MILK_DRINK_WORDS: frozenset[str] = frozenset({
    "latte", "cappuccino", "mocha", "macchiato", "cortado", "chai", "frappuccino",
})
_MILK_FAMILY: frozenset[str] = frozenset({"milk", "cream", "half and half", "creamer"})


def _is_milk_drink(name: str) -> bool:
    return _head(name).split()[-1] in _MILK_DRINK_WORDS


def _is_milk_family(name: str) -> bool:
    words = _norm(name).split()
    if not words:
        return False
    return words[-1] in _MILK_FAMILY or " ".join(words[-2:]) in _MILK_FAMILY


def _is_protein_component(name: str) -> bool:
    words = _norm(name).split()
    if not words:
        return False
    return words[-1] in _PROTEIN_COMPONENTS or " ".join(words[-2:]) in _PROTEIN_COMPONENTS


def _is_blended(container_name: str) -> bool:
    return _head(container_name).split()[-1] in _BLENDED_CONTAINERS


def _has_blend_base(component_names: list[str]) -> bool:
    for name in component_names:
        words = _norm(name).split()
        if not words:
            continue
        if words[-1] in _BLEND_BASES or (len(words) > 1 and " ".join(words[-2:]) in _BLEND_BASES):
            return True
    return False

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


def _head(name: str) -> str:
    """The dish name before any ' with ...' suffix. Absorption renames a container to
    the full described dish ("chicken burrito with rice, beans") so the estimator prices
    the whole thing — container DETECTION must keep working on that enriched name at
    confirm-time re-analysis, or the absorbed components would re-price at store."""
    return _norm(name).split(" with ")[0].strip()


def is_container(name: str) -> bool:
    """Does this item NAME a composed-meal structure (possibly qualified: 'turkey sandwich')?"""
    n = _head(name)
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
    # Index of the container the absorbed components folded into — the resolver prices
    # THAT item as the full described dish ("chicken burrito with rice, beans"), not the
    # bare name (a bare "chicken burrito" estimated 198 g/400 kcal while its stated
    # contents sat at zero; eval 2026-07-30).
    absorbed_into_index: int | None = None
    # Exactly the names folded into that container (a strict subset of suppressed_names:
    # a merged verdict can also carry classic container suppressions, which must never
    # leak into the enriched dish name).
    absorbed_names: tuple[str, ...] = ()


def _qualifier_ingredients(container_name: str) -> set[str]:
    """Component-word tokens embedded in a container's qualifier ("CHICKEN burrito").

    The final container word/phrase is stripped; remaining single words and word pairs
    that name component-type foods are the ingredients the user put INSIDE the dish's
    name — they must be restated as components for the enumeration to count as full.
    """
    words = _head(container_name).split()
    for phrase in _CONTAINER_PHRASES:
        p = phrase.split()
        if words[-len(p):] == p:
            # The phrase's own leading words ARE qualifier candidates: stripping "avocado
            # toast" whole discarded the avocado, so "avocado toast with two eggs" read as
            # fully-enumerated, the toast was zeroed, and the meal logged 143 kcal (eval
            # 2026-07-30). Only the final structure word is the container.
            words = words[: -len(p)] + p[:-1]
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


# Egg-structure dishes: the stated eggs ARE the dish ("spinach omelet with two eggs
# and feta" is an omelet MADE OF those eggs). Pricing the omelet AND the eggs double-
# counted (513 kcal; eval 2026-07-30) — an egg component means full construction:
# suppress the container, price the parts.
_EGG_CONTAINERS: frozenset[str] = frozenset({"omelet", "omelette", "frittata", "scramble"})
_EGG_COMPONENTS: frozenset[str] = frozenset({"egg", "eggs", "egg white", "egg whites"})


def _egg_constructed(container_name: str, component_names: list[str]) -> bool:
    if _head(container_name).split()[-1] not in _EGG_CONTAINERS:
        return False
    return any(
        _norm(n).split()[-1] in ("egg", "eggs", "white", "whites") or _norm(n) in _EGG_COMPONENTS
        for n in component_names
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


def _milk_into_drink(names_amounts: list[tuple[str, float | None]]) -> Composition | None:
    """A milk-family item spoken alongside a milk-inclusive coffee drink IS the drink's
    milk — absorb it (the latte estimate already includes milk). Runs before and merges
    with the container pass; syrups/sugars are not milk-family and keep adding."""
    drinks = [i for i, (n, _) in enumerate(names_amounts) if _is_milk_drink(n)]
    if not drinks:
        return None
    milk_items = [
        i
        for i, (n, _) in enumerate(names_amounts)
        if i not in drinks and _is_milk_family(n)
    ]
    if not milk_items:
        return None
    milk_names = tuple(names_amounts[i][0] for i in milk_items)
    return Composition(
        frozenset(milk_items),
        milk_names,
        absorbed_by=names_amounts[drinks[0]][0],
        absorbed_into_index=drinks[0],
        absorbed_names=milk_names,
    )


def _merge(primary: Composition, milk: Composition | None) -> Composition:
    """Union a milk-drink absorption into the container verdict (indices are disjoint:
    milk-family items are not containers, and a milk drink is not a component)."""
    if milk is None:
        return primary
    primary_wins = primary.absorbed_into_index is not None
    return Composition(
        primary.suppressed_indices | milk.suppressed_indices,
        primary.suppressed_names + milk.suppressed_names,
        absorbed_by=primary.absorbed_by or milk.absorbed_by,
        absorbed_into_index=(
            primary.absorbed_into_index if primary_wins else milk.absorbed_into_index
        ),
        absorbed_names=primary.absorbed_names if primary_wins else milk.absorbed_names,
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
    milk = _milk_into_drink(names_amounts)

    all_containers = [i for i, (n, _) in enumerate(names_amounts) if is_container(n)]
    if not all_containers:
        return milk or Composition(frozenset(), ())

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
        # One linked, unquantified PROTEIN is still real content ("street tacos with
        # carne asada" summed the tacos AND the beef inside them — 608 kcal; eval
        # 2026-07-30). Never full coverage though: the dish keeps its price and the
        # filling folds in. Non-protein singletons ("toast with butter") stay additive.
        if (
            not sided
            and len(component_idx) == 1
            and not quantified
            and _is_protein_component(names_amounts[component_idx[0]][0])
        ):
            return _merge(
                Composition(
                    frozenset(component_idx),
                    (names_amounts[component_idx[0]][0],),
                    absorbed_by=names_amounts[containers[0]][0],
                    absorbed_into_index=containers[0],
                    absorbed_names=(names_amounts[component_idx[0]][0],),
                ),
                milk,
            )
        return milk or Composition(frozenset(), ())

    component_names = [names_amounts[i][0] for i in component_idx]
    covered = [
        i
        for i in containers
        if (
            _components_cover(names_amounts[i][0], component_names)
            # A blended drink is only "constructed" when a stated component can BE its
            # base (liquid or powder) — fruits alone are add-ins/partial recipe.
            and (not _is_blended(names_amounts[i][0]) or _has_blend_base(component_names))
        )
        # Egg dishes: stated eggs = the dish's substance; unstated qualifiers
        # (spinach) are trace and never block construction.
        or _egg_constructed(names_amounts[i][0], component_names)
    ]
    if covered == containers:
        return _merge(
            Composition(
                frozenset(containers),
                tuple(names_amounts[i][0] for i in containers),
            ),
            milk,
        )

    # Shakes price their base by NAME; add-ins go on top. Neither suppression (kills the
    # base) nor absorption (a generic "protein shake" doesn't include the banana) is
    # honest — base + add-ins simply SUM. Smoothies fall through to absorption instead:
    # their generic estimate DOES include blended fruit.
    uncovered = [i for i in containers if i not in covered]
    if uncovered and all(
        _head(names_amounts[i][0]).split()[-1] in ("shake", "milkshake") for i in uncovered
    ):
        return milk or Composition(frozenset(), ())

    # Partial enumeration: the container(s) keep their generic dish price; unquantified
    # components fold into it. (With several containers and mixed coverage — vanishingly
    # rare speech — err toward the dish price for all: over-counting a shared component
    # is a smaller harm than double-zeroing.)
    absorbed = [i for i in component_idx if names_amounts[i][1] is None]
    if not absorbed:
        # Everything the user listed was quantified — stated precision all stays priced,
        # and the dish keeps its generic price too (the over-count is the honest reading
        # of "a chicken burrito with 200g of rice": a dish plus a measured add-on).
        return milk or Composition(frozenset(), ())
    absorbed_names = tuple(names_amounts[i][0] for i in absorbed)
    return _merge(
        Composition(
            frozenset(absorbed),
            absorbed_names,
            absorbed_by=names_amounts[containers[0]][0],
            absorbed_into_index=containers[0],
            absorbed_names=absorbed_names,
        ),
        milk,
    )
