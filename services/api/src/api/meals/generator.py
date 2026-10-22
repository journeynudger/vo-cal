"""The meal plan, drafted (decision 73, Francesco's three steps): the person's day and foods
in, portions out.

Pure arithmetic on per-100 g profiles the resolver already chose. In a generated plan the model's
only part is reading a grocery receipt into names (meals/receipt.py); it never sees a target and
never writes a number (AGENTS.md #6). The router resolves the names, calls ``draft_plan``, then
prices every portion on the one confirm path and checks the result (meals/plan.py check_plan),
so the numbers the person sees are the confirm path's, exactly as a typed slot's are.

How a draft is made:

1. Each food gets a role from its own profile: dessert by name; fat when 60 percent of its
   energy is fat, unless it is a protein first (30 percent of its energy from protein and 10 g
   per 100 g, so eggs and 80/20 beef are proteins; aged cheese is a fat); fruit or vegetable
   when the dictionary credits it as produce; starch when half its energy is carbohydrate; a
   bar or chips are a snack, milk a drink, a mixed plate a dish (a meal on its own).
2. The day the person described becomes slots: meals by count, snacks between them, dessert
   last, at most eight.
3. Calories are split: snacks and dessert small and capped, the meals equal. Each meal gets a
   protein, produce (fruit at breakfast, vegetables later) and a starch, rotated through the
   person's foods so the day is not one meal three times; a dish stands in for protein and
   starch in the meal it fills.
4. The day is balanced in a fixed order: protein up to the band's floor, fat up to most of its
   share (Francesco, 2026-10-12: low fat dysregulates hormones), produce toward its count, then
   the starches carry the calories to the target. Portions stay inside sensible bounds per food,
   so a short list can leave a plan off the protocol; the check line then says by how much, and
   nothing is invented to hide it.
5. A food the person did not name is added only when they allowed it, from ``staples`` (the
   router resolves those names through the same ladder), and the draft says which.
"""

from __future__ import annotations

import math
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from enum import Enum
from typing import Literal

from ..nutrition.schemas import NutrientProfile

# Day shape bounds (the builder holds at most eight slots: five meals, two snacks, a dessert).
MIN_MEALS, MAX_MEALS = 2, 5
MAX_SNACKS = 2

# A dessert and a snack are small, and capped so a large target does not make them meals.
_DESSERT_SHARE, _DESSERT_CAP = 0.08, 180.0
_SNACK_SHARE, _SNACK_CAP = 0.10, 220.0
# Protein in the meals' own portions; starches, snacks and the rest carry the remainder.
_MEAL_PROTEIN_SHARE = 0.85
# Calories the balance aims inside before rounding to pieces and 5 g (the check accepts 10
# percent; the draft aims tighter so the rounding cannot carry it out).
_KCAL_AIM = 0.02
# Fat is raised to this share of the protocol's fat target before calories are balanced.
_FAT_FLOOR_SHARE = 0.80
# Protein is raised a little past the band's floor so rounding cannot drop it under.
_PROTEIN_MARGIN = 1.05
# Calories never push fat past this share of its target (the rest of the day carries them).
_FAT_CEILING_SHARE = 1.30

_MEAL_NAMES: dict[int, tuple[str, ...]] = {
    2: ("Lunch", "Dinner"),
    3: ("Breakfast", "Lunch", "Dinner"),
    4: ("Breakfast", "Lunch", "Afternoon meal", "Dinner"),
    5: ("Breakfast", "Late morning meal", "Lunch", "Afternoon meal", "Dinner"),
}


class Role(str, Enum):
    PROTEIN = "protein"
    STARCH = "starch"
    VEGETABLE = "vegetable"
    FRUIT = "fruit"
    FAT = "fat"
    DESSERT = "dessert"
    # A food eaten as a snack on its own (a bar, chips, jerky), never a meal's main.
    SNACK = "snack"
    # A drink with energy (milk, juice): one serving beside breakfast.
    DRINK = "drink"
    DISH = "dish"
    # Never placed: condiments (a plan does not size ketchup) and foods with no energy (water,
    # black coffee, diet soda). Reported as not placed.
    NONE = "none"


