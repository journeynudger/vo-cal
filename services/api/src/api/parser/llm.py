"""LLM parse step — transcript → ParsedMeal, schema-enforced, provider-injectable.

Two implementations of one interface (the Database-seam pattern, applied to the
LLM):

- ``AnthropicParserClient`` — real Anthropic SDK, tool-forced structured output
  against the B0 contract schema (``record_parsed_meal``). model =
  ``settings.parser_model``. Used in production and behind the ``live_llm``
  pytest marker.
- ``FakeParserClient`` — returns recorded tool outputs from
  ``tests/fixtures/llm_responses/*.json`` keyed by transcript. The entire
  offline suite + scripts/parser-eval run through this, with zero network. The
  recorded responses double as golden expectations.

Post-validation (B3 step 2): the raw tool input is parsed with the Pydantic
contract (``ParsedMeal``). On a schema mismatch we retry ONCE, appending the
validation error to the conversation so the model can self-correct. Empty-item
parses are rejected (a meal transcript yielding zero foods is a parse failure,
not a valid empty meal).

The LLM never produces calorie numbers (AGENTS.md #6) — only structure.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any, Protocol

from pydantic import ValidationError

from ..config import settings
from .prompts import (
    PROMPT_VERSION,
    SYSTEM_PROMPT,
    TOOL_NAME,
    TOOL_SCHEMA,
    build_messages,
)
from .schemas import ParsedMeal

logger = logging.getLogger(__name__)

_LLM_RESPONSES_DIR = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "llm_responses"


class ParseError(Exception):
    """The model could not produce a contract-valid, non-empty parse after retry."""


class ToolCallResult:
    """A single tool call's raw input + the prompt version that produced it."""

    def __init__(self, tool_input: dict[str, Any], *, model: str, prompt_version: str) -> None:
        self.tool_input = tool_input
        self.model = model
        self.prompt_version = prompt_version


class ParserClient(Protocol):
    """The seam: produce a tool-call result for a transcript (with optional retry feedback)."""

    model: str

    async def complete(
        self, transcript: str, *, retry_feedback: str | None = None
    ) -> ToolCallResult: ...


def _normalize_key(transcript: str) -> str:
    return " ".join(transcript.lower().split())


class FakeParserClient:
    """Returns recorded tool outputs keyed by transcript — the offline LLM.

    Responses live in tests/fixtures/llm_responses/*.json, each:
        {"transcript": "...", "model": "...", "tool_input": { ... }}
    Authored as realistic tool-output JSON, they are the golden expectations the
    corpus is scored against.
    """

    def __init__(
        self, responses: dict[str, dict[str, Any]] | None = None, *, model: str | None = None
    ) -> None:
        self.model = model or settings.parser_model
        self._responses = responses if responses is not None else self._load_recorded()

    @staticmethod
    def _load_recorded() -> dict[str, dict[str, Any]]:
        out: dict[str, dict[str, Any]] = {}
        if not _LLM_RESPONSES_DIR.exists():
            return out
        for path in sorted(_LLM_RESPONSES_DIR.glob("*.json")):
            data = json.loads(path.read_text())
            out[_normalize_key(data["transcript"])] = data
        return out

    async def complete(
        self, transcript: str, *, retry_feedback: str | None = None
    ) -> ToolCallResult:
        del retry_feedback  # recorded responses are already contract-valid
        data = self._responses.get(_normalize_key(transcript))
        if data is None:
            msg = (
                f"FakeParserClient has no recorded response for transcript {transcript!r}. "
                f"Add tests/fixtures/llm_responses/<slug>.json."
            )
            raise ParseError(msg)
        return ToolCallResult(
            tool_input=data["tool_input"],
            model=data.get("model", self.model),
            prompt_version=PROMPT_VERSION,
        )


