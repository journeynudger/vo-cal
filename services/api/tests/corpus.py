"""Fixture-corpus loader — shared by the pytest suite and scripts/parser-eval.

The corpus (tests/fixtures/transcripts.yaml) is the binding regression net
(decision #22). This module is the one place that knows its on-disk shape, so a
schema tweak touches a single loader rather than every consumer.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"
CORPUS_PATH = FIXTURES_DIR / "transcripts.yaml"
LLM_RESPONSES_DIR = FIXTURES_DIR / "llm_responses"

# The four canonical examples from docs/PARSER_CONTRACT.md — the hard gate.
CANONICAL_IDS = frozenset(
    {"canonical_beef", "canonical_rice", "canonical_chipotle", "canonical_burger"}
)


@dataclass(frozen=True)
class Fixture:
    """One corpus utterance with its expected parse fields."""

    id: str
    transcript: str
    meal_type: str
    item_count: int
    names: list[str]
    expect_question: bool
    amounts: dict[int, Any] = field(default_factory=dict)
    units: dict[int, str] = field(default_factory=dict)
    states: dict[int, str] = field(default_factory=dict)
    fat_ratios: dict[int, Any] = field(default_factory=dict)
    brands: dict[int, str] = field(default_factory=dict)
    question_field: str | None = None
    notes: str = ""

    @property
    def is_canonical(self) -> bool:
        return self.id in CANONICAL_IDS


def _coerce_int_keys(raw: dict[Any, Any] | None) -> dict[int, Any]:
    """YAML map keys parse as ints already, but normalize defensively."""
    if not raw:
        return {}
    return {int(k): v for k, v in raw.items()}


def load_corpus(path: Path = CORPUS_PATH) -> list[Fixture]:
    """Parse the YAML corpus into Fixture objects (canonical four first)."""
    data = yaml.safe_load(path.read_text())
    fixtures = [
        Fixture(
            id=row["id"],
            transcript=row["transcript"],
            meal_type=row["meal_type"],
            item_count=row["item_count"],
            names=list(row["names"]),
            expect_question=bool(row["expect_question"]),
            amounts=_coerce_int_keys(row.get("amounts")),
            units=_coerce_int_keys(row.get("units")),
            states=_coerce_int_keys(row.get("states")),
            fat_ratios=_coerce_int_keys(row.get("fat_ratios")),
            brands=_coerce_int_keys(row.get("brands")),
            question_field=row.get("question_field"),
            notes=row.get("notes", ""),
        )
        for row in data["fixtures"]
    ]
    # Canonical four lead the corpus for at-a-glance eval output.
    fixtures.sort(key=lambda f: (not f.is_canonical, f.id))
    return fixtures
