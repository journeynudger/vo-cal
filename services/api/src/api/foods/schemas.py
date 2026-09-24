"""Schemas for personal foods.

A personal food is a food the person declared rather than one the databases know: the
nutrition label of a meal-prep container, a batch they cooked and divided into servings.
It carries a per-serving profile (the numbers as declared or as summed from resolved
ingredients), an optional serving weight, and the name they will say. Numbers are never
invented: a label's calories are kept as printed, and missing calories are computed with
the Atwater general factors (4, 4, 9), which is deterministic Python (AGENTS.md #6).
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from ..meals.schemas import ConfirmedItem
from ..nutrition.schemas import NutrientProfile

# Atwater general factors, kcal per gram. One address for the calorie identity used when a
# label or a batch states macros without calories.
KCAL_PER_G_PROTEIN = 4.0
KCAL_PER_G_CARBS = 4.0
KCAL_PER_G_FAT = 9.0


def kcal_from_macros(protein: float, carbs: float, fat: float) -> float:
    return round(protein * KCAL_PER_G_PROTEIN + carbs * KCAL_PER_G_CARBS + fat * KCAL_PER_G_FAT, 1)


class DeclaredServing(BaseModel):
    """One serving as printed on a label. ``kcal`` may be omitted; it is then computed."""

    model_config = ConfigDict(allow_inf_nan=False)

    kcal: float | None = Field(default=None, ge=0)
    protein: float = Field(ge=0)
    carbs: float = Field(ge=0)
    fat: float = Field(ge=0)
    fiber: float = Field(default=0.0, ge=0)

    def profile(self) -> NutrientProfile:
        kcal = self.kcal if self.kcal is not None else kcal_from_macros(self.protein, self.carbs, self.fat)
        return NutrientProfile(kcal=kcal, protein=self.protein, carbs=self.carbs, fat=self.fat, fiber=self.fiber)


class SaveLabelFoodRequest(BaseModel):
    """``POST /foods/personal``: a food from its label."""

    name: str = Field(min_length=1, max_length=120)
    per_serving: DeclaredServing
    # The weight of one serving when the label states it: lets "150 g of it" price by weight.
    serving_grams: float | None = Field(default=None, gt=0)
    # Servings in the package, when known (display only; the maths is per serving).
    servings_per_package: float | None = Field(default=None, gt=0)
    aliases: list[str] = Field(default_factory=list, max_length=8)


class SaveBatchFoodRequest(BaseModel):
    """``POST /foods/personal/batch``: a recipe from its resolved ingredients and a servings count.

    The items are the confirmed items of a parse (the batch as spoken, one ingredient per
    item); the server re-resolves them through the same engine as a meal confirm, sums the
    totals, and divides by ``servings``. Nothing here trusts client numbers.
    """

    name: str = Field(min_length=1, max_length=120)
    items: list[ConfirmedItem] = Field(min_length=1, max_length=40)
    servings: float = Field(gt=0, le=200)
    parse_id: UUID | None = None
    aliases: list[str] = Field(default_factory=list, max_length=8)


class PersonalFood(BaseModel):
    """A personal food as the app lists it (Settings > My foods) and as the resolver uses it."""

    id: UUID
    name: str
    aliases: list[str]
    per_serving: NutrientProfile
    serving_grams: float | None
    servings_per_package: float | None
    source: str  # "label" | "batch"
    created_at: datetime
