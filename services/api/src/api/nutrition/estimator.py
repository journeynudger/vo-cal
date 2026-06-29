"""AI nutrition estimator — the FENCED fallback for foods not in the dictionary or FDC.

AGENTS.md non-negotiable #6 says the LLM never invents the numbers a user trusts. This is the
one deliberate, fenced exception (explicit product decision): when a food can't be resolved
deterministically, an estimate is FAR better than silently logging 0 kcal — provided it is
never presented as fact. So an estimate is always tagged ``source = ESTIMATED`` / ``is_estimate``,
carries a deliberately low confidence, and the UI flags it and invites a one-tap correction.

The estimator is an injected seam (Protocol): prod wires the Anthropic-backed one when a key is
configured; tests inject a fake; with neither, the resolver falls back to UNRESOLVED (zero, as
before) so the deterministic suite stays offline and pinned.
"""

from __future__ import annotations

import json
import logging
from typing import Any, Protocol

from ..parser.schemas import ParsedItem
from .schemas import Macros

_logger = logging.getLogger(__name__)


class NutritionEstimator(Protocol):
    """Estimate total grams + macros for one described item, or None if it can't."""

    async def estimate(self, item: ParsedItem) -> tuple[float, Macros] | None: ...


def _describe(item: ParsedItem) -> str:
    amount = f"{item.amount:g} " if item.amount else ""
    unit = f"{item.unit.value} " if item.unit else ""
    return f"{amount}{unit}{item.name}".strip()


class AnthropicNutritionEstimator:
    """Anthropic-backed estimate. Best-effort: any error/parse failure -> None (fall back to 0).

    Mirrors the parser's client construction (lazy SDK, key from settings). Forces a small JSON
    object of macros for the described portion; the deterministic engine still owns every
    resolved number — this only fills the otherwise-blank unresolved case.
    """

    def __init__(self, api_key: str, model: str = "claude-haiku-4-5-20251001") -> None:
        self._api_key = api_key
        self._model = model
        self._client: Any = None

    def _ensure_client(self) -> Any:
        if self._client is None:
            import anthropic  # noqa: PLC0415 — lazy, same as the parser client

            self._client = anthropic.AsyncAnthropic(api_key=self._api_key)
        return self._client

    async def estimate(self, item: ParsedItem) -> tuple[float, Macros] | None:
        prompt = (
            "Estimate the nutrition for this single food portion. Reply with ONLY a compact JSON "
            'object: {"grams": <number>, "kcal": <number>, "protein": <g>, "carbs": <g>, '
            '"fat": <g>, "fiber": <g>}. Use typical values for the portion described. '
            f"Portion: {_describe(item)}"
        )
        try:
            resp = await self._ensure_client().messages.create(
                model=self._model,
                max_tokens=200,
                messages=[{"role": "user", "content": prompt}],
            )
            text = "".join(b.text for b in resp.content if getattr(b, "type", "") == "text")
            data = json.loads(text[text.index("{") : text.rindex("}") + 1])
            grams = float(data["grams"])
            macros = Macros(
                kcal=float(data["kcal"]),
                protein=float(data["protein"]),
                carbs=float(data["carbs"]),
                fat=float(data["fat"]),
                fiber=float(data.get("fiber", 0.0)),
            )
            if grams <= 0 or macros.kcal <= 0:
                return None  # a zero estimate is no better than unresolved
            return grams, macros
        except Exception as exc:
            # Fallback must never raise into the resolve path — any failure degrades to None
            # (caller then falls back to UNRESOLVED). Broad by intent.
            _logger.warning("nutrition estimate failed for %r: %s", item.name, exc)
            return None


def make_estimator(api_key: str) -> NutritionEstimator | None:
    """Prod factory: an estimator only when an Anthropic key is configured, else None."""
    return AnthropicNutritionEstimator(api_key) if api_key else None