# Per role: (fewest, most) servings of the food's own serving, and a hard ceiling in grams.
_BOUNDS: dict[Role, tuple[float, float, float]] = {
    Role.PROTEIN: (0.5, 2.5, 300.0),
    Role.STARCH: (0.5, 3.0, 450.0),
    Role.VEGETABLE: (0.5, 2.5, 300.0),
    Role.FRUIT: (0.5, 2.0, 300.0),
    Role.FAT: (0.25, 2.0, 60.0),
    Role.DESSERT: (0.5, 1.5, 120.0),
    Role.SNACK: (0.5, 2.0, 150.0),
    Role.DRINK: (1.0, 1.0, 500.0),
    Role.DISH: (0.5, 2.0, 600.0),
    Role.NONE: (0.0, 0.0, 0.0),
}
# A serving to size by when the source carries none (USDA rows are per 100 g only).
_DEFAULT_SERVING: dict[Role, float] = {
    Role.PROTEIN: 113.0,
    Role.STARCH: 150.0,
    Role.VEGETABLE: 100.0,
    Role.FRUIT: 120.0,
    Role.FAT: 14.0,
    Role.DESSERT: 30.0,
    Role.SNACK: 40.0,
    Role.DRINK: 240.0,
    Role.DISH: 250.0,
    Role.NONE: 100.0,
}

_DESSERT_WORDS = frozenset({
    "chocolate", "cookie", "cookies", "cake", "cheesecake", "brownie", "brownies", "pie",
    "candy", "pudding", "gelato", "sorbet", "dessert", "donut", "doughnut", "cupcake",
    "icecream", "tiramisu", "fudge", "macaron", "macarons",
})
_FRUIT_WORDS = frozenset({
    "apple", "apples", "banana", "bananas", "orange", "oranges", "berry", "berries",
    "strawberry", "strawberries", "blueberry", "blueberries", "raspberry", "raspberries",
    "blackberry", "blackberries", "grape", "grapes", "grapefruit", "melon", "watermelon",
    "cantaloupe", "honeydew", "mango", "mangoes", "pineapple", "peach", "peaches", "pear",
    "pears", "plum", "plums", "cherry", "cherries", "kiwi", "fruit", "clementine",
    "clementines", "tangerine", "mandarin", "apricot", "apricots", "fig", "figs",
    "nectarine", "papaya", "pomegranate", "dates",
})
_VEGETABLE_OVERRIDES = frozenset({"tomato", "tomatoes", "avocado", "avocados"})
_BREAKFAST_WORDS = frozenset({
    "egg", "eggs", "yogurt", "oat", "oats", "oatmeal", "cereal", "granola", "toast", "bread",
    "bagel", "muffin", "pancake", "pancakes", "waffle", "waffles", "croissant", "cottage",
    "milk", "smoothie", "shake", "bacon", "sausage", "muesli",
})
# Foods eaten in pieces: sized in whole pieces of their serving, never 137 g of egg.
_COUNT_WORDS = frozenset({
    "egg", "eggs", "bread", "toast", "tortilla", "tortillas", "bagel", "muffin", "pita",
    "roll", "bun", "waffle", "pancake", "banana", "apple", "orange", "bar",
})
_CONDIMENT_WORDS = frozenset({
    "ketchup", "mustard", "sauce", "salsa", "dressing", "mayo", "mayonnaise", "sriracha",
    "syrup", "honey", "jam", "jelly", "vinegar", "seasoning", "spice", "spices", "salt",
    "ranch", "relish", "gravy", "marinade", "creamer", "sugar", "sweetener",
})
_DRINK_WORDS = frozenset({
    "milk", "juice", "soda", "latte", "coffee", "tea", "beer", "wine", "kombucha",
    "lemonade", "cappuccino", "espresso",
})
_SNACK_WORDS = frozenset({
    "bar", "bars", "chips", "crackers", "popcorn", "pretzels", "jerky", "trail",
})
# Fats suited to a meal's plate: oil on the vegetables before nuts at dinner.
_MEAL_FAT_WORDS = frozenset({"oil", "butter", "ghee", "avocado", "avocados", "cheese", "olives"})
# Fats a person eats on their own as a snack; oils and spreads are never a snack.
_SNACK_FAT_WORDS = frozenset({
    "almond", "almonds", "peanut", "peanuts", "walnut", "walnuts", "cashew", "cashews",
    "pistachio", "pistachios", "pecan", "pecans", "nut", "nuts", "seeds", "cheese",
    "hummus", "trail", "avocado",
})


