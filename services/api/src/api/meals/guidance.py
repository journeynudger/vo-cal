"""One thing to add, without numbers (decision 74; Francesco, 2026-10-12: "recommendations based
off what you're eating, with you blind to the numbers. Let us do the work for you.").

For a person who chose no numbers, the engine still computes the whole protocol (decision 59);
this reads the person's last seven days against it and names, in one catalog sentence, the
first thing short, in a fixed order: protein, produce, fat, fiber. The sentence carries no
number, and where the person has eaten foods of the right kind in the last month it names up
to two of them ("Your Greek yogurt or chicken breast"), so the guidance is about their food,
not a textbook's. A food whose name has a digit in it ("93/7 ground beef") is never quoted.

No line when fewer than three of the seven days were logged (too little to read), and none when
nothing is short: absence says it, never an "all good" card (no grade, decision 69). Every line
is here, in this file; no model writes one (decision 71's rule).
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo

from ..db import SupportsDatabase
from ..nutrition.dictionary import FoodDictionary, get_dictionary
from ..nutrition.schemas import NutrientProfile
from ..protocols.store import ProtocolsStore
from .generator import PlanFood, Role, role_of
from .store import MealsStore
from .today import (
    Guidance,
    GuidanceKind,
    consumed_from_day,
    protein_band_from_protocol,
    targets_from_protocol,
)

TITLE = "Something to add"
MIN_DAYS = 3
WEEK_DAYS = 7
OWN_FOODS_DAYS = 30
# Short means under this share of the protocol's number (decision 74).
SHORT: dict[str, float] = {"protein": 0.80, "produce": 0.70, "fat": 0.75, "fiber": 0.70}
# A food at or above this much fiber per 100 g counts as a fiber food (beans, oats, berries).
_FIBER_FOOD_G = 5.0

_OPENERS: dict[str, str] = {
    "protein": "Protein has been on the light side this week.",
    "produce": "Fruit and vegetables have been on the light side this week.",
    "fat": "Fat has been on the low side this week.",
    "fiber": "Fiber has been on the light side this week.",
}
# With the person's own foods ({foods} is "your X" or "your X or Y").
_OWN: dict[str, str] = {
    "protein": "{Foods} at one more meal a day would round it out.",
    "produce": "{Foods} at one more meal a day would round it out.",
    "fat": "A little more of {foods} with meals would bring it up.",
    "fiber": "{Foods}, more often, would bring it up.",
}
# Without any: the catalog's examples.
_GENERIC: dict[str, str] = {
    "protein": "A palm of chicken, fish, eggs, Greek yogurt or tofu at one more meal a day would round it out.",
    "produce": "A piece of fruit or a handful of vegetables at one more meal a day would round it out.",
    "fat": "A drizzle of olive oil, some avocado, a handful of nuts or an egg with meals would bring it up.",
    "fiber": "Beans, oats, berries or whole-grain bread are easy ways to bring it up.",
}


def _has_number(name: str) -> bool:
    """Any character that writes a number: digits, and the fractions, superscripts and other
    scripts a food's name can carry ("½ cup oats", "milk²"). ``\\d`` let those through to a
    person who chose no numbers (2026-10-22 audit)."""
    return any(ch.isnumeric() for ch in name)


@dataclass(frozen=True)
class WeekIntake:
    """Per logged day, over the days that had a meal."""

    days_logged: int
    protein: float
    produce: float
    fat: float
    fiber: float


@dataclass(frozen=True)
class GuidanceTargets:
    protein_floor: float
    produce: float
    fat: float
    fiber: float


def choose(week: WeekIntake, targets: GuidanceTargets, own: Mapping[str, Sequence[str]]) -> Guidance | None:
    """The first thing short, or None."""
    if week.days_logged < MIN_DAYS:
        return None
    checks: tuple[tuple[GuidanceKind, float, float], ...] = (
        ("protein", week.protein, targets.protein_floor),
        ("produce", week.produce, targets.produce),
        ("fat", week.fat, targets.fat),
        ("fiber", week.fiber, targets.fiber),
    )
    for kind, value, target in checks:
        if target > 0 and value < SHORT[kind] * target:
            return Guidance(kind=kind, title=TITLE, line=line_for(kind, own.get(kind, ())))
    return None


def line_for(kind: str, foods: Sequence[str]) -> str:
    named = [f for f in foods if f and not _has_number(f)][:2]
    if not named:
        return f"{_OPENERS[kind]} {_GENERIC[kind]}"
    phrase = "your " + " or ".join(named)
    sentence = _OWN[kind].format(foods=phrase, Foods=phrase[0].upper() + phrase[1:])
    return f"{_OPENERS[kind]} {sentence}"


def week_intake(rows: Sequence[Mapping[str, Any]], tz: ZoneInfo, dictionary: FoodDictionary | None = None) -> WeekIntake:
    """The rows' days averaged over the days that had a meal (local days in ``tz``)."""
    by_day: dict[date, list[Mapping[str, Any]]] = {}
    for row in rows:
        logged = row.get("logged_at")
        if not logged:
            continue
        stamp = datetime.fromisoformat(str(logged))
        local = stamp.astimezone(tz).date() if stamp.tzinfo else stamp.date()
        by_day.setdefault(local, []).append(row)
    days = len(by_day)
    if days == 0:
        return WeekIntake(days_logged=0, protein=0.0, produce=0.0, fat=0.0, fiber=0.0)
    totals = [consumed_from_day(list(day_rows), 0.0, dictionary) for day_rows in by_day.values()]
    return WeekIntake(
        days_logged=days,
        protein=sum(t.protein for t in totals) / days,
        produce=sum(t.produce for t in totals) / days,
        fat=sum(t.fat for t in totals) / days,
        fiber=sum(t.fiber for t in totals) / days,
    )


