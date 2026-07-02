"""B3: LLM parse step — FakeParserClient, post-validation, one-retry, canonical four.

Offline: every parse runs through FakeParserClient against recorded responses.
The live Anthropic path is exercised only under the ``live_llm`` marker.
"""

from __future__ import annotations

import os

import pytest

from api.parser.llm import (
    AnthropicParserClient,
    FakeParserClient,
    ParseError,
    ToolCallResult,
    parse_transcript,
)
from api.parser.prompts import PROMPT_VERSION, TOOL_NAME, build_messages
from api.parser.schemas import State, Unit

FAKE = FakeParserClient()


# -- canonical four ----------------------------------------------------------


async def test_canonical_beef_parses():
    meal, model, version = await parse_transcript(FAKE, "4oz 93/7 beef")
    assert len(meal.items) == 1
    item = meal.items[0]
    assert item.name == "ground beef"
    assert item.amount == 4
    assert item.unit is Unit.OZ
    assert item.fat_ratio == "93/7"
    assert version == PROMPT_VERSION
    assert model


async def test_canonical_rice_no_missing_details():
    meal, _, _ = await parse_transcript(FAKE, "200g cooked jasmine rice")
    assert len(meal.items) == 1
    assert meal.items[0].state is State.COOKED
    assert meal.missing_details == []


async def test_canonical_chipotle_five_items_with_modifiers():
    meal, _, _ = await parse_transcript(
        FAKE, "Chipotle bowl, double chicken, white rice, mild salsa, light cheese"
    )
    assert len(meal.items) == 5
    by_name = {i.name: i for i in meal.items}
    assert by_name["chicken"].amount == 2  # double
    assert by_name["cheese"].amount == 0.5  # light
    assert all(i.brand == "Chipotle" for i in meal.items)


async def test_canonical_burger_unknown_ratio():
    meal, _, _ = await parse_transcript(FAKE, "burger, unknown beef, regular cheddar, mayo")
    assert len(meal.items) == 4
    beef = meal.items[1]
    assert beef.name == "ground beef"
    assert beef.fat_ratio is None  # explicitly unknown — not invented
    # high-importance candidate on the beef fat ratio
    fields = {(d.field, d.importance.value) for d in meal.missing_details}
    assert ("items[1].fat_ratio", "high") in fields


# -- whole corpus parses cleanly through the fake client ---------------------


async def test_every_recorded_response_parses():
    from tests.corpus import load_corpus

    for fx in load_corpus():
        meal, _, _ = await parse_transcript(FAKE, fx.transcript)
        assert len(meal.items) == fx.item_count, fx.id
        assert [i.name for i in meal.items] == fx.names, fx.id


async def test_missing_recorded_response_raises():
    with pytest.raises(ParseError, match="no recorded response"):
        await parse_transcript(FAKE, "some transcript never recorded")


# -- post-validation: one retry on schema mismatch ---------------------------


class _RetryClient:
    """Returns a bad tool input first, then a good one — to exercise the retry."""

    model = "test-model"

    def __init__(self) -> None:
        self.calls = 0

    async def complete(
        self, transcript: str, *, retry_feedback: str | None = None
    ) -> ToolCallResult:
        self.calls += 1
        if retry_feedback is None:
            # hallucinated field → extra_forbidden validation error
            return ToolCallResult(
                {
                    "meal_type": "unspecified",
                    "items": [{"name": "rice", "confidence": 0.9, "calories": 200}],
                    "missing_details": [],
                },
                model=self.model,
                prompt_version="v",
            )
        return ToolCallResult(
            {
                "meal_type": "unspecified",
                "items": [{"name": "rice", "confidence": 0.9}],
                "missing_details": [],
            },
            model=self.model,
            prompt_version="v",
        )


async def test_one_retry_on_validation_error():
    client = _RetryClient()
    meal, _, _ = await parse_transcript(client, "rice")
    assert client.calls == 2  # original + one retry
    assert meal.items[0].name == "rice"


class _AlwaysBadClient:
    model = "test-model"

    async def complete(
        self, transcript: str, *, retry_feedback: str | None = None
    ) -> ToolCallResult:
        return ToolCallResult(
            {
                "meal_type": "unspecified",
                "items": [{"name": "x", "unit": "grams", "confidence": 0.9}],
                "missing_details": [],
            },
            model=self.model,
            prompt_version="v",
        )


async def test_persistent_validation_error_raises_after_retry():
    with pytest.raises(ParseError):
        await parse_transcript(_AlwaysBadClient(), "x")


class _EmptyClient:
    model = "test-model"

    async def complete(
        self, transcript: str, *, retry_feedback: str | None = None
    ) -> ToolCallResult:
        return ToolCallResult(
            {"meal_type": "unspecified", "items": [], "missing_details": []},
            model=self.model,
            prompt_version="v",
        )


async def test_empty_item_parse_rejected():
    with pytest.raises(ParseError, match="zero items"):
        await parse_transcript(_EmptyClient(), "uhh nothing")


# -- prompt assembly ---------------------------------------------------------


def test_build_messages_includes_few_shot_and_transcript():
    messages = build_messages("hello transcript")
    assert messages[-1]["content"] == "hello transcript"
    # few-shot assistant turns force the tool
    tool_uses = [
        b
        for m in messages
        if isinstance(m["content"], list)
        for b in m["content"]
        if b.get("type") == "tool_use"
    ]
    assert tool_uses
    assert all(t["name"] == TOOL_NAME for t in tool_uses)


def test_build_messages_shot_ids_are_deterministic_and_paired():
    # Shot ids must be process-stable (not hash()-based, which is salted by PYTHONHASHSEED)
    # so the assembled prompt is identical run-to-run, and each tool_use id must match its
    # tool_result id. Regression: hash()-based ids churned the prompt across processes.
    messages = build_messages("hello transcript")
    tool_use_ids = [
        b["id"]
        for m in messages
        if isinstance(m["content"], list)
        for b in m["content"]
        if b.get("type") == "tool_use"
    ]
    tool_result_ids = [
        b["tool_use_id"]
        for m in messages
        if isinstance(m["content"], list)
        for b in m["content"]
        if b.get("type") == "tool_result"
    ]
    assert tool_use_ids == [f"shot_{i}" for i in range(len(tool_use_ids))]
    assert tool_use_ids == tool_result_ids  # every result references its use


# -- live (deselected) -------------------------------------------------------


@pytest.mark.live_llm
async def test_live_anthropic_parses_canonical_beef():
    if not os.environ.get("ANTHROPIC_API_KEY"):
        pytest.skip("live_llm: ANTHROPIC_API_KEY not set")
    client = AnthropicParserClient()
    meal, _, _ = await parse_transcript(client, "4oz 93/7 beef")
    assert meal.items[0].fat_ratio == "93/7"