@dataclass(frozen=True)
class PlanFood:
    """A food the resolver priced: what the person called it, its per-100 g profile, its
    serving, and the dictionary's produce credit per 100 g. ``added`` marks a staple the
    person did not name."""

    name: str
    per_100g: NutrientProfile
    serving_grams: float | None = None
    produce_per_100g: float = 0.0
    added: bool = False
    # A serving the person saved without its weight (foods/index.py): the confirm path prices it
    # in servings only, so the draft states it in servings (plan_drafts.items_for).
    unweighed: bool = False

    @property
    def role(self) -> Role:
        return role_of(self)

    @property
    def serving(self) -> float:
        if self.serving_grams and self.serving_grams > 0:
            return float(self.serving_grams)
        return _DEFAULT_SERVING[self.role]

    @property
    def counted(self) -> bool:
        """Sized in whole pieces of its serving. Only a food whose serving the resolver knows:
        pieces of an assumed serving cannot be priced (a USDA bagel drafted as "1 piece" came
        back at 0 kcal), so a food without one is sized by weight."""
        if self.unweighed or not self.serving_grams:
            return False
        return bool(_tokens(self.name) & _COUNT_WORDS)

    @property
    def breakfast(self) -> bool:
        return bool(_tokens(self.name) & _BREAKFAST_WORDS)


@dataclass(frozen=True)
class DayShape:
    meals: int
    snacks: int = 0
    dessert: bool = False


@dataclass(frozen=True)
class PlanTargets:
    """What the draft aims at, from the active protocol."""

    kcal: float
    protein_floor: float
    protein_target: float
    fat: float
    produce: float
    # The band's top (protein is a bounded goal): calories never push protein past it. None
    # when the protocol carries no band.
    protein_ceiling: float | None = None


@dataclass
class Portion:
    food: PlanFood
    grams: float

    @property
    def kcal(self) -> float:
        return self.food.per_100g.kcal * self.grams / 100.0

    @property
    def protein(self) -> float:
        return self.food.per_100g.protein * self.grams / 100.0

    @property
    def fat(self) -> float:
        return self.food.per_100g.fat * self.grams / 100.0

    @property
    def produce(self) -> float:
        return self.food.produce_per_100g * self.grams / 100.0

    @property
    def pieces(self) -> int | None:
        """Whole pieces for a counted food (two eggs, one slice), None for everything else."""
        if not self.food.counted:
            return None
        return max(1, round(self.grams / self.food.serving))


@dataclass
class DraftSlot:
    label: str
    kind: Literal["meal", "snack", "dessert"]
    portions: list[Portion] = field(default_factory=list)
    breakfast: bool = False
    budget: float = 0.0

    @property
    def kcal(self) -> float:
        return sum(p.kcal for p in self.portions)


@dataclass(frozen=True)
class Draft:
    slots: list[DraftSlot]
    # Staples placed in the plan (only when the person allowed additions), in first-use order.
    added: list[str]
    # Foods the person named that the day had no place for.
    unused: list[str]
    notes: list[str]


class DraftRefusedError(ValueError):
    """The request cannot become a plan (no foods and no additions allowed, a day out of
    bounds). The router answers 422 with the message."""


def role_of(food: PlanFood) -> Role:
    words = _tokens(food.name)
    if food.per_100g.kcal < 5.0 or words & _CONDIMENT_WORDS:
        return Role.NONE
    protein_share, carb_share, fat_share = _energy_shares(food.per_100g)
    if words & _DESSERT_WORDS and protein_share < 0.30:
        return Role.DESSERT
    if words & _SNACK_WORDS:
        return Role.SNACK
    cheese = "cheese" in words and "cottage" not in words
    protein_g = food.per_100g.protein
    if not cheese and protein_share >= 0.30 and (protein_g >= 10.0 or (protein_share >= 0.60 and protein_g >= 5.0)):
        return Role.PROTEIN
    if fat_share >= 0.60 or cheese:
        return Role.FAT
    if food.produce_per_100g > 0:
        if words & _FRUIT_WORDS and not words & _VEGETABLE_OVERRIDES:
            return Role.FRUIT
        return Role.VEGETABLE
    if words & _DRINK_WORDS:
        return Role.DRINK
    if carb_share >= 0.50:
        return Role.STARCH
    return Role.DISH


