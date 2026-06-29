"""Nutrition value objects: nutrient profiles, macro totals, resolution metadata.

These are the deterministic-side types (AGENTS.md non-negotiable #6: the LLM
extracts; deterministic code calculates). All macro math flows through
``Macros`` so rounding policy lives in one place.
"""

from __future__ import annotations

from enum import Enum

from pydantic import BaseModel, ConfigDict, Field


class NutrientProfile(BaseModel):
    """Macros per 100 g of the food as resolved (basis state included)."""

    # Reject NaN/+Inf as well as negatives: ge=0 already rejects NaN/-Inf (NaN>=0 is False)
    # but +Inf passes ge, so allow_inf_nan=False closes it.
    model_config = ConfigDict(allow_inf_nan=False)

    kcal: float = Field(ge=0)
    protein: float = Field(ge=0)
    carbs: float = Field(ge=0)
    fat: float = Field(ge=0)
    fiber: float = Field(default=0.0, ge=0)

    def for_grams(self, grams: float) -> Macros:
        factor = grams / 100.0
        return Macros(
            kcal=round(self.kcal * factor, 1),
            protein=round(self.protein * factor, 1),
            carbs=round(self.carbs * factor, 1),
            fat=round(self.fat * factor, 1),
            fiber=round(self.fiber * factor, 1),
        )


class Macros(BaseModel):
    """Computed macros for a concrete quantity (item or meal totals).

    Hard non-negativity + finiteness: these values are summed into durable meal/day
    totals and serialized to clients, so a NaN/Inf/negative is data poison (NaN -> JSON
    null breaks the non-optional Swift decode of a 'Logged' meal). The client never
    authors trustworthy macros (Non-Negotiable #6); bad input must 422, not persist.
    """

    model_config = ConfigDict(allow_inf_nan=False)

    kcal: float = Field(default=0.0, ge=0)
    protein: float = Field(default=0.0, ge=0)
    carbs: float = Field(default=0.0, ge=0)
    fat: float = Field(default=0.0, ge=0)
    fiber: float = Field(default=0.0, ge=0)

    def __add__(self, other: Macros) -> Macros:
        return Macros(
            kcal=round(self.kcal + other.kcal, 1),
            protein=round(self.protein + other.protein, 1),
            carbs=round(self.carbs + other.carbs, 1),
            fat=round(self.fat + other.fat, 1),
            fiber=round(self.fiber + other.fiber, 1),
        )

    @classmethod
    def zero(cls) -> Macros:
        return cls()


class ResolutionSource(str, Enum):
    DICTIONARY = "dictionary"
    FDC = "fdc"
    # AI best-guess when the food isn't in the dictionary or FDC — always flagged is_estimate
    # so the UI marks it and invites a correction; never silently trusted (see estimator.py).
    ESTIMATED = "estimated"
    # User typed the calories/macros themselves on the edit screen — trusted verbatim.
    MANUAL = "manual"
    UNRESOLVED = "unresolved"


class MatchKind(str, Enum):
    """How the food was matched, ordered by trustworthiness (feeds confidence)."""

    CANONICAL = "canonical"  # exact canonical-name hit
    ALIAS = "alias"  # dictionary alias hit
    PARAMETERIZED = "parameterized"  # ground-meat family + stated fat ratio (incl. interpolation)
    FAMILY_DEFAULT = "family_default"  # ground-meat family, ratio unknown → documented default
    FDC = "fdc"  # USDA FoodData Central search hit
    ESTIMATED = "estimated"  # AI best-guess, low trust by design
    NONE = "none"


class AmountSpecificity(str, Enum):
    """How precisely the user stated the quantity, ordered by trust."""

    STATED_MASS = "stated_mass"  # g / oz / lb / ml
    STATED_VOLUME = "stated_volume"  # cup / tbsp / tsp
    STATED_COUNT = "stated_count"  # piece / slice / scoop
    SERVING_MULTIPLIER = "serving_multiplier"  # "double", "light" → n × standard serving
    INFERRED_SERVING = "inferred_serving"  # nothing stated → 1 × standard serving
