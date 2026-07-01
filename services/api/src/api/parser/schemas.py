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

from pydantic import BaseModel, ConfigDict, Field

from ..nutrition.schemas import Macros, ResolutionSource


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


class ParsedItem(BaseModel):
    """One food item extracted from speech. Amounts come from the transcript or are null."""

    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, description="Canonical food name, normalized from speech")
    amount: float | None = Field(default=None, gt=0, description="Null when unstated")
    unit: Unit | None = Field(
        default=None, description="Null with a non-null amount means standard servings"
    )
    state: State = State.UNSPECIFIED
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


class RefineAnswer(BaseModel):
    field: str = Field(
        min_length=1, description='Path from the question, e.g. "items[1].fat_ratio"'
    )
    value: Any = Field(description="The user's answer: number for amounts, string otherwise")


class RefineRequest(BaseModel):
    parse_id: UUID
    answers: list[RefineAnswer] = Field(min_length=1, max_length=10)