def draft_plan(
    shape: DayShape,
    foods: Sequence[PlanFood],
    targets: PlanTargets,
    *,
    may_add: bool,
    staples: Mapping[Role, Sequence[PlanFood]] | None = None,
) -> Draft:
    """The draft for this day, these foods and this protocol. Deterministic: the same inputs
    give the same plan."""
    if not MIN_MEALS <= shape.meals <= MAX_MEALS:
        raise DraftRefusedError(f"a day has {MIN_MEALS} to {MAX_MEALS} meals")
    if not 0 <= shape.snacks <= MAX_SNACKS:
        raise DraftRefusedError(f"a day has at most {MAX_SNACKS} snacks")
    if not foods and not may_add:
        raise DraftRefusedError("name a few foods, or let the plan add some")
    if targets.kcal <= 0:
        raise DraftRefusedError("there is no calorie target to build toward")

    pool = _Pool(foods, (staples or {}) if may_add else {})
    slots = _layout(shape, targets.kcal)
    notes: list[str] = []
    for slot in slots:
        _fill(slot, pool, targets, shape.meals)
    if shape.dessert and not any(s.kind == "dessert" and s.portions for s in slots):
        notes.append("Nothing among your foods reads as a dessert, so the plan leaves it out.")
    slots = [s for s in slots if s.portions]

    _balance_protein(slots, pool, targets)
    _balance_fat(slots, pool, targets)
    _balance_produce(slots, pool, targets)
    _balance_kcal(slots, pool, targets)
    _round(slots)

    return Draft(slots=slots, added=pool.added_names(), unused=pool.unused_names(), notes=notes)


def totals(slots: Sequence[DraftSlot]) -> tuple[float, float, float, float]:
    """(kcal, protein, fat, produce) of the slots as drafted: the balance's own view, which the
    confirm path's pricing then replaces."""
    portions = [p for s in slots for p in s.portions]
    return (
        sum(p.kcal for p in portions),
        sum(p.protein for p in portions),
        sum(p.fat for p in portions),
        sum(p.produce for p in portions),
    )


# -- the pool -------------------------------------------------------------------------------


class _Pool:
    """The person's foods by role, rotated so consecutive meals differ, and the staples behind
    them. ``take`` prefers the person's foods, then a staple; it records what was used."""

    def __init__(self, foods: Sequence[PlanFood], staples: Mapping[Role, Sequence[PlanFood]]) -> None:
        seen: set[str] = set()
        self._own: dict[Role, list[PlanFood]] = {role: [] for role in Role}
        self._order: list[str] = []
        for food in foods:
            key = _key(food.name)
            if key in seen:
                continue
            seen.add(key)
            self._own[food.role].append(food)
            self._order.append(food.name)
        self._staples = {role: list(items) for role, items in staples.items()}
        self._turn: dict[tuple, int] = {}
        self._used: set[str] = set()
        self._added: list[str] = []

    def has(self, role: Role) -> bool:
        return bool(self._own[role]) or bool(self._staples.get(role))

    def take(
        self,
        role: Role,
        *,
        breakfast: bool = False,
        prefer: frozenset[str] | None = None,
        only: frozenset[str] | None = None,
        fresh: bool = False,
    ) -> PlanFood | None:
        """A food of ``role``: the person's own first (rotated), then a staple. ``prefer`` and
        ``breakfast`` narrow softly; ``only`` narrows strictly; ``fresh`` takes only a food
        not placed yet (a dish is a whole meal, once)."""
        if role is Role.NONE:
            return None
        own = [f for f in self._own[role] if not fresh or _key(f.name) not in self._used]
        staples = [f for f in self._staples.get(role) or [] if not fresh or f.name not in self._added]
        own = _narrow(own, role, breakfast=breakfast, prefer=prefer, only=only)
        staples = _narrow(staples, role, breakfast=breakfast, prefer=prefer, only=only)
        # A morning staple the person allowed beats rice at breakfast; their own morning food
        # beats both.
        if breakfast and own and not any(f.breakfast for f in own) and any(f.breakfast for f in staples):
            own = []
        if own:
            food = self._rotate((role, breakfast), own)
            self._used.add(_key(food.name))
            return food
        if not staples:
            return None
        food = self._rotate((role, breakfast, "staple"), staples)
        if food.name not in self._added:
            self._added.append(food.name)
        return food

    def _rotate(self, key: tuple, foods: list[PlanFood]) -> PlanFood:
        turn = self._turn.get(key, 0)
        self._turn[key] = turn + 1
        return foods[turn % len(foods)]

    def added_names(self) -> list[str]:
        return list(self._added)

    def unused_names(self) -> list[str]:
        return [name for name in self._order if _key(name) not in self._used]


