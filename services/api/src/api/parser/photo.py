"""A photographed meal: the model identifies, the ladder prices, the blind spots become checks.

Requirement (Lorenzo, 2026-09-24): snapping a picture should give the most accurate
calories a photo can, clearly better than the usual calorie apps, and it should ask what a
photo cannot show ("Is there sauce on this burger?"). Two things make that true here:

1. The model only EXTRACTS (AGENTS.md #6). It is forced onto the same ``record_parsed_meal``
   tool as a transcript: names, amounts read off visual cues, states, brands when a label is
   in frame, and ``missing_details``. Every number then comes from the deterministic ladder
   (dictionary, FatSecret, the estimator, USDA), the same way a spoken meal is priced, so a
   photo and a voice note of the same plate land on the same numbers.
2. What a photo cannot see is asked, never guessed silently: sauces and dressings, oil or
   butter in the pan, sugar in a drink, a layer under another. The model lists each as an
   item with its usual amount and low confidence plus an amount question whose first option
   is "None"; answering None removes it (parser/clarify.py absence_index), an amount keeps
   it at that amount.

The photo is a capture (AGENTS.md #5): the bytes land in the private capture-photos bucket
and a ``captures`` row before the model is paid, exactly like audio.
"""

from __future__ import annotations

import base64
import json
import logging
from pathlib import Path
from typing import Any, Protocol

from ..config import settings
from .llm import AnthropicParserClient, ParseError, ToolCallResult, _validate
from .prompts import TOOL_NAME, TOOL_SCHEMA
from .schemas import ParsedMeal

logger = logging.getLogger(__name__)

PHOTO_PROMPT_VERSION = "vocal-photo-2026-09-25.1"

_PHOTO_RESPONSES_DIR = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "photo_responses"

MAX_PHOTO_BYTES = 8 * 1024 * 1024
ALLOWED_MEDIA_TYPES = frozenset({"image/jpeg", "image/png"})

PHOTO_SYSTEM_PROMPT = """\
You are Vo-Cal's meal photo reader. You turn a photo of what someone is about to eat (or \
just ate) into structured food items by calling record_parsed_meal. You extract structure \
ONLY; you never invent calorie or macro numbers. Deterministic code prices every item from \
its name, amount, unit and state.

How to read the photo:
- List every distinct food and drink you can see, one item each. Name each the way a person \
would say it ("grilled chicken breast", "white rice", "sesame bun", "french fries", "black \
coffee"). If a brand or product label is legible, put the brand in "brand" and the product \
in "name".
- Estimate the amount from what is in frame: a dinner plate is about 27 cm across, a side \
plate 20 cm, a fork 18 cm long, a standard mug 300 ml, a 12 oz can, a tall glass 350 ml. \
Give grams for solids you can size ("g"), ml for drinks, or a count with "piece" or "slice" \
for things eaten in pieces (eggs, slices of bread, wings). Say "cup" or "tbsp" only when a \
measuring cup or spoon is visible.
- Set "state" to cooked, raw or ready as it appears; note the cooking method in \
"prep_method" when it is visible (grilled marks, deep-fried batter, breaded).
- Confidence is how sure you are the item is what you named it: 0.9 for a clear plain food, \
0.6 for a covered or partly hidden one, 0.4 to 0.5 for something you infer rather than see.

What a photo cannot show, ask, never guess silently. For each likely hidden calorie source \
that you cannot confirm from the image, add it as its OWN item with its usual amount and a \
confidence of 0.4 to 0.5, and add a missing_details entry for that item with:
  field "items[N].amount", importance "high", a short question naming what you see \
("Is there sauce on the burger?", "Was the chicken cooked in oil or butter?", "Is the \
drink sweetened?"), and options starting with "None" then three amounts, for example \
["None", "1 tsp", "1 tbsp", "2 tbsp"] for a sauce or oil, or ["None", "1 tsp sugar", "2 tsp \
sugar", "Regular soda"] for a drink.
Typical hidden sources: mayonnaise or a burger sauce inside a bun; dressing on a salad; oil \
or butter a protein or vegetables were cooked in; syrup or sugar in a coffee or tea; cheese \
melted under a topping; a second layer under visible food. Do not ask about what you can \
plainly see, and never add more than three such questions.

Also use missing_details for a material axis the photo leaves open: the fat ratio of \
visible ground beef ("items[N].fat_ratio"), whether rice is a half cup or a full cup when \
the plate makes the amount ambiguous ("items[N].amount" with importance "medium").

If the person typed a note with the photo, the note is authoritative: use its names and \
amounts over your reading, and do not ask what the note already answers. If the image is \
not food, call the tool with an empty items list."""


class PhotoParserClient(Protocol):
    """The seam: a tool call for a photo, with optional retry feedback."""

    model: str

    async def complete(
        self, image: bytes, media_type: str, note: str | None, *, retry_feedback: str | None = None
    ) -> ToolCallResult: ...


