"""Clarify answer-merge integrity (RT-15/34/35/51).

merge_answer applies a user's answer via model_copy, which SKIPS ParsedItem's field
validators — so a bad answer must be rejected here, never written as a poisoned value
(non-positive/NaN amount, contract-invalid fat ratio) or fabricated into a quantity.
"""

from __future__ import annotations

from api.parser.clarify import ClarifyEngine, _parse_amount_answer
from api.parser.schemas import ParsedItem, State, Unit


async def test_ground_meat_no_ratio_asks_fat_content():
    # RT-16: a bare ground-meat family default (no stated fat ratio) must ask its fat content
    # rather than silently logging the ~85/15 default — the spread across the family (lean to
    # fatty) is large (turkey ~94 kcal at 4oz), well past the bar for a single-tap choice.
    eng = ClarifyEngine()
    item = ParsedItem(name="ground turkey", amount=4.0, unit=Unit.OZ, confidence=0.9)
    decision = await eng.decide([item], [])
    assert any(q.field == "items[0].fat_ratio" for q in decision.questions)


async def test_stated_ratio_ground_meat_asks_nothing():
    # A ground meat WITH a stated ratio is fully resolved — no synthesized fat-content check.
    eng = ClarifyEngine()
    item = ParsedItem(name="ground beef", amount=4.0, unit=Unit.OZ, fat_ratio="93/7", confidence=0.9)
    decision = await eng.decide([item], [])
    assert not any(q.field == "items[0].fat_ratio" for q in decision.questions)


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


def test_parse_amount_answer_rejects_malformed_numeric_strings():
    # The amount regex admits any run of digits/dots, but "1.2.3" / "." / ".." are not
    # parseable floats. float() must not be allowed to raise out of here — the module
    # contract is "a bad answer is ignored, never raised as a 500" (RT: multi-dot crash).
    assert _parse_amount_answer("1.2.3") is None
    assert _parse_amount_answer("1.2.3g") is None
    assert _parse_amount_answer(".") is None
    assert _parse_amount_answer("..") is None


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