# -- the day --------------------------------------------------------------------------------


def _layout(shape: DayShape, kcal: float) -> list[DraftSlot]:
    meal_names = _MEAL_NAMES[shape.meals]
    dessert_budget = min(_DESSERT_SHARE * kcal, _DESSERT_CAP) if shape.dessert else 0.0
    snack_budget = min(_SNACK_SHARE * kcal, _SNACK_CAP)
    meal_budget = (kcal - dessert_budget - snack_budget * shape.snacks) / shape.meals

    # Snacks sit between meals, the earliest gaps first; a snack with no gap left goes before
    # the first meal (two meals and two snacks: a morning snack, lunch, a snack, dinner).
    after: list[int] = list(range(shape.meals - 1))[: shape.snacks]
    before_first = shape.snacks - len(after)
    slots: list[DraftSlot] = []
    for _ in range(before_first):
        slots.append(DraftSlot(label="Morning snack", kind="snack", budget=snack_budget))
    for index, name in enumerate(meal_names):
        slots.append(DraftSlot(label=name, kind="meal", breakfast=name == "Breakfast", budget=meal_budget))
        if index in after:
            label = "Morning snack" if name == "Breakfast" else "Afternoon snack"
            slots.append(DraftSlot(label=label, kind="snack", budget=snack_budget))
    if shape.snacks == 1:
        for slot in slots:
            if slot.kind == "snack":
                slot.label = "Snack"
    if shape.dessert:
        slots.append(DraftSlot(label="Dessert", kind="dessert", budget=dessert_budget))
    return slots


def _fill(slot: DraftSlot, pool: _Pool, targets: PlanTargets, meals: int) -> None:
    if slot.kind == "dessert":
        _fill_dessert(slot, pool)
    elif slot.kind == "snack":
        _fill_snack(slot, pool)
    else:
        _fill_meal(slot, pool, targets, meals)


def _fill_dessert(slot: DraftSlot, pool: _Pool) -> None:
    food = pool.take(Role.DESSERT) or pool.take(Role.FRUIT)
    if food is not None:
        slot.portions.append(_sized(food, slot.budget))


def _fill_snack(slot: DraftSlot, pool: _Pool) -> None:
    first = slot.label in ("Snack", "Morning snack")
    order = (Role.FRUIT, Role.SNACK, Role.PROTEIN, Role.FAT) if first else (Role.PROTEIN, Role.SNACK, Role.FAT, Role.FRUIT)
    for role in order:
        only = _SNACK_FAT_WORDS if role is Role.FAT else None
        food = pool.take(role, breakfast=role is Role.PROTEIN, only=only)
        if food is not None:
            slot.portions.append(_sized(food, slot.budget))
            return


