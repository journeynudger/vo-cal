"""Parser contract schemas + parse API request/response models.

The ``ParsedMeal`` / ``ParsedItem`` / ``MissingDetail`` models mirror
``docs/PARSER_CONTRACT.md`` exactly — field names, enums, and nullability.
If they disagree, the contract doc wins; fix this file.

``extra="forbid"`` on the contract models is deliberate: the LLM's tool output
is validated against these, and a hallucinated field must produce a
field-level validation error (which feeds the one-retry loop in parser/llm.py)
rather than being silently dropped.
"""

from __future__ import annotations

from enum import Enum
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

from ..nutrition.schemas import Macros, ResolutionSource
from .certainty import Certainty


class Unit(str, Enum):
    """Contract units. ``null`` unit with a non-null amount means standard servings."""

    G = "g"
    OZ = "oz"
    LB = "lb"
    CUP = "cup"
    TBSP = "tbsp"
    TSP = "tsp"
    PIECE = "piece"
    SLICE = "slice"
    SCOOP = "scoop"
    ML = "ml"


class State(str, Enum):
    RAW = "raw"
    COOKED = "cooked"
    UNSPECIFIED = "unspecified"


class Importance(str, Enum):
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


class MealType(str, Enum):
    BREAKFAST = "breakfast"
    LUNCH = "lunch"
    DINNER = "dinner"
    SNACK = "snack"
    UNSPECIFIED = "unspecified"


# Near-miss spellings the model emits for real units — coerce instead of rejecting the
# whole parse over pluralization/verbosity. Anything mass-like NOT in this map still
# rejects (see _lenient_unit): turning an unrecognized weight into servings would be a
# multiplying error, not a graceful degrade.
_UNIT_SYNONYMS: dict[str, str] = {
    "grams": "g", "gram": "g", "gs": "g",
    "ounce": "oz", "ounces": "oz",
    "pound": "lb", "pounds": "lb", "lbs": "lb",
    "milliliter": "ml", "milliliters": "ml", "millilitre": "ml", "millilitres": "ml", "mls": "ml",
    "cups": "cup",
    "tablespoon": "tbsp", "tablespoons": "tbsp", "tbsps": "tbsp",
    "teaspoon": "tsp", "teaspoons": "tsp", "tsps": "tsp",
    "pieces": "piece", "pcs": "piece", "pc": "piece",
    "slices": "slice",
    "scoops": "scoop",
}


class ParsedItem(BaseModel):
    """One food item extracted from speech. Amounts come from the transcript or are null."""

    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, description="Canonical food name, normalized from speech")
    amount: float | None = Field(default=None, gt=0, description="Null when unstated")
    unit: Unit | None = Field(
        default=None, description="Null with a non-null amount means standard servings"
    )
    state: State = State.UNSPECIFIED

    @field_validator("state", mode="before")
    @classmethod
    def _lenient_state(cls, v: object) -> object:
        """An off-enum state ("crumbled", "scrambled") degrades to UNSPECIFIED — it must
        never kill the parse. Field evidence 2026-07-30: the model tagged feta
        state="crumbled" and the WHOLE meal 422'd; a wrong state costs at most a
        raw/cooked factor, losing the log costs everything."""
        if v is None or (isinstance(v, str) and v not in (s.value for s in State)):
            return State.UNSPECIFIED
        return v

    @field_validator("unit", mode="before")
    @classmethod
    def _lenient_unit(cls, v: object) -> object:
        """Boundary lenience for unit, in three tiers. Near-miss spellings of REAL units
        coerce ("grams" → g — rejecting the whole meal over pluralization lost logs).
        Container-ish words ("bowl", "handful", "glass") mean the amount counts standard
        servings (unit null) — "3 bowls" prices as 3 servings. But an unmappable
        MASS/VOLUME word must still reject: degrading "100 kilocalories of..." or a
        novel mass unit to servings would multiply a weight into a serving count."""
        if not isinstance(v, str) or v in (u.value for u in Unit):
            return v
        coerced = _UNIT_SYNONYMS.get(v.strip().lower())
        if coerced is not None:
            return coerced
        lowered = v.strip().lower()
        if any(tok in lowered for tok in ("gram", "ounce", "pound", "liter", "litre", "kilo", "oz", "lb", "ml")):
            return v  # unmappable mass/volume — let the enum reject it (retry feedback)
        return None
    fat_ratio: str | None = Field(
        default=None,
        pattern=r"^\d{2}/\d{1,2}$",
        description='Lean/fat as spoken, e.g. "93/7", "80/20"',
    )
    brand: str | None = Field(
        default=None, description="Resolution context and audit only; no restaurant DB lookup"
    )
    prep_method: str | None = Field(default=None, description='e.g. "grilled", "fried in butter"')
    variant: str | None = Field(
        default=None,
        description="Chosen variant key (e.g. fat-free) once answered; engine fills, LLM omits",
    )
    confidence: float = Field(
        ge=0.0, le=1.0, description="Parser's confidence this item is what the user said"
    )


