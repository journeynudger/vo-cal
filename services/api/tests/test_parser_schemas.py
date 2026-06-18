"""B0: contract schemas + fixture corpus loader.

Proves the corpus loads, every fixture is internally consistent, and the
Pydantic contract models round-trip clean JSON and reject malformed JSON with
field-level errors (the signal the one-retry loop in parser/llm.py consumes).
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from api.parser.schemas import (
    Importance,
    MealType,
    MissingDetail,
    ParsedItem,
    ParsedMeal,
    State,
    Unit,
)
from tests.corpus import CANONICAL_IDS, load_corpus

CORPUS = load_corpus()


def test_corpus_has_at_least_30_fixtures():
    assert len(CORPUS) >= 30


def test_corpus_ids_unique():
    ids = [f.id for f in CORPUS]
    assert len(ids) == len(set(ids))


def test_corpus_contains_canonical_four():
    ids = {f.id for f in CORPUS}
    assert ids >= CANONICAL_IDS


def test_canonical_four_lead_the_corpus():
    leading = {f.id for f in CORPUS[:4]}
    assert leading == CANONICAL_IDS


@pytest.mark.parametrize("fx", CORPUS, ids=lambda f: f.id)
def test_fixture_internally_consistent(fx):
    # meal_type is a valid enum member
    assert fx.meal_type in {m.value for m in MealType}
    # names list length matches declared item_count
    assert len(fx.names) == fx.item_count
    # per-index expectation maps never reference an out-of-range item
    for mapping in (fx.amounts, fx.units, fx.states, fx.fat_ratios, fx.brands):
        for idx in mapping:
            assert 0 <= idx < fx.item_count
    # any stated unit/state is a valid enum value
    for unit in fx.units.values():
        assert unit in {u.value for u in Unit}
    for state in fx.states.values():
        assert state in {s.value for s in State}
    # when a question is expected, a target field path is declared
    if fx.expect_question:
        assert fx.question_field is not None
        assert fx.question_field.startswith("items[")


def test_parsed_meal_roundtrip_clean_json():
    payload = {
        "meal_type": "unspecified",
        "items": [
            {
                "name": "ground beef",
                "amount": 4,
                "unit": "oz",
                "state": "unspecified",
                "fat_ratio": "93/7",
                "brand": None,
                "prep_method": None,
                "confidence": 0.96,
            }
        ],
        "missing_details": [
            {
                "field": "items[0].state",
                "importance": "medium",
                "question": "Was the 4oz of beef weighed raw or cooked?",
            }
        ],
    }
    meal = ParsedMeal.model_validate(payload)
    assert meal.items[0].unit is Unit.OZ
    assert meal.items[0].fat_ratio == "93/7"
    assert meal.missing_details[0].importance is Importance.MEDIUM
    # round-trips byte-stable through JSON
    assert ParsedMeal.model_validate_json(meal.model_dump_json()) == meal


def test_schema_rejects_unknown_field():
    with pytest.raises(ValidationError) as exc:
        ParsedItem.model_validate(
            {"name": "rice", "confidence": 0.9, "calories": 200}  # hallucinated field
        )
    assert any(e["type"] == "extra_forbidden" for e in exc.value.errors())


def test_schema_rejects_bad_unit():
    with pytest.raises(ValidationError) as exc:
        ParsedItem.model_validate({"name": "rice", "unit": "grams", "confidence": 0.9})
    assert any("unit" in e["loc"] for e in exc.value.errors())


def test_schema_rejects_bad_fat_ratio():
    with pytest.raises(ValidationError):
        ParsedItem.model_validate({"name": "beef", "fat_ratio": "ninety-three", "confidence": 0.9})


def test_schema_rejects_confidence_out_of_range():
    with pytest.raises(ValidationError):
        ParsedItem.model_validate({"name": "beef", "confidence": 1.4})


def test_schema_rejects_non_positive_amount():
    with pytest.raises(ValidationError):
        ParsedItem.model_validate({"name": "beef", "amount": 0, "confidence": 0.9})


def test_missing_detail_requires_question_text():
    with pytest.raises(ValidationError):
        MissingDetail.model_validate({"field": "items[0].amount", "importance": "high"})


def test_parsed_item_defaults():
    item = ParsedItem.model_validate({"name": "apple", "confidence": 0.8})
    assert item.amount is None
    assert item.unit is None
    assert item.state is State.UNSPECIFIED
    assert item.brand is None