def _user_text(note: str | None, retry_feedback: str | None) -> str:
    parts = ["Read this meal photo and call record_parsed_meal."]
    if note and note.strip():
        parts.append(f"The person's note: {note.strip()}")
    if retry_feedback:
        parts.append(
            "Your previous tool call did not match the contract. "
            f"Fix it and call {TOOL_NAME} again. Error:\n{retry_feedback}"
        )
    return "\n\n".join(parts)


class AnthropicPhotoParserClient:
    """The vision model, tool-forced onto the transcript contract."""

    def __init__(self, client: Any | None = None, *, model: str | None = None, max_tokens: int = 2048) -> None:
        self.model = model or settings.photo_model
        self._max_tokens = max_tokens
        self._client = client

    def _ensure_client(self) -> Any:
        if self._client is None:
            # The same lazily built SDK client the transcript parser uses: one import site
            # for the heavy SDK, one place that reads the key.
            self._client = AnthropicParserClient()._ensure_client()
        return self._client

    async def complete(
        self, image: bytes, media_type: str, note: str | None, *, retry_feedback: str | None = None
    ) -> ToolCallResult:
        content = [
            {
                "type": "image",
                "source": {"type": "base64", "media_type": media_type, "data": base64.b64encode(image).decode()},
            },
            {"type": "text", "text": _user_text(note, retry_feedback)},
        ]
        response = await self._ensure_client().messages.create(
            model=self.model,
            max_tokens=self._max_tokens,
            # A forced tool call and extended thinking do not mix, and the Sonnet 5 family
            # thinks by default (the estimator learned this live, 2026-07): say so.
            thinking={"type": "disabled"},
            system=[{"type": "text", "text": PHOTO_SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}],
            tools=[TOOL_SCHEMA],
            tool_choice={"type": "tool", "name": TOOL_NAME},
            messages=[{"role": "user", "content": content}],
        )
        for block in response.content:
            if getattr(block, "type", None) == "tool_use" and block.name == TOOL_NAME:
                return ToolCallResult(tool_input=dict(block.input), model=self.model, prompt_version=PHOTO_PROMPT_VERSION)
        msg = "Model response contained no record_parsed_meal tool call"
        raise ParseError(msg)


class FakePhotoParserClient:
    """Recorded tool outputs for photos, keyed by the note (tests/fixtures/photo_responses):
    an image's bytes cannot key a fixture, so ``default.json`` answers any photo without a
    matching note. Zero network."""

    model = "fake-photo"

    def __init__(self, responses: dict[str, dict[str, Any]] | None = None) -> None:
        self._responses = responses if responses is not None else self._load_recorded()

    @staticmethod
    def _load_recorded() -> dict[str, dict[str, Any]]:
        out: dict[str, dict[str, Any]] = {}
        for path in sorted(_PHOTO_RESPONSES_DIR.glob("*.json")):
            data = json.loads(path.read_text())
            key = " ".join(str(data.get("note") or "").lower().split()) or "default"
            out[key] = data
        return out

    async def complete(
        self, image: bytes, media_type: str, note: str | None, *, retry_feedback: str | None = None
    ) -> ToolCallResult:
        del image, media_type, retry_feedback
        key = " ".join((note or "").lower().split())
        data = self._responses.get(key) or self._responses.get("default")
        if data is None:
            msg = "No recorded photo response (add tests/fixtures/photo_responses/default.json)"
            raise ParseError(msg)
        return ToolCallResult(tool_input=data["tool_input"], model=self.model, prompt_version=PHOTO_PROMPT_VERSION)


def get_photo_client() -> PhotoParserClient:
    """The vision model when an Anthropic key is configured and the suite is not offline;
    the recorded fake otherwise (mirrors parser/router.py get_parser_client)."""
    if settings.test_mode or not settings.anthropic_api_key:
        return FakePhotoParserClient()
    return AnthropicPhotoParserClient()


async def parse_photo(
    client: PhotoParserClient, image: bytes, media_type: str, note: str | None
) -> tuple[ParsedMeal, str, str]:
    """A validated ParsedMeal from a photo, with the same two feedback retries as a
    transcript (llm.parse_transcript). Empty items is a ParseError: nothing to price."""
    result = await client.complete(image, media_type, note)
    meal, error = _validate(result.tool_input)
    for _attempt in range(2):
        if meal is not None:
            break
        feedback = error or "Output failed schema validation."
        logger.info("Photo parse failed schema validation; retrying (bytes=%d)", len(image))
        result = await client.complete(image, media_type, note, retry_feedback=feedback)
        meal, error = _validate(result.tool_input)
    if meal is None:
        raise ParseError(error or "schema validation failed after retries")
    if not meal.items:
        msg = "No food in this photo"
        raise ParseError(msg)
    return meal, result.model, result.prompt_version


def looks_like_image(data: bytes, media_type: str) -> bool:
    """The bytes carry the magic of the declared type: a mislabelled upload is refused before
    it is stored or paid for."""
    if media_type == "image/jpeg":
        return data[:3] == b"\xff\xd8\xff"
    if media_type == "image/png":
        return data[:8] == b"\x89PNG\r\n\x1a\n"
    return False