class AnthropicParserClient:
    """Real Anthropic client — tool-forced structured output.

    The async SDK client is injectable for testing; production constructs it
    from settings.anthropic_api_key. tool_choice forces record_parsed_meal, so
    the model's only output path is the contract tool.
    """

    def __init__(
        self, client: Any | None = None, *, model: str | None = None, max_tokens: int = 2048
    ) -> None:
        self.model = model or settings.parser_model
        self._max_tokens = max_tokens
        self._client = client  # lazily built if None

    def _ensure_client(self) -> Any:
        if self._client is None:
            from anthropic import AsyncAnthropic  # noqa: PLC0415  (lazy heavy SDK)

            self._client = AsyncAnthropic(api_key=settings.anthropic_api_key)
        return self._client

    async def complete(
        self, transcript: str, *, retry_feedback: str | None = None
    ) -> ToolCallResult:
        messages = build_messages(transcript)
        if retry_feedback:
            messages.append(
                {
                    "role": "user",
                    "content": (
                        "Your previous tool call did not match the contract. "
                        f"Fix it and call {TOOL_NAME} again. Error:\n{retry_feedback}"
                    ),
                }
            )

        response = await self._ensure_client().messages.create(
            model=self.model,
            max_tokens=self._max_tokens,
            system=SYSTEM_PROMPT,
            tools=[TOOL_SCHEMA],
            tool_choice={"type": "tool", "name": TOOL_NAME},
            messages=messages,
        )

        for block in response.content:
            if getattr(block, "type", None) == "tool_use" and block.name == TOOL_NAME:
                return ToolCallResult(
                    tool_input=dict(block.input),
                    model=self.model,
                    prompt_version=PROMPT_VERSION,
                )
        msg = "Model response contained no record_parsed_meal tool call"
        raise ParseError(msg)


def _retry_user_text(transcript: str, retry_feedback: str | None) -> str:
    """Shared user-turn text for the OpenAI/Gemini clients (provider-neutral, no SDK blocks)."""
    if not retry_feedback:
        return transcript
    return (
        f"{transcript}\n\nYour previous tool call did not match the contract. "
        f"Fix it and call {TOOL_NAME} again. Error:\n{retry_feedback}"
    )


class OpenAIParserClient:
    """Real OpenAI client — function-calling forced to record_parsed_meal.

    Same contract as the Anthropic client: tool_choice pins the one function so the
    model's only output path is the B0 schema. The async SDK client is injectable;
    production builds it from settings.openai_api_key. Selected when
    PARSER_PROVIDER=openai (decision: third provider option alongside gemini/anthropic).
    """

    def __init__(
        self, client: Any | None = None, *, model: str | None = None, max_tokens: int = 2048
    ) -> None:
        self.model = model or settings.parser_model
        self._max_tokens = max_tokens
        self._client = client

    def _ensure_client(self) -> Any:
        if self._client is None:
            from openai import AsyncOpenAI  # noqa: PLC0415  (lazy heavy SDK)

            self._client = AsyncOpenAI(api_key=settings.openai_api_key)
        return self._client

    async def complete(
        self, transcript: str, *, retry_feedback: str | None = None
    ) -> ToolCallResult:
        tool = {
            "type": "function",
            "function": {
                "name": TOOL_NAME,
                "description": TOOL_SCHEMA.get("description", ""),
                "parameters": TOOL_SCHEMA["input_schema"],
            },
        }
        response = await self._ensure_client().chat.completions.create(
            model=self.model,
            max_tokens=self._max_tokens,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": _retry_user_text(transcript, retry_feedback)},
            ],
            tools=[tool],
            tool_choice={"type": "function", "function": {"name": TOOL_NAME}},
        )
        for call in response.choices[0].message.tool_calls or []:
            if call.function.name == TOOL_NAME:
                return ToolCallResult(
                    tool_input=json.loads(call.function.arguments),
                    model=self.model,
                    prompt_version=PROMPT_VERSION,
                )
        msg = "OpenAI response contained no record_parsed_meal tool call"
        raise ParseError(msg)


