"""Clarify answer-merge integrity (RT-15/34/35/51).

merge_answer applies a user's answer via model_copy, which SKIPS ParsedItem's field
validators — so a bad answer must be rejected here, never written as a poisoned value
(non-positive/NaN amount, contract-invalid fat ratio) or fabricated into a quantity.
"""

from __future__ import annotations

from api.parser.clarify import ClarifyEngine, _parse_amount_answer
from api.parser.schemas import ParsedItem, State, Unit


def _item(**over) -> ParsedItem:
    base = {
        "name": "rice", "amount": 200.0, "unit": Unit.G,
        "state": State.UNSPECIFIED, "fat_ratio": None, "confidence": 0.9,
    }
    base.update(over)
    return ParsedItem(**base)


def test_parse_amount_answer_rejects_non_positive_nan_and_garbage():
    assert _parse_amount_answer(-5) is None
    assert _parse_amount_answer(0) is None
    assert _parse_amount_answer(float("nan")) is None
    assert _parse_amount_answer(float("inf")) is None
    assert _parse_amount_answer("not a number") is None
    assert _parse_amount_answer(True) is None  # bool is not a quantity
    # Valid answers still parse.
    assert _parse_amount_answer("150g") == (150.0, Unit.G)
    assert _parse_amount_answer(2) == (2.0, None)


async def test_merge_amount_ignores_bad_answer_keeps_item():
    eng = ClarifyEngine()
    items = [_item(amount=200.0, unit=Unit.G)]
    # A negative or unparseable amount must NOT overwrite the item with a poisoned value.
    assert (await eng.merge_answer(items, "items[0].amount", -10))[0].amount == 200.0
    assert (await eng.merge_answer(items, "items[0].amount", "junk"))[0].amount == 200.0
    # A valid answer applies.
    assert (await eng.merge_answer(items, "items[0].amount", "120g"))[0].amount == 120.0


async def test_merge_fat_ratio_ignores_invalid_ratio():
    eng = ClarifyEngine()
    items = [_item(name="ground beef", fat_ratio=None)]
    assert (await eng.merge_answer(items, "items[0].fat_ratio", "lean-ish"))[0].fat_ratio is None
    assert (await eng.merge_answer(items, "items[0].fat_ratio", "93/7"))[0].fat_ratio == "93/7"


async def test_merge_invalid_state_does_not_500():
    eng = ClarifyEngine()
    items = [_item(state=State.UNSPECIFIED)]
    # An invalid enum answer is ignored, not raised as a 500.
    assert (await eng.merge_answer(items, "items[0].state", "bogus"))[0].state is State.UNSPECIFIED