def _fill_meal(slot: DraftSlot, pool: _Pool, targets: PlanTargets, meals: int) -> None:
    """A protein, produce and a starch; outside breakfast a dish stands in for protein and
    starch, each dish once; breakfast carries one drink with energy."""
    dish = pool.take(Role.DISH, fresh=True) if not slot.breakfast else None
    produce_role = Role.FRUIT if slot.breakfast else Role.VEGETABLE
    other = Role.VEGETABLE if produce_role is Role.FRUIT else Role.FRUIT
    produce = pool.take(produce_role) or pool.take(other)
    produce_portion = None
    if produce is not None:
        servings = 1.0 if slot.breakfast else 1.5
        produce_portion = Portion(produce, _clamp(produce, produce.serving * servings))
    if dish is not None:
        room = slot.budget - (produce_portion.kcal if produce_portion else 0.0)
        slot.portions.append(_sized(dish, room))
        if produce_portion:
            slot.portions.append(produce_portion)
        return

    protein_aim = targets.protein_target * _MEAL_PROTEIN_SHARE / meals
    protein = pool.take(Role.PROTEIN, breakfast=slot.breakfast)
    if protein is not None:
        grams = protein_aim / max(protein.per_100g.protein / 100.0, 1e-6)
        slot.portions.append(Portion(protein, _clamp(protein, grams)))
    if produce_portion:
        slot.portions.append(produce_portion)
    if slot.breakfast:
        # One drink with energy beside breakfast (milk with the oats), at a serving.
        drink = pool.take(Role.DRINK, fresh=True)
        if drink is not None:
            slot.portions.append(Portion(drink, drink.serving))
    starch = pool.take(Role.STARCH, breakfast=slot.breakfast)
    if starch is not None:
        slot.portions.append(_sized(starch, slot.budget - slot.kcal))


# -- the balance ----------------------------------------------------------------------------


def _balance_protein(slots: list[DraftSlot], pool: _Pool, targets: PlanTargets) -> None:
    want = targets.protein_floor * _PROTEIN_MARGIN
    _, protein, _, _ = totals(slots)
    if protein >= want:
        return
    _grow(slots, Role.PROTEIN, _protein, want - protein, ceiling=Guard(_protein, targets.protein_ceiling) if targets.protein_ceiling else None)
    _, protein, _, _ = totals(slots)
    if protein >= want:
        return
    # Still short: a protein portion where there is none (a snack first, then the meals).
    for slot in sorted(slots, key=lambda s: (s.kind != "snack", s.kind != "meal")):
        if slot.kind == "dessert" or any(p.food.role is Role.PROTEIN for p in slot.portions):
            continue
        food = pool.take(Role.PROTEIN, breakfast=True)
        if food is None:
            return
        gap = want - totals(slots)[1]
        if gap <= 0:
            return
        grams = gap / max(food.per_100g.protein / 100.0, 1e-6)
        slot.portions.append(Portion(food, _clamp(food, grams)))


def _balance_fat(slots: list[DraftSlot], pool: _Pool, targets: PlanTargets) -> None:
    want = targets.fat * _FAT_FLOOR_SHARE
    _, _, fat, _ = totals(slots)
    if want <= 0 or fat >= want:
        return
    _grow(slots, Role.FAT, _fat, want - fat)
    _, _, fat, _ = totals(slots)
    if fat >= want:
        return
    # A fat at the main meals that have none (the later meals first: oil on dinner's
    # vegetables before butter on breakfast).
    meals = [s for s in slots if s.kind == "meal" and not s.breakfast] or [s for s in slots if s.kind == "meal"]
    open_meals = [s for s in reversed(meals) if not any(p.food.role is Role.FAT for p in s.portions)][:2]
    if not open_meals:
        return
    share = (want - fat) / len(open_meals)
    for slot in open_meals:
        food = pool.take(Role.FAT, prefer=_MEAL_FAT_WORDS)
        if food is None:
            return
        grams = share / max(food.per_100g.fat / 100.0, 1e-6)
        slot.portions.append(Portion(food, _clamp(food, grams)))