def _to_gemini_schema(node: Any) -> Any:
    """Adapt the B0 JSON-Schema contract to Gemini's FunctionDeclaration schema.

    Gemini's Schema type rejects three JSON-Schema idioms the Anthropic/OpenAI tool
    schemas accept (verified live 2026-06-23, ValidationError on FunctionDeclaration):
    nullable-as-type-union (``["number","null"]`` -> type "number" + ``nullable``),
    ``null`` inside an ``enum`` (-> drop it + ``nullable``), and ``additionalProperties``
    (unsupported -> drop). Everything else passes through unchanged, so the one contract
    still drives all three providers (AGENTS.md #6).
    """
    if isinstance(node, list):
        return [_to_gemini_schema(v) for v in node]
    if not isinstance(node, dict):
        return node
    out: dict[str, Any] = {}
    nullable = False
    for key, value in node.items():
        if key == "additionalProperties":
            continue
        if key == "type" and isinstance(value, list):
            non_null = [t for t in value if t != "null"]
            nullable = nullable or "null" in value
            out["type"] = non_null[0] if non_null else "string"
        elif key == "enum" and isinstance(value, list):
            nullable = nullable or any(v is None for v in value)
            out["enum"] = [v for v in value if v is not None]
        elif key == "properties" and isinstance(value, dict):
            # Recurse per-property so a property NAMED "type"/"enum" is never mistaken
            # for a schema keyword.
            out["properties"] = {k: _to_gemini_schema(v) for k, v in value.items()}
        else:
            out[key] = _to_gemini_schema(value)
    if nullable:
        out["nullable"] = True
    return out


class GeminiParserClient:
    """Real Gemini client (google-genai) — function-calling forced to record_parsed_meal.

    The free-tier default for the beta (PARSER_PROVIDER=gemini). FunctionCallingConfig
    mode=ANY with the single allowed name forces the contract function; the structured
    args come back on the function_call part. Client is injectable; production builds it
    from settings.gemini_api_key.
    """

    def __init__(self, client: Any | None = None, *, model: str | None = None) -> None:
        self.model = model or settings.parser_model
        self._client = client

    def _ensure_client(self) -> Any:
        if self._client is None:
            from google import genai  # noqa: PLC0415  (lazy heavy SDK)

            self._client = genai.Client(api_key=settings.gemini_api_key)
        return self._client

    async def complete(
        self, transcript: str, *, retry_feedback: str | None = None
    ) -> ToolCallResult:
        from google.genai import types  # noqa: PLC0415

        fn = types.FunctionDeclaration(
            name=TOOL_NAME,
            description=TOOL_SCHEMA.get("description", ""),
            parameters=_to_gemini_schema(TOOL_SCHEMA["input_schema"]),
        )
        config = types.GenerateContentConfig(
            system_instruction=SYSTEM_PROMPT,
            tools=[types.Tool(function_declarations=[fn])],
            tool_config=types.ToolConfig(
                function_calling_config=types.FunctionCallingConfig(
                    mode="ANY", allowed_function_names=[TOOL_NAME]
                )
            ),
        )
        response = await self._ensure_client().aio.models.generate_content(
            model=self.model,
            contents=_retry_user_text(transcript, retry_feedback),
            config=config,
        )
        for candidate in response.candidates or []:
            for part in getattr(candidate.content, "parts", None) or []:
                call = getattr(part, "function_call", None)
                if call and call.name == TOOL_NAME:
                    return ToolCallResult(
                        tool_input=dict(call.args),
                        model=self.model,
                        prompt_version=PROMPT_VERSION,
                    )
        msg = "Gemini response contained no record_parsed_meal tool call"
        raise ParseError(msg)


async def parse_transcript(client: ParserClient, transcript: str) -> tuple[ParsedMeal, str, str]:
    """Parse a transcript into a validated ParsedMeal.

    Returns (meal, model, prompt_version). Validates the tool output against the
    Pydantic contract; on a schema error, retries ONCE with the error appended.
    Rejects empty-item parses (raises ParseError).
    """
    result = await client.complete(transcript)
    meal, error = _validate(result.tool_input)
    if meal is None:
        feedback = error or "Output failed schema validation."
        logger.info("Parse retry for %r: %s", transcript, feedback)
        result = await client.complete(transcript, retry_feedback=feedback)
        meal, error = _validate(result.tool_input)
        if meal is None:
            raise ParseError(error or "schema validation failed after retry")

    if not meal.items:
        msg = f"Parse produced zero items for transcript {transcript!r}"
        raise ParseError(msg)

    return meal, result.model, result.prompt_version


def _validate(tool_input: dict[str, Any]) -> tuple[ParsedMeal | None, str | None]:
    """Validate raw tool input against the contract. Returns (meal, error_json)."""
    try:
        meal = ParsedMeal.model_validate(tool_input)
    except ValidationError as exc:
        return None, json.dumps(exc.errors(include_url=False, include_input=False))
    return meal, None
