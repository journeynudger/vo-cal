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
    # Longest token-suffix hit ("kitkat creamer" → "creamer"; "strawberry greek yogurt" →
    # "greek yogurt"): the head food is curated, the spoken prefix (flavor/brand line) is
    # not. Scored below ALIAS — the profile is the plain entry's, so flavored add-ins ride
    # the entry's variant axis (the clarify chip), not this match.
    SUFFIX = "suffix"
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


class FoodSourceRef(BaseModel):
    """One web source a grounded estimate was read from (trust row: '4 sources')."""

    url: str
    title: str = ""


class FoodIdentity(BaseModel):
    """WHAT food was priced: everything about the food that does not depend on how much of
    it was eaten (identity/quantity separation, 2026-09-23).

    Requirement: a manual amount or unit edit must never change which food is priced.
    Failure mode before this type existed: the resolver chose the SOURCE of a food by the
    amount's unit. "200 g cosmic crisp apple" went to USDA search first and priced 200 g of
    "Desserts, apple crisp, prepared-from-recipe" at 322 kcal; "a cosmic crisp apple" priced
    the curated apple at 95 kcal. Same words, two foods, and the refine edit from one amount
    to the other silently swapped them (field incident 2026-09-23). Identity is now resolved
    once from the identity fields only (name, brand, variant, fat ratio, prep method), is
    persisted on the parse item, and refine/confirm re-PRICE it (``Resolver.prime``).

    Persisted as JSON inside ``parses.payload.result.items[]`` and ``meal_logs.items[]``;
    every field is additive and optional for old rows and old clients.
    """

    # Stable handle for logs/evals: "dictionary:<canonical>[/variant][/ratio]",
    # "fdc:<fdcId>", "est:<estimator cache key>".
    key: str
    source: ResolutionSource
    match_kind: MatchKind
    match_score: float = Field(ge=0.0, le=1.0)
    per_100g: NutrientProfile
    # One standard serving in grams. None = the source carries no portion data (USDA FDC
    # rows are per-100g only): the identity can price a stated MASS and nothing else.
    serving_grams: float | None = None
    unit_conversions: dict[str, float] = Field(default_factory=dict)
    basis_state: str = "ready"  # raw | cooked | ready
    raw_cooked_factor: float | None = None
    resolved_fat_ratio: str | None = None
    # Material-variant axis (decision #29): the ordered variant keys and their per-100g
    # profiles; ``per_100g`` above is the chosen (or default) variant's profile.
    variant_family: list[str] | None = None
    variant_profiles: dict[str, NutrientProfile] | None = None
    variant_unspecified: bool = False
    resolved_variant: str | None = None
    is_estimate: bool = False
    sources: list[FoodSourceRef] = Field(default_factory=list)
    # What was actually priced when it is not literally what was said: the curated head of a
    # suffix/alias match ("apple" for "cosmic crisp apple") or a USDA row description. The UI
    # shows it so a wrong identity is visible BEFORE it is logged.
    priced_as: str | None = None