def _balance_produce(slots: list[DraftSlot], pool: _Pool, targets: PlanTargets) -> None:
    _, _, _, produce = totals(slots)
    if targets.produce <= 0 or produce >= targets.produce:
        return
    for role in (Role.VEGETABLE, Role.FRUIT):
        _grow(slots, role, lambda p: p.produce, targets.produce - totals(slots)[3])
        if totals(slots)[3] >= targets.produce:
            return
    # Fruit where there is no produce yet: the snacks, then breakfast.
    for slot in sorted(slots, key=lambda s: (s.kind != "snack", not s.breakfast)):
        if slot.kind == "dessert" or any(p.produce > 0 for p in slot.portions):
            continue
        gap = targets.produce - totals(slots)[3]
        if gap <= 0:
            return
        food = pool.take(Role.FRUIT) or pool.take(Role.VEGETABLE)
        if food is None or food.produce_per_100g <= 0:
            return
        grams = gap / (food.produce_per_100g / 100.0)
        slot.portions.append(Portion(food, _clamp(food, grams)))


def _balance_kcal(slots: list[DraftSlot], pool: _Pool, targets: PlanTargets) -> None:
    """The starches and dishes carry the calories; when they cannot, snacks and dessert, then
    fat, then protein move, in that order. Fat stays between its floor and its ceiling, protein
    between the band's floor and top: calories never buy a gram past either bound."""
    aim = targets.kcal
    fat_floor = targets.fat * _FAT_FLOOR_SHARE
    fat_ceiling = targets.fat * _FAT_CEILING_SHARE
    protein_floor = targets.protein_floor * _PROTEIN_MARGIN
    protein_ceiling = targets.protein_ceiling
    groups: tuple[tuple[tuple[Role, ...], Guard | None, Guard | None], ...] = (
        ((Role.STARCH, Role.DISH, Role.SNACK), None, None),
        ((Role.FRUIT, Role.DESSERT), None, None),
        ((Role.FAT,), Guard(_fat, fat_floor), Guard(_fat, fat_ceiling) if targets.fat > 0 else None),
        ((Role.PROTEIN,), Guard(_protein, protein_floor), Guard(_protein, protein_ceiling) if protein_ceiling else None),
    )
    for roles, floor, ceiling in groups:
        gap = aim - totals(slots)[0]
        if abs(gap) <= _KCAL_AIM * aim:
            return
        if gap > 0:
            _grow(slots, roles, _kcal, gap, ceiling=ceiling)
        else:
            _shrink(slots, roles, -gap, floor=floor)
    gap = aim - totals(slots)[0]
    if gap > _KCAL_AIM * aim:
        # Under even at every portion's ceiling: a starch where a meal has none, if allowed.
        for slot in (s for s in slots if s.kind == "meal"):
            if any(p.food.role in (Role.STARCH, Role.DISH) for p in slot.portions):
                continue
            food = pool.take(Role.STARCH, breakfast=slot.breakfast)
            if food is None:
                return
            gap = aim - totals(slots)[0]
            if gap <= _KCAL_AIM * aim:
                return
            slot.portions.append(_sized(food, gap))


@dataclass(frozen=True)
class Guard:
    """A bound on a day total while portions move: ``measure`` of one portion, and the total it
    may not cross."""

    measure: object
    limit: float


def _kcal(portion: Portion) -> float:
    return portion.kcal


def _protein(portion: Portion) -> float:
    return portion.protein


def _fat(portion: Portion) -> float:
    return portion.fat


def _grow(slots, roles, measure, amount: float, *, ceiling: Guard | None = None) -> None:
    """Raise the portions of ``roles`` toward their ceilings until ``measure`` has grown by
    ``amount``, in proportion to what each can still give, never carrying the day's
    ``ceiling.measure`` past ``ceiling.limit``."""
    roles = (roles,) if isinstance(roles, Role) else roles
    portions = [p for s in slots for p in s.portions if p.food.role in roles]
    for _ in range(3):
        if amount <= 1e-6:
            return
        room = [(p, _ceiling(p.food) - p.grams) for p in portions]
        room = [(p, r) for p, r in room if r > 1e-6]
        if ceiling is not None:
            spare = ceiling.limit - sum(ceiling.measure(q) for s in slots for q in s.portions)
            if spare <= 1e-6:
                return
            bound_room = sum(r * ceiling.measure(Portion(p.food, 100.0)) / 100.0 for p, r in room)
            if bound_room > spare:
                room = [(p, r * spare / bound_room) for p, r in room]
        unit = [(p, r, measure(Portion(p.food, 100.0)) / 100.0) for p, r in room]
        capacity = sum(r * u for _, r, u in unit)
        if capacity <= 1e-6:
            return
        share = min(1.0, amount / capacity)
        for portion, r, u in unit:
            portion.grams += r * share
            amount -= r * share * u


