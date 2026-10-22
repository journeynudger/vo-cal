"""The drafted plan's orchestration (decision 73): names to priced foods, the staples, a draft's
portions as items for the confirm path, and the foods a person already eats.

The arithmetic lives in meals/generator.py (pure) and the pricing on the one confirm path
(meals/router.py ``_reresolve``); this module is the glue between them and the request.
"""

from __future__ import annotations

import asyncio
from collections.abc import Mapping, Sequence
from typing import Annotated, Any

from pydantic import BaseModel, Field

from ..nutrition.dictionary import get_dictionary
from ..nutrition.resolver import Resolver
from ..nutrition.schemas import MatchKind
from ..parser.schemas import ParsedItem, Unit
from .generator import DraftSlot, PlanFood, Role
from .plan import PlanCheck, PlanSlot
from .schemas import ConfirmedItem

# What the plan may add when the person allows it: plain foods the curated dictionary prices,
# a morning and a savory choice where the role has both. Order is preference.
STAPLE_NAMES: dict[Role, tuple[str, ...]] = {
    Role.PROTEIN: ("greek yogurt", "egg", "chicken breast", "salmon"),
    Role.STARCH: ("oatmeal", "whole wheat bread", "brown rice", "potato"),
    Role.VEGETABLE: ("broccoli", "green beans", "carrots"),
    Role.FRUIT: ("blueberries", "banana", "apple"),
    Role.FAT: ("olive oil", "almonds", "avocado"),
    Role.DESSERT: ("dark chocolate",),
}
# The suggestions offered in step two: the person's most-logged foods, then their own foods.
MAX_SUGGESTIONS = 30
_MOST_LOGGED = 24


class GeneratePlanRequest(BaseModel):
    """Francesco's three steps, as the phone sends them."""

    meals: int = Field(ge=2, le=5)
    snacks: int = Field(default=0, ge=0, le=2)
    dessert: bool = False
    # A name is resolved from its first 80 characters (plan_foods); one longer than any food's
    # name is refused, never carried whole through the request (2026-10-22 audit).
    foods: list[Annotated[str, Field(max_length=200)]] = Field(default_factory=list, max_length=40)
    may_add: bool = False


class GeneratedSlot(PlanSlot):
    """A drafted slot: a saved slot's shape plus the part of the day it is (Breakfast, Snack),
    which the builder may print; the plan stores only the slot."""

    label: str


class GeneratedPlan(BaseModel):
    """The draft, priced and checked, never stored: the person edits it in the builder and
    saves it with PUT /meals/plan like any plan."""

    slots: list[GeneratedSlot]
    check: PlanCheck | None = None
    # Foods the plan added (only when allowed), foods the day had no place for, and names the
    # ladder could not price.
    added: list[str] = Field(default_factory=list)
    unused: list[str] = Field(default_factory=list)
    unpriced: list[str] = Field(default_factory=list)
    notes: list[str] = Field(default_factory=list)


class ReceiptFoods(BaseModel):
    foods: list[str]


async def plan_foods(resolver: Resolver, names: Sequence[str], *, added: bool = False) -> tuple[list[PlanFood], list[str]]:
    """Each name through the identity ladder, concurrently (the parse's rule), keeping the
    person's spelling. A name nothing could price comes back in the second list."""
    cleaned: list[str] = []
    seen: set[str] = set()
    for raw in names:
        name = " ".join(str(raw).split())[:80]
        if name and name.lower() not in seen:
            seen.add(name.lower())
            cleaned.append(name)
    identities = await asyncio.gather(
        *(resolver.resolve_identity(ParsedItem(name=name, confidence=0.9)) for name in cleaned)
    )
    dictionary = get_dictionary()
    priced: list[PlanFood] = []
    unpriced: list[str] = []
    for name, identity in zip(cleaned, identities, strict=True):
        if identity.match_kind is MatchKind.NONE:
            unpriced.append(name)
            continue
        priced.append(
            PlanFood(
                name=name,
                per_100g=identity.per_100g,
                serving_grams=identity.serving_grams,
                produce_per_100g=dictionary.produce_servings_for(name, 100.0),
                added=added,
                unweighed=identity.unweighed_serving,
            )
        )
    return priced, unpriced


async def staple_foods(resolver: Resolver) -> dict[Role, list[PlanFood]]:
    """The staples priced through the same ladder (dictionary hits: free and deterministic)."""
    out: dict[Role, list[PlanFood]] = {}
    for role, names in STAPLE_NAMES.items():
        foods, _ = await plan_foods(resolver, names, added=True)
        out[role] = [food for food in foods if food.role is role]
    return out


def items_for(slot: DraftSlot) -> list[ConfirmedItem]:
    """A drafted slot's portions as items for the confirm path, in the unit the resolver can
    price: whole pieces as servings (two eggs), a serving saved without its weight as servings
    of it (0.9 of my chili; in grams the confirm path refused it and the draft carried it at
    0 kcal, 2026-10-22), everything else in grams. The macros here are advisory; the confirm
    path prices them again from the identity (RT-02)."""
    items: list[ConfirmedItem] = []
    for portion in slot.portions:
        pieces = portion.pieces
        if portion.food.unweighed:
            amount, unit = round(portion.grams / portion.food.serving, 2), None
        elif pieces is not None:
            amount, unit = float(pieces), None
        else:
            amount, unit = round(portion.grams, 1), Unit.G
        items.append(
            ConfirmedItem(
                name=portion.food.name,
                amount=amount,
                unit=unit,
                grams=round(portion.grams, 1),
                macros=portion.food.per_100g.for_grams(portion.grams),
                confidence=0.9,
            )
        )
    return items


def most_logged_foods(meal_rows: Sequence[Mapping[str, Any]], personal_rows: Sequence[Mapping[str, Any]]) -> list[str]:
    """What the person eats, most often first (then most recently), from their logged items, then
    their own foods (My foods) not already listed. Items with no energy (water, black coffee)
    are not offered: a plan has nothing to size about them."""
    counts: dict[str, int] = {}
    shown: dict[str, str] = {}
    latest: dict[str, str] = {}
    for row in meal_rows:
        logged_at = str(row.get("logged_at") or "")
        for item in row.get("items") or []:
            if not isinstance(item, Mapping):
                continue
            name = " ".join(str(item.get("name") or "").split())
            macros = item.get("macros") if isinstance(item.get("macros"), Mapping) else {}
            if not name or float(macros.get("kcal") or 0.0) <= 0.0:
                continue
            key = name.lower()
            counts[key] = counts.get(key, 0) + 1
            if logged_at >= latest.get(key, ""):
                latest[key] = logged_at
                shown[key] = name
    # Most recent first, then (stable) most often: ties in count keep the recent one ahead.
    ordered = sorted(sorted(counts, key=lambda k: latest[k], reverse=True), key=lambda k: -counts[k])
    out = [shown[k] for k in ordered[:_MOST_LOGGED]]
    have = {name.lower() for name in out}
    for row in personal_rows:
        name = " ".join(str(row.get("name") or "").split())
        if name and name.lower() not in have:
            have.add(name.lower())
            out.append(name)
        if len(out) >= MAX_SUGGESTIONS:
            break
    return out[:MAX_SUGGESTIONS]

