"""AI nutrition estimator — the informed fallback when deterministic sources can't answer.

AGENTS.md non-negotiable #6 says the LLM never invents the numbers a user trusts. This is
the one deliberate, fenced exception (explicit product decision, widened 2026-07): the AI
knows what an espresso is and what a Chobani 30g-protein drink's label says — refusing to
use that knowledge produced the app's worst accuracy failures (branded items priced as
wrong generics; "baby bell" cheeses guessed blind; four phrasings of the same drink giving
four answers). The rules that keep #6 honest:

  1. The AI describes the FOOD, not the portion: it returns a per-100g profile +
     serving/unit grams ONCE; deterministic local code computes every portion from it
     (same math as a dictionary entry). No per-log number invention.
  2. Every estimate is validated for plausibility (Atwater: kcal ≈ 4P+4C+9F) and bounds —
     an implausible answer is declined, never logged.
  3. Estimates are cached durably by food identity (usda_cache, ``est:`` keys), so the
     same food resolves to the SAME numbers on every log, forever, for every user.
  4. Results stay flagged ``is_estimate`` so the UI can invite a correction. A branded
     estimate (the user read the label; the model knows the product) is an INFORMED
     read and carries higher confidence than a brand-less unknown.

The estimator is an injected seam (Protocol): prod wires the Anthropic-backed one when a
key is configured; tests inject a fake; with neither, the resolver falls back to the
deterministic path unchanged.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from typing import Any, Protocol

from ..parser.schemas import ParsedItem
from .schemas import NutrientProfile

_logger = logging.getLogger(__name__)

# Plausibility fences (rule 2). Atwater tolerance is generous — labels round and fiber
# complicates the identity — but catches unit confusion and hallucinated magnitudes.
_ATWATER_TOLERANCE = 0.35
_MAX_KCAL_PER_100G = 950.0  # pure fat is ~900
_MIN_SERVING_GRAMS, _MAX_SERVING_GRAMS = 1.0, 2000.0


@dataclass(frozen=True)
class FoodSource:
    """One web source a grounded estimate was read from — shown to the user (trust UX)."""

    url: str
    title: str


@dataclass(frozen=True)
class EstimatedFood:
    """The AI's one-time description of a food's identity — portions are computed locally."""

    per_100g: NutrientProfile
    serving_grams: float
    # Food-specific unit conversions (grams per piece/slice/scoop, grams per ml), same
    # shape as a dictionary entry's — so "2 babybels" or "300 ml" price deterministically.
    unit_conversions: dict[str, float] = field(default_factory=dict)
    # Web sources the numbers were grounded in (empty for knowledge-only estimates).
    sources: tuple[FoodSource, ...] = ()


class NutritionEstimator(Protocol):
    """Describe one food's nutrition identity, or None if it can't be done plausibly."""

    async def estimate(self, item: ParsedItem) -> EstimatedFood | None: ...


def describe_food(item: ParsedItem) -> str:
    """The food's full identity for the model — brand/variant/prep INCLUDED.

    Dropping the brand was a field bug (2026-07): 'Babybel light cheese' reached the
    model as 'light cheese' and got generic-cheese numbers. Amounts are deliberately
    EXCLUDED — the estimate describes the food per-100g; portions are computed locally.
    """
    parts = [item.brand, item.variant, item.prep_method, item.fat_ratio, item.name]
    return " ".join(str(p) for p in parts if p).strip()


def estimate_cache_key(item: ParsedItem) -> str:
    """Durable cache key for a food identity (rule 3). ``est:`` prefix keeps these rows
    disjoint from FDC keys in usda_cache (FDC keys are normalized bare terms; ':' never
    survives its normalizer)."""
    norm = re.sub(r"[^a-z0-9 ]+", " ", describe_food(item).lower())
    return "est:" + re.sub(r"\s+", " ", norm).strip()


def validate_estimate(data: dict[str, Any]) -> EstimatedFood | None:
    """Parse + plausibility-check a raw model reply. None = decline (fall through)."""
    try:
        per = data["per_100g"]
        profile = NutrientProfile(
            kcal=float(per["kcal"]),
            protein=float(per["protein"]),
            carbs=float(per["carbs"]),
            fat=float(per["fat"]),
            fiber=float(per.get("fiber", 0.0)),
        )
        serving = float(data["serving_grams"])
        conversions = {
            str(k): float(v)
            for k, v in (data.get("unit_conversions") or {}).items()
            if isinstance(v, int | float) and float(v) > 0
        }
    except (KeyError, TypeError, ValueError) as exc:
        _logger.warning("estimate reply malformed: %s", exc)
        return None

    if not (_MIN_SERVING_GRAMS <= serving <= _MAX_SERVING_GRAMS):
        return None
    if not (0 < profile.kcal <= _MAX_KCAL_PER_100G):
        return None
    if min(profile.protein, profile.carbs, profile.fat, profile.fiber) < 0:
        return None
    # Atwater identity: reported kcal must be consistent with the macros.
    atwater = 4 * profile.protein + 4 * profile.carbs + 9 * profile.fat
    if atwater > 0 and abs(profile.kcal - atwater) > _ATWATER_TOLERANCE * max(profile.kcal, atwater):
        _logger.warning("estimate failed Atwater check: kcal=%s vs 4/4/9=%s", profile.kcal, atwater)
        return None
    return EstimatedFood(per_100g=profile, serving_grams=serving, unit_conversions=conversions)


_PROMPT = """\
You are a nutrition database. Describe this food's nutrition identity. If it is a branded \
or packaged product you recognize, use its actual label values — that is the whole point. \
The description may itself quote label facts (e.g. "30g protein", "zero added sugar", \
"50 calorie"): treat those as ground truth for ONE serving and make your per-100g values \
consistent with them. For generic foods use typical values. serving_grams is one typical \
serving (for a packaged product: the package/unit the label describes). In unit_conversions, \
include only the units that make sense for this food (grams per piece/slice/scoop, grams \
per ml); leave the rest null.
Food: {food}"""

# Structured output schema (output_config.format): the reply is guaranteed-valid JSON —
# no string scraping. unit_conversions uses explicit optional keys because the schema
# grammar requires additionalProperties: false (no open maps).
_OUTPUT_SCHEMA = {
    "type": "json_schema",
    "schema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["per_100g", "serving_grams", "unit_conversions"],
        "properties": {
            "per_100g": {
                "type": "object",
                "additionalProperties": False,
                "required": ["kcal", "protein", "carbs", "fat", "fiber"],
                "properties": {
                    "kcal": {"type": "number"},
                    "protein": {"type": "number"},
                    "carbs": {"type": "number"},
                    "fat": {"type": "number"},
                    "fiber": {"type": "number"},
                },
            },
            "serving_grams": {"type": "number"},
            "unit_conversions": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "piece": {"type": ["number", "null"]},
                    "slice": {"type": ["number", "null"]},
                    "scoop": {"type": ["number", "null"]},
                    "cup": {"type": ["number", "null"]},
                    "tbsp": {"type": ["number", "null"]},
                    "ml": {"type": ["number", "null"]},
                },
            },
        },
    },
}


class AnthropicNutritionEstimator:
    """Anthropic-backed food identity. Best-effort: any error/implausible reply -> None."""

    def __init__(self, api_key: str, model: str = "claude-sonnet-5") -> None:
        # Sonnet, not haiku: resolution accuracy IS the product (field complaints 2026-07),
        # and rule 3's durable cache means each food identity is paid for exactly once.
        self._api_key = api_key
        self._model = model
        self._client: Any = None

    def _ensure_client(self) -> Any:
        if self._client is None:
            import anthropic  # noqa: PLC0415 — lazy, same as the parser client

            self._client = anthropic.AsyncAnthropic(api_key=self._api_key)
        return self._client

    async def estimate(self, item: ParsedItem) -> EstimatedFood | None:
        try:
            # thinking disabled + structured output: this is a recall lookup, not reasoning —
            # sonnet-5 defaults to adaptive thinking, which burned the whole token budget
            # inside an (empty-by-default) thinking block and returned no text (live-verified
            # 2026-07). No sampling params: sonnet-5 rejects them (400). Cross-call
            # consistency comes from the durable cache (rule 3), not sampling.
            resp = await self._ensure_client().messages.create(
                model=self._model,
                max_tokens=500,
                thinking={"type": "disabled"},
                output_config={"format": _OUTPUT_SCHEMA},
                messages=[{"role": "user", "content": _PROMPT.format(food=describe_food(item))}],
            )
            text = next(b.text for b in resp.content if getattr(b, "type", "") == "text")
            data = json.loads(text)
        except Exception as exc:
            # Fallback must never raise into the resolve path. Broad by intent.
            _logger.warning("nutrition estimate failed for %r: %s", item.name, exc)
            return None
        return validate_estimate(data)


_GROUNDED_PROMPT = """\
Look up this food's nutrition facts on the web (the brand's own site, USDA, retailer or \
nutrition databases). Prefer the official label. Then reply with ONLY compact JSON on one \
line, using the label values you found for ONE serving and per-100g:
{{"per_100g": {{"kcal": n, "protein": g, "carbs": g, "fat": g, "fiber": g}}, \
"serving_grams": n, "unit_conversions": {{"piece": g_or_null, "slice": g_or_null, \
"ml": g_or_null}}}}
The description may itself quote label facts (e.g. "23g protein"): treat those as ground \
truth and use them to pick the RIGHT product among variants.
Food: {food}"""


class WebGroundedEstimator:
    """Haiku + web search: the cheapest model that can READ the label off the internet.

    Requirement (field report 2026-07): "Oikos 23g protein smoothie" — heard as "oil
    coast" — returned NOTHING; the fix bar is 'anything searchable on the internet must
    resolve, best-guess, with the sources shown'. Haiku is deliberate (cheapest capable:
    ~$0.005 tokens + ~$0.01-0.03 search per NOVEL food, then cached durably forever by
    CachedEstimator — amortized ≈ zero). Sources are extracted from the search tool's
    result blocks (never model-claimed), deduped, capped at 4 for the UI row.

    Any failure (tool unavailable, implausible reply) falls through to the knowledge-only
    estimator — never to a blank result.
    """

    def __init__(
        self,
        api_key: str,
        fallback: NutritionEstimator | None = None,
        model: str = "claude-haiku-4-5",
    ) -> None:
        self._api_key = api_key
        self._fallback = fallback
        self._model = model
        self._client: Any = None

    def _ensure_client(self) -> Any:
        if self._client is None:
            import anthropic  # noqa: PLC0415 — lazy, same as the parser client

            self._client = anthropic.AsyncAnthropic(api_key=self._api_key)
        return self._client

    async def estimate(self, item: ParsedItem) -> EstimatedFood | None:
        result = await self._grounded(item)
        if result is not None:
            return result
        return await self._fallback.estimate(item) if self._fallback else None

    async def _grounded(self, item: ParsedItem) -> EstimatedFood | None:
        try:
            resp = await self._ensure_client().messages.create(
                model=self._model,
                max_tokens=1500,  # search-result blocks + the JSON line
                tools=[{"type": "web_search_20250305", "name": "web_search", "max_uses": 3}],
                messages=[
                    {"role": "user", "content": _GROUNDED_PROMPT.format(food=describe_food(item))}
                ],
            )
            text = "".join(b.text for b in resp.content if getattr(b, "type", "") == "text")
            data = json.loads(text[text.index("{") : text.rindex("}") + 1])
        except Exception as exc:
            _logger.warning("grounded estimate failed for %r: %s", item.name, exc)
            return None
        est = validate_estimate(data)
        if est is None:
            return None
        return EstimatedFood(
            per_100g=est.per_100g,
            serving_grams=est.serving_grams,
            unit_conversions=est.unit_conversions,
            sources=_extract_sources(resp.content),
        )


def _extract_sources(blocks: list) -> tuple[FoodSource, ...]:
    """Deterministic source list from web_search tool-result blocks (url+title), deduped by
    domain-ish url, capped at 4. Error results ('content' is an object) yield nothing."""
    out: list[FoodSource] = []
    seen: set[str] = set()
    for block in blocks:
        if getattr(block, "type", "") != "web_search_tool_result":
            continue
        content = getattr(block, "content", None)
        if not isinstance(content, list):
            continue  # error object, not results
        for r in content:
            url = getattr(r, "url", None)
            if not url or url in seen:
                continue
            seen.add(url)
            out.append(FoodSource(url=url, title=str(getattr(r, "title", "") or "")[:120]))
            if len(out) >= 4:
                return tuple(out)
    return tuple(out)


class CachedEstimator:
    """Durable write-through cache around any estimator (rule 3): usda_cache, ``est:`` keys.

    Same food identity -> same numbers on every log ("I drink this every morning" must not
    price differently per day), and one paid model call per food ever, across all users.
    Corrupt cache rows are misses, never 500s (mirrors the FDC cache posture).
    """

    def __init__(self, db: Any, inner: NutritionEstimator) -> None:
        self._db = db
        self._inner = inner

    async def estimate(self, item: ParsedItem) -> EstimatedFood | None:
        key = estimate_cache_key(item)
        rows = await self._db.select("usda_cache", {"query_key": key})
        if rows:
            payload = rows[0].get("profile") or {}
            try:
                return EstimatedFood(
                    per_100g=NutrientProfile(**payload["per_100g"]),
                    serving_grams=float(payload["serving_grams"]),
                    unit_conversions={
                        str(k): float(v) for k, v in (payload.get("unit_conversions") or {}).items()
                    },
                    sources=tuple(
                        FoodSource(url=str(s.get("url", "")), title=str(s.get("title", "")))
                        for s in (payload.get("sources") or [])
                        if s.get("url")
                    ),
                )
            except (KeyError, TypeError, ValueError) as exc:
                _logger.warning("estimate cache row corrupt for %r (%s) — miss", key, exc)

        result = await self._inner.estimate(item)
        if result is not None:
            await self._db.insert(
                "usda_cache",
                {
                    "query_key": key,
                    "fdc_id": None,
                    "profile": {
                        "per_100g": result.per_100g.model_dump(),
                        "serving_grams": result.serving_grams,
                        "unit_conversions": result.unit_conversions,
                        "sources": [{"url": s.url, "title": s.title} for s in result.sources],
                    },
                },
            )
        return result


def make_estimator(api_key: str, db: Any = None) -> NutritionEstimator | None:
    """Prod factory: an estimator only when an Anthropic key is configured, else None.

    The chain, cheapest-capable first: durable cache -> web-grounded haiku (reads the
    actual label off the internet, returns sources) -> knowledge-only sonnet (no search
    needed/available) -> caller falls through to the deterministic path.
    """
    if not api_key:
        return None
    inner = WebGroundedEstimator(api_key, fallback=AnthropicNutritionEstimator(api_key))
    return CachedEstimator(db, inner) if db is not None else inner