def _shrink(slots, roles, amount: float, *, floor: Guard | None) -> None:
    """Lower the portions of ``roles`` toward their floors until calories fall by ``amount``,
    never carrying the day's ``floor.measure`` under ``floor.limit``."""
    portions = [p for s in slots for p in s.portions if p.food.role in roles]
    for _ in range(3):
        if amount <= 1e-6:
            return
        room = [(p, p.grams - _floor(p.food)) for p in portions]
        room = [(p, r) for p, r in room if r > 1e-6]
        if floor is not None:
            spare = sum(floor.measure(q) for s in slots for q in s.portions) - floor.limit
            if spare <= 1e-6:
                return
            bound_room = sum(r * floor.measure(Portion(p.food, 100.0)) / 100.0 for p, r in room)
            if bound_room > spare:
                room = [(p, r * spare / bound_room) for p, r in room]
        capacity = sum(r * p.food.per_100g.kcal / 100.0 for p, r in room)
        if capacity <= 1e-6:
            return
        share = min(1.0, amount / capacity)
        for portion, r in room:
            portion.grams -= r * share
            amount -= r * share * portion.food.per_100g.kcal / 100.0


def _round(slots: list[DraftSlot]) -> None:
    """Whole pieces for counted foods, 5 g otherwise, never under 5 g. Protein and fat round
    up, so the floors the balance reached survive the rounding."""
    for slot in slots:
        for portion in slot.portions:
            up = portion.food.role in (Role.PROTEIN, Role.FAT)
            if portion.food.counted:
                exact = portion.grams / portion.food.serving
                pieces = max(1, math.ceil(exact - 1e-9) if up else round(exact))
                portion.grams = pieces * portion.food.serving
            else:
                steps = portion.grams / 5.0
                portion.grams = max(5.0, (math.ceil(steps - 1e-9) if up else round(steps)) * 5.0)


# -- helpers --------------------------------------------------------------------------------


def _narrow(
    foods: list[PlanFood],
    role: Role,
    *,
    breakfast: bool,
    prefer: frozenset[str] | None,
    only: frozenset[str] | None,
) -> list[PlanFood]:
    """Strict filter, soft preference, then the meal's register: morning foods at breakfast,
    savory proteins and starches at lunch and dinner (yogurt is breakfast's when chicken
    exists), each softly so a short list still fills the meal."""
    if only is not None:
        foods = [f for f in foods if _tokens(f.name) & only]
    if prefer is not None:
        foods = [f for f in foods if _tokens(f.name) & prefer] or foods
    if breakfast:
        return [f for f in foods if f.breakfast] or foods
    if role in (Role.PROTEIN, Role.STARCH):
        return [f for f in foods if not f.breakfast] or foods
    return foods


def _sized(food: PlanFood, kcal: float) -> Portion:
    per_gram = food.per_100g.kcal / 100.0
    grams = kcal / per_gram if per_gram > 0 else food.serving
    return Portion(food, _clamp(food, grams))


def _clamp(food: PlanFood, grams: float) -> float:
    return min(max(grams, _floor(food)), _ceiling(food))


def _floor(food: PlanFood) -> float:
    low, _, _ = _BOUNDS[food.role]
    return food.serving * low


def _ceiling(food: PlanFood) -> float:
    _, high, cap = _BOUNDS[food.role]
    return min(food.serving * high, max(cap, food.serving))


def _energy_shares(profile: NutrientProfile) -> tuple[float, float, float]:
    protein = profile.protein * 4.0
    carbs = profile.carbs * 4.0
    fat = profile.fat * 9.0
    total = protein + carbs + fat
    if total <= 0:
        return 0.0, 0.0, 0.0
    return protein / total, carbs / total, fat / total


def _tokens(name: str) -> set[str]:
    words = set(re.findall(r"[a-z]+", name.lower()))
    if "ice" in words and "cream" in words:
        words.add("icecream")
    return words


def _key(name: str) -> str:
    return " ".join(name.lower().split())
