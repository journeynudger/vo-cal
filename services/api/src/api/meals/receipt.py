"""A grocery receipt, read into food names (decision 73, the second of Francesco's steps: "they
could even upload their grocery receipt").

The model only READS (AGENTS.md #6): forced onto ``record_grocery_foods``, it returns the
foods and drinks on the receipt as a person would say them, and nothing else: no prices, no
quantities, no totals, no store, no payment line. The names then go where a typed food goes
(the plan generator resolves them through the ladder).

A receipt is not a capture: it is not food the person ate, so it is not kept (AGENTS.md #5
governs captures). The bytes go to the model and are dropped; a receipt carries a store, a time
and the end of a card number, so nothing about it is logged beyond its size and how many foods
it named.
"""

from __future__ import annotations

import base64
import importlib
import json
import logging
from pathlib import Path
from typing import Any, Protocol

from ..config import settings
from ..parser.llm import AnthropicParserClient, recorded_answers_allowed

logger = logging.getLogger(__name__)

RECEIPT_PROMPT_VERSION = "vocal-receipt-2026-10-12.1"
TOOL_NAME = "record_grocery_foods"
MAX_FOODS = 40
_MAX_NAME = 80

_RESPONSES_DIR = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "receipt_responses"

TOOL_SCHEMA: dict[str, Any] = {
    "name": TOOL_NAME,
    "description": "Record the foods and drinks a grocery receipt lists, as a person would name them.",
    "input_schema": {
        "type": "object",
        "properties": {
            "foods": {
                "type": "array",
                "maxItems": 60,
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {
                            "type": "string",
                            "description": "The food as a person would say it, e.g. 'Greek yogurt', 'chicken breast', 'Dave's Killer Bread'.",
                        },
                    },
                    "required": ["name"],
                },
            },
        },
        "required": ["foods"],
    },
}

SYSTEM_PROMPT = """\
You are Vo-Cal's grocery receipt reader. You turn a photo of a grocery receipt into the list of \
foods and drinks it shows, by calling record_grocery_foods. You only read; you never estimate \
calories, prices or amounts.

How to read the receipt:
- One entry per distinct food or drink a person eats or drinks. Expand the store's \
abbreviations into the words a person would say: "GRK YGRT PLN" is "plain Greek yogurt", \
"BNLS SKNLS CHKN BRST" is "chicken breast", "ORG BNNA" is "banana".
- Keep a brand only when it is part of what the food is ("Dave's Killer Bread", "Fairlife \
milk", "Chobani Greek yogurt"); otherwise name the food plainly.
- Leave out everything that is not food or drink: bags, paper goods, cleaning and personal \
care products, pet food, gift cards, deposits, coupons, discounts, tax, subtotals, totals, \
payment and card lines, the store's name, address and phone, dates and times.
- Leave out quantities, weights, sizes and prices. One entry per food even when it was bought \
several times.
- If the photo is not a receipt, or no food is legible, call the tool with an empty list."""


class ReceiptReader(Protocol):
    model: str

    async def read(self, image: bytes, media_type: str) -> list[str]: ...


class ReceiptUnreadableError(Exception):
    """The model answered without the tool, or with nothing usable."""


class ReceiptUnavailableError(Exception):
    """The reader could not be reached: a refusal for load (429, 529), a 5xx, a timeout, or a
    deployment with no key. The phone's try-again (503), never a 500 (2026-10-22 audit)."""


class AnthropicReceiptReader:
    """The vision model the photo parse uses, forced onto the names-only tool."""

    def __init__(self, client: Any | None = None, *, model: str | None = None, max_tokens: int = 1024) -> None:
        self.model = model or settings.photo_model
        self._max_tokens = max_tokens
        self._client = client
        # The SDK's error family, known once the SDK is loaded; an injected client (tests) keeps
        # the empty tuple, so its errors propagate as they are (assist/llm.py's rule).
        self._errors: tuple[type[BaseException], ...] = ()

    def _ensure_client(self) -> Any:
        if self._client is None:
            # The parser's lazily built SDK client: one import site, one place reading the key.
            self._client = AnthropicParserClient()._ensure_client()
            self._errors = (importlib.import_module("anthropic").APIError,)
        return self._client

    async def read(self, image: bytes, media_type: str) -> list[str]:
        content = [
            {
                "type": "image",
                "source": {"type": "base64", "media_type": media_type, "data": base64.b64encode(image).decode()},
            },
            {"type": "text", "text": "Read this receipt and call record_grocery_foods."},
        ]
        client = self._ensure_client()
        try:
            response = await client.messages.create(
                model=self.model,
                max_tokens=self._max_tokens,
                # A forced tool call and extended thinking do not mix (parser/photo.py learned it).
                thinking={"type": "disabled"},
                system=[{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}],
                tools=[TOOL_SCHEMA],
                tool_choice={"type": "tool", "name": TOOL_NAME},
                messages=[{"role": "user", "content": content}],
            )
        except self._errors as exc:
            raise ReceiptUnavailableError(type(exc).__name__) from exc
        for block in response.content:
            if getattr(block, "type", None) == "tool_use" and block.name == TOOL_NAME:
                return clean_names(dict(block.input).get("foods"))
        raise ReceiptUnreadableError("no record_grocery_foods call in the response")


class FakeReceiptReader:
    """Recorded answers (tests/fixtures/receipt_responses/default.json); zero network."""

    model = "fake-receipt"

    def __init__(self, foods: list[str] | None = None) -> None:
        self._foods = foods

    async def read(self, image: bytes, media_type: str) -> list[str]:
        del image, media_type
        if self._foods is not None:
            return clean_names([{"name": f} for f in self._foods])
        path = _RESPONSES_DIR / "default.json"
        if not path.exists():
            raise ReceiptUnreadableError("no recorded receipt response")
        return clean_names(json.loads(path.read_text()).get("tool_input", {}).get("foods"))


class UnavailableReceiptReader:
    """A hosted deployment with no key: the reader says it is unavailable."""

    model = "unavailable"

    async def read(self, image: bytes, media_type: str) -> list[str]:
        del image, media_type
        raise ReceiptUnavailableError("no model key in this deployment")


def get_receipt_reader() -> ReceiptReader:
    """The vision model with a key and outside the test suite. The recorded fake answers any
    photo with the same foods, so it serves only where recorded answers are allowed (the suite,
    a local stack): a hosted deployment missing its key handed every person the fixture's
    foods as if read from their receipt (2026-10-22 audit)."""
    if settings.test_mode:
        return FakeReceiptReader()
    if settings.anthropic_api_key:
        return AnthropicReceiptReader()
    return FakeReceiptReader() if recorded_answers_allowed() else UnavailableReceiptReader()


def clean_names(raw: Any) -> list[str]:
    """The tool's foods as plain names: trimmed, single-spaced, deduplicated ignoring case,
    capped; anything that is not a short string is dropped, never repaired."""
    out: list[str] = []
    seen: set[str] = set()
    for entry in raw if isinstance(raw, list) else []:
        name = entry.get("name") if isinstance(entry, dict) else None
        if not isinstance(name, str):
            continue
        name = " ".join(name.split())
        if not name or len(name) > _MAX_NAME:
            continue
        key = name.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(name)
        if len(out) >= MAX_FOODS:
            break
    return out