class MissingDetail(BaseModel):
    """A candidate clarifying question. The parser proposes; the engine disposes."""

    model_config = ConfigDict(extra="forbid")

    field: str = Field(min_length=1, description='JSON path of the unknown, e.g. "items[0].state"')
    importance: Importance
    question: str = Field(
        min_length=1, description="A single user-facing question that would resolve it"
    )
    options: list[str] | None = Field(
        default=None, description="Quick-answer chips for the UI (variant keys, fat-ratio presets)"
    )


class ParsedMeal(BaseModel):
    """The full parser-contract output for one transcript."""

    model_config = ConfigDict(extra="forbid")

    meal_type: MealType = MealType.UNSPECIFIED
    items: list[ParsedItem] = Field(default_factory=list)
    missing_details: list[MissingDetail] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Parse API surface (POST /parse, POST /parse/refine) — contract + resolution
# ---------------------------------------------------------------------------


class ParseRequest(BaseModel):
    transcript: str = Field(min_length=1, max_length=4000)
    # Optional provenance: Phase C's enrichment worker passes these; ad-hoc
    # text parses (Phase B testing, admin replays) legitimately have neither.
    capture_id: UUID | None = None
    transcript_id: UUID | None = None


class FoodSourceRef(BaseModel):
    """One web source a grounded estimate was read from (trust row: '4 sources')."""

    url: str
    title: str = ""


class ParseResultItem(BaseModel):
    """A parsed item joined with its deterministic resolution."""

    name: str
    amount: float | None
    unit: Unit | None
    state: State
    fat_ratio: str | None
    brand: str | None
    prep_method: str | None
    variant: str | None = None
    grams: float
    macros: Macros
    confidence: float = Field(ge=0.0, le=1.0)
    source: ResolutionSource
    match_score: float = Field(ge=0.0, le=1.0)
    # AI best-guess (food not in dictionary/FDC). Surfaced in the parse PREVIEW too — not just
    # the confirm path — so the UI can flag an estimate before logging. The iOS client expects
    # this field; omitting it broke its decode (keyNotFound). Default False = a real resolution.
    is_estimate: bool = False
    # Web sources a grounded estimate was read from — ADDITIVE + optional (the Swift mirror
    # decodes it as Optional; shipped clients ignore unknown keys). None for deterministic
    # resolutions and knowledge-only estimates.
    sources: list[FoodSourceRef] | None = None


class ParseResult(BaseModel):
    parse_id: UUID
    supersedes: UUID | None = None
    meal_type: MealType
    items: list[ParseResultItem]
    totals: Macros
    meal_confidence: float = Field(ge=0.0, le=1.0)
    questions: list[MissingDetail] = Field(
        default_factory=list,
        description="One check per material ingredient over the threshold (decision #29); "
        "ordered highest-impact first, capped",
    )
    missing_details: list[MissingDetail] = Field(
        default_factory=list, description="All raw candidates considered, for audit"
    )
    model: str
    prompt_version: str
    # The confidence-aware logging layer (certainty.py): score, calm label, category,
    # missing-detail flags, assumptions, and coaching tips. Additive + optional so
    # shipped clients tolerate it and old parse payloads re-validate without it.
    certainty: Certainty | None = None


class RefineAnswer(BaseModel):
    field: str = Field(
        min_length=1, description='Path from the question, e.g. "items[1].fat_ratio"'
    )
    value: Any = Field(description="The user's answer: number for amounts, string otherwise")


class RefineRequest(BaseModel):
    parse_id: UUID
    answers: list[RefineAnswer] = Field(min_length=1, max_length=10)