def own_foods(rows: Sequence[Mapping[str, Any]], dictionary: FoodDictionary | None = None) -> dict[str, list[str]]:
    """The person's logged foods by what they would add, most often first: a protein, produce,
    a fat, a fiber food. Read from each item's own numbers, with the plan generator's roles."""
    dictionary = dictionary or get_dictionary()
    counts: dict[str, dict[str, int]] = {"protein": {}, "produce": {}, "fat": {}, "fiber": {}}
    shown: dict[str, str] = {}
    for row in rows:
        for item in row.get("items") or []:
            kinds = _kinds(item, dictionary) if isinstance(item, Mapping) else ()
            name = " ".join(str(item.get("name") or "").split()) if isinstance(item, Mapping) else ""
            for kind in kinds:
                key = name.lower()
                shown.setdefault(key, name)
                counts[kind][key] = counts[kind].get(key, 0) + 1
    return {
        kind: [shown[k] for k in sorted(found, key=lambda k: -found[k])]
        for kind, found in counts.items()
    }


def _kinds(item: Mapping[str, Any], dictionary: FoodDictionary) -> tuple[str, ...]:
    name = " ".join(str(item.get("name") or "").split())
    grams = float(item.get("grams") or 0.0)
    macros = item.get("macros") if isinstance(item.get("macros"), Mapping) else {}
    if not name or grams <= 0:
        return ()
    scale = 100.0 / grams
    try:
        profile = NutrientProfile(
            kcal=float(macros.get("kcal") or 0.0) * scale,
            protein=float(macros.get("protein") or 0.0) * scale,
            carbs=float(macros.get("carbs") or 0.0) * scale,
            fat=float(macros.get("fat") or 0.0) * scale,
            fiber=float(macros.get("fiber") or 0.0) * scale,
        )
    except ValueError:
        return ()
    food = PlanFood(name=name, per_100g=profile, produce_per_100g=dictionary.produce_servings_for(name, 100.0))
    role = role_of(food)
    kinds: list[str] = []
    if role is Role.PROTEIN:
        kinds.append("protein")
    if role in (Role.FRUIT, Role.VEGETABLE):
        kinds.append("produce")
    if role is Role.FAT:
        kinds.append("fat")
    if profile.fiber >= _FIBER_FOOD_G:
        kinds.append("fiber")
    return tuple(kinds)


async def load_guidance(db: SupportsDatabase, user_id: UUID, day: date, tz: ZoneInfo) -> Guidance | None:
    """The guidance for the seven whole days before ``day``, against the active protocol, with
    the person's foods from the month before. None without a protocol."""
    protocol_row = await ProtocolsStore(db).get_active(user_id)
    if protocol_row is None:
        return None
    targets, _ = targets_from_protocol(protocol_row)
    band_floor, _ = protein_band_from_protocol(protocol_row, targets.protein)
    end = datetime.combine(day, datetime.min.time(), tzinfo=tz)
    store = MealsStore(db)
    week_rows = await store.list_between(user_id, end - timedelta(days=WEEK_DAYS), end)
    week = week_intake(week_rows, tz)
    if week.days_logged < MIN_DAYS:
        return None
    month_rows = await store.list_recent(user_id, since=end - timedelta(days=OWN_FOODS_DAYS), limit=200)
    return choose(
        week,
        GuidanceTargets(protein_floor=band_floor, produce=targets.produce, fat=targets.fat, fiber=targets.fiber),
        own_foods(month_rows),
    )
