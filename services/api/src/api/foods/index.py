"""The person's own vocabulary, ahead of every database.

Requirement (nutritionist brief, 2026-09-23): the foods no database has are a top pain,
a meal-prep container with its label, a batch of chili divided into eight. Once a person
declares one, saying its name must price it, every time, with their numbers. So the
resolver consults this index BEFORE the dictionary, the estimator and USDA: if you named
it, you meant it. A name that shadows a generic food ("chicken") is the person's choice,
visible under Settings > My foods, and retirable there.

Pure and deterministic: a normalized-name lookup that yields a FoodIdentity, the same type
every other source yields, so pricing, priming at refine and confirm, persistence on the
parse row and the edit sheet's "priced as" line all work unchanged.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from ..db import SupportsDatabase
from ..nutrition.dictionary import normalize_name
from ..nutrition.schemas import FoodIdentity, MatchKind, NutrientProfile, ResolutionSource
from ..parser.schemas import ParsedItem
from .store import PersonalFoodsStore

PERSONAL_KEY_PREFIX = "personal:"
# A serving whose weight the person did not state is carried as 100 g, so the per-serving
# numbers survive the per-100 g identity contract unchanged (1 serving = 100 g of a profile
# that IS the serving). No surface shows grams for such an item; the identity key says
# "personal", and a stated weight ("150 g of my chili") is refused for it (price() sees no
# real serving weight and the item stays unpriced by weight, as USDA rows do).
UNWEIGHED_SERVING_GRAMS = 100.0
_LEADING_WORDS = ("my ", "the ", "a serving of ", "one serving of ", "a portion of ")
_TRAILING_WORDS = (" recipe", " batch", " meal prep")


def spoken_key(name: str) -> str:
    """The key a spoken name is looked up under: normalized, with the ways people refer to
    their own food stripped ("my chili recipe" and "chili" are the same food)."""
    key = normalize_name(name)
    changed = True
    while changed:
        changed = False
        for lead in _LEADING_WORDS:
            if key.startswith(lead) and len(key) > len(lead):
                key = key[len(lead):]
                changed = True
        for tail in _TRAILING_WORDS:
            if key.endswith(tail) and len(key) > len(tail):
                key = key[: -len(tail)]
                changed = True
    return key


class PersonalFoodIndex:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self._by_key: dict[str, dict[str, Any]] = {}
        # Newest first from the store: an alias never shadows a later food's own name.
        for row in reversed(rows):
            for alias in row.get("aliases") or []:
                self._by_key[spoken_key(str(alias))] = row
        for row in reversed(rows):
            self._by_key[spoken_key(str(row.get("name") or ""))] = row

    def __len__(self) -> int:
        return len(self._by_key)

    def match(self, name: str) -> dict[str, Any] | None:
        return self._by_key.get(spoken_key(name))

    def identity_for(self, item: ParsedItem) -> FoodIdentity | None:
        row = self.match(item.name)
        if row is None:
            return None
        return identity_from_row(row, spoken_name=item.name)


def identity_from_row(row: dict[str, Any], *, spoken_name: str) -> FoodIdentity:
    per_serving = NutrientProfile.model_validate(row["per_serving"])
    serving_grams = row.get("serving_grams")
    if serving_grams:
        factor = 100.0 / float(serving_grams)
        per_100g = NutrientProfile(
            kcal=round(per_serving.kcal * factor, 3),
            protein=round(per_serving.protein * factor, 3),
            carbs=round(per_serving.carbs * factor, 3),
            fat=round(per_serving.fat * factor, 3),
            fiber=round(per_serving.fiber * factor, 3),
        )
        grams = float(serving_grams)
    else:
        per_100g = per_serving
        grams = UNWEIGHED_SERVING_GRAMS
    name = str(row.get("name") or "")
    exact = spoken_key(spoken_name) == spoken_key(name)
    return FoodIdentity(
        key=f"{PERSONAL_KEY_PREFIX}{row['id']}",
        # "manual" is the contract's word for numbers the person declared; the shipped app
        # decodes it, shows no estimate flag, and never re-resolves it away.
        source=ResolutionSource.MANUAL,
        match_kind=MatchKind.CANONICAL if exact else MatchKind.ALIAS,
        match_score=1.0,
        per_100g=per_100g,
        serving_grams=grams,
        basis_state="ready",
        priced_as=None if exact else name,
    )


def personal_food_id(identity: FoodIdentity | None) -> str | None:
    if identity is None or not identity.key.startswith(PERSONAL_KEY_PREFIX):
        return None
    return identity.key[len(PERSONAL_KEY_PREFIX):]


async def load_personal_index(db: SupportsDatabase, user_id: UUID) -> PersonalFoodIndex:
    return PersonalFoodIndex(await PersonalFoodsStore(db).list_active(user_id))
