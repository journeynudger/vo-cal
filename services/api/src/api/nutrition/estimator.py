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
  2. Every estimate is validated for plausibility (Atwater: kcal ≈ 4P+4C+9F), bounds, and
     serving-basis consistency (the label's kcal_per_serving must match per_100g x
     serving_grams — a reply that echoes the per-100g basis as "one serving" prices a
     whole sandwich at its per-100g row). An implausible answer is declined, never logged.
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

import hashlib
import json
import logging
import re
from dataclasses import dataclass, field
from typing import Any, Protocol

from ..db import UniqueViolationError
from ..parser.schemas import ParsedItem
from .schemas import NutrientProfile
from .sources import domains_for

_logger = logging.getLogger(__name__)


def food_ref(name: str) -> str:
    """Privacy-safe log handle for a food name (MUST-NOT #5: names are user content).

    A short stable digest keeps repeat failures on the same food correlatable in logs
    without ever writing the name itself.
    """
    return hashlib.blake2s(name.strip().lower().encode(), digest_size=4).hexdigest()

# Bump when the estimate shape/quality rules change so the durable cache invalidates
# stale rows on READ (a food logged before a fix re-estimates instead of serving the
# old numbers forever). Rows without this field are treated as version 0.
# v3 (2026-07-16): grounded prompt gained the per-piece hardening; per-piece weights
# capped relative to serving; ml fenced as a density — pre-v3 conversions can be poisoned.
# v4 (2026-07-19): serving-basis integrity — kcal_per_serving redundancy required and
# cross-checked against per_100g x serving_grams; grounded serving_grams == 100.0
# declined as a per-100g basis echo. Pre-v4 rows can carry a 100 g "serving" that
# prices a whole sandwich as its per-100g row (the 234-kcal Big Mac shape).
# v5 (2026-07-30): grounded lane un-truncated (search budget + JSON follow-up — sources
# actually populate); homemade-vs-restaurant serving bands + WHOLE-item rule; ml density
# fence. Pre-v5 rows can carry sliceless-pizza/triple-decker-sandwich servings.
ESTIMATOR_VERSION = 5

# Plausibility fences (rule 2). Atwater tolerance is generous — labels round and fiber
# complicates the identity — but catches unit confusion and hallucinated magnitudes.
_ATWATER_TOLERANCE = 0.35
_MAX_KCAL_PER_100G = 950.0  # pure fat is ~900
_MIN_SERVING_GRAMS, _MAX_SERVING_GRAMS = 1.0, 2000.0
# A single discrete piece/slice/scoop is rarely heavier than this; a larger "per-piece"
# weight is the model confusing a serving (or a package) for a piece — drop it so the
# count-unit safety net in to_grams engages instead of ballooning the portion.
_MAX_PER_UNIT_GRAMS = 300.0
# ...and a piece is also rarely heavier than ~2 servings: a "slice" of 150 g against a
# 30 g serving is a serving/package misread, not a slice (the absolute cap alone let a
# ~100-150 g bogus slice through — exactly the 736-kcal turkey-bacon shape).
_MAX_PER_UNIT_VS_SERVING = 2.0
# ml is a DENSITY (grams per ml), not a piece weight: foods sit between light foams and
# dense syrups. A model echoing serving grams into ml (240 "g per ml") priced 350 ml at
# 84 kg — fence it to a physical band and let the 1.0 default carry the rest.
_MIN_ML_DENSITY, _MAX_ML_DENSITY = 0.2, 2.0
# kcal_per_serving is a REDUNDANT label read: the label's calories for one serving. It
# must agree with per_100g.kcal x serving_grams / 100 or the reply mixed bases (read the
# per-serving calories but echoed the per-100g weight, or vice versa) — the mixed-basis
# misread is exactly how a ~590 kcal sandwich gets cached at a 100 g "serving" and
# poisons every user's log for that food (shared durable cache). Same generous 0.35
# band as Atwater: labels round, but a basis swap is a 2-6x miss and always trips it.
_SERVING_KCAL_TOLERANCE = 0.35


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
    # The label's calories for ONE serving, as the model reported it — redundancy kept
    # for the basis cross-check (validate_estimate) and re-checked on cache read. Never
    # used for portion math (per_100g x grams stays the single pricing basis).
    kcal_per_serving: float | None = None


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
        kcal_per_serving = float(data["kcal_per_serving"])
        # Drop implausible per-unit weights — a "piece" heavier than 300 g OR ~2 servings
        # is the model confusing a serving/package for a piece, which is exactly what
        # balloons "N pieces of turkey bacon" (field bugs 2026-07). ml is a DENSITY and
        # gets its own physical band. A dropped conversion routes the count through
        # to_grams' one-serving safety net instead.
        per_unit_cap = min(_MAX_PER_UNIT_GRAMS, _MAX_PER_UNIT_VS_SERVING * serving)
        conversions: dict[str, float] = {}
        for k, v in (data.get("unit_conversions") or {}).items():
            if not isinstance(v, int | float):
                continue
            value = float(v)
            cap_ok = (
                _MIN_ML_DENSITY <= value <= _MAX_ML_DENSITY
                if str(k) == "ml"
                else 0 < value <= per_unit_cap
            )
            if cap_ok:
                conversions[str(k)] = value
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
    # Serving-basis identity: the label's per-serving calories must equal what our own
    # portion math will produce for one serving. A mismatch means the reply mixed bases
    # (per-serving calories with a per-100g weight, or vice versa) — decline rather than
    # durably cache a serving that prices a whole item as its per-100g row.
    serving_kcal = profile.kcal * serving / 100.0
    if kcal_per_serving <= 0:
        return None
    if abs(kcal_per_serving - serving_kcal) > _SERVING_KCAL_TOLERANCE * max(
        kcal_per_serving, serving_kcal
    ):
        _logger.warning(
            "estimate failed serving-basis check: kcal_per_serving=%s vs per_100g x serving=%s",
            kcal_per_serving,
            round(serving_kcal, 1),
        )
        return None
    return EstimatedFood(
        per_100g=profile,
        serving_grams=serving,
        unit_conversions=conversions,
        kcal_per_serving=kcal_per_serving,
    )


_PROMPT = """\
You are a nutrition database. Describe this food's nutrition identity. If it is a branded \
or packaged product you recognize, use its actual label values — that is the whole point. \
The description may itself quote label facts (e.g. "30g protein", "zero added sugar", \
"50 calorie"): treat those as ground truth for ONE serving and make your per-100g values \
consistent with them. For generic foods use typical values. serving_grams is one typical \
serving AS EATEN (for a packaged product: the package/unit the label describes; for a \
restaurant or menu item: the WHOLE item as sold — a whole sandwich, burger, bowl, can or \
bottle, often 200-500 g; for a HOMEMADE single-serving item — a pb&j, a bowl of cereal, \
two slices of toast — the normal single portion, usually 100-250 g: never inflate a home \
sandwich to restaurant weight). If the description says WHOLE pizza/pie/pint, \
serving_grams is the ENTIRE item (a whole 12-inch pizza is ~500-850 g), not one slice. \
NEVER report 100 as serving_grams just because nutrition data \
is listed per 100 g — 100 is the reporting basis, not a serving. kcal_per_serving is the \
calories in that one serving (for a Big Mac: the whole sandwich's calories, not per-100g). \
In unit_conversions, include only the units that make sense for this food (grams per \
piece/slice/scoop, grams per ml); leave the rest null. CRITICAL: if the food is eaten in \
discrete pieces — bacon or turkey-bacon slices, eggs, chicken nuggets/tenders, cookies, \
crackers, shrimp, meatballs, slices of bread or pizza — you MUST fill the matching \
piece/slice weight, because users log "3 pieces". Use the real weight of THIS food's \
piece: small pieces (crackers, nuggets, bacon) run 5-30 g, mid pieces (eggs, cookies, \
bread slices) 25-60 g, and large pieces (a slice of a 14-inch pizza, a pancake, a \
sausage link) 70-140 g — never anchor a pizza slice at bread-slice weight. NEVER \
more than 300 g; serving_grams is one serving and may equal several pieces, so do not \
reuse it as the per-piece weight.
Food: {food}"""

# Structured output schema (output_config.format): the reply is guaranteed-valid JSON —
# no string scraping. unit_conversions uses explicit optional keys because the schema
# grammar requires additionalProperties: false (no open maps).
_OUTPUT_SCHEMA = {
    "type": "json_schema",
    "schema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["per_100g", "serving_grams", "kcal_per_serving", "unit_conversions"],
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
            "kcal_per_serving": {"type": "number"},
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
            _logger.warning("nutrition estimate failed for food=%s: %s", food_ref(item.name), exc)
            return None
        return validate_estimate(data)


_GROUNDED_PROMPT = """\
Look up this food's nutrition facts on the web (the brand's own site, USDA, retailer or \
nutrition databases). Prefer the official label. Then reply with ONLY compact JSON on one \
line, using the label values you found for ONE serving and per-100g:
{{"per_100g": {{"kcal": n, "protein": g, "carbs": g, "fat": g, "fiber": g}}, \
"serving_grams": n, "kcal_per_serving": n, "unit_conversions": {{"piece": g_or_null, \
"slice": g_or_null, "ml": g_or_null}}}}
The description may itself quote label facts (e.g. "23g protein"): treat those as ground \
truth and use them to pick the RIGHT product among variants.
serving_grams is one serving AS EATEN: for a restaurant or menu item that is the WHOLE \
item as sold (a whole sandwich, burger, bowl, can or bottle — often 200-500 g); a HOMEMADE \
single-serving item (a pb&j, a bowl of cereal) is its normal portion, usually 100-250 g. \
If the description says WHOLE pizza/pie/pint, serving_grams is the ENTIRE item (a whole \
12-inch pizza is ~500-850 g), not one slice. Nutrition \
sites list values per 100 g; 100 is the reporting basis, NOT a serving — never echo it as \
serving_grams. kcal_per_serving is the calories in that one whole serving (for a Big Mac, \
the whole sandwich's calories).
CRITICAL: if the food is eaten in discrete pieces — bacon or turkey-bacon slices, eggs, \
chicken nuggets/tenders, cookies, crackers, shrimp, meatballs, slices of bread or pizza — \
you MUST fill the matching piece/slice weight, because users log "3 pieces". Use the real \
weight of THIS food's piece: small pieces (crackers, nuggets, bacon) run 5-30 g, mid \
pieces (eggs, cookies, bread slices) 25-60 g, large pieces (a slice of a 14-inch pizza, \
a pancake, a sausage link) 70-140 g — never anchor a pizza slice at bread-slice weight. \
serving_grams is one serving and may equal several pieces, so never \
reuse the serving (or a 100 g basis) as the per-piece weight. "ml" is grams per \
milliliter (a density near 1.0), never a serving size.
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
        prompt = _GROUNDED_PROMPT.format(food=describe_food(item))
        # Bias the search to authoritative nutrition domains: the brand's OWN site
        # (mcdonalds.com, dunkindonuts.com, …) plus trusted databases (USDA, Nutritionix).
        # Field report 2026-07: an unconstrained search for "large protein iced matcha
        # from Dunkin" returned a 0g-protein entry — the domain allowlist steers it to
        # Dunkin's own nutrition page and the real protein figure.
        try:
            resp = await self._search(prompt, domains_for(item.brand))
        except Exception as exc:
            # Anthropic's crawler rejects a few domains outright (400 lists them). Rather
            # than lose grounding entirely over one bad domain, retry unconstrained — still
            # a real web search with sources, just not domain-steered.
            if "not accessible to our user agent" in str(exc):
                _logger.info("grounded search domain rejected for food=%s — retrying open", food_ref(item.name))
                try:
                    resp = await self._search(prompt, None)
                except Exception as exc2:
                    _logger.warning("grounded estimate failed for food=%s: %s", food_ref(item.name), exc2)
                    return None
            else:
                _logger.warning("grounded estimate failed for food=%s: %s", food_ref(item.name), exc)
                return None
        data = _json_from_blocks(resp.content)
        if data is None:
            # The search-result blocks count against max_tokens, so the model can burn the
            # whole budget searching and never write the JSON line (field eval 2026-07-30:
            # ~a third of grounded lookups died "substring not found" and silently fell to
            # blind knowledge estimates — no sources, worse numbers). The searches already
            # happened and are in the turn's content: ask once for JSON-only, no new tools.
            try:
                followup = await self._ensure_client().messages.create(
                    model=self._model,
                    max_tokens=300,
                    messages=[
                        {"role": "user", "content": prompt},
                        {"role": "assistant", "content": _text_and_results_only(resp.content)},
                        {
                            "role": "user",
                            "content": "Reply now with ONLY the compact JSON object — no prose.",
                        },
                    ],
                )
                data = _json_from_blocks(followup.content)
            except Exception as exc:
                _logger.warning("grounded JSON follow-up failed for food=%s: %s", food_ref(item.name), exc)
        if data is None:
            _logger.warning("grounded reply unparseable for food=%s", food_ref(item.name))
            return None
        est = validate_estimate(data)
        if est is None:
            return None
        if est.serving_grams == 100.0:
            # A grounded serving of EXACTLY 100 g is the per-100g basis echoed back — the
            # aggregator sites this lane searches lead with per-100g tables, and a reply
            # built solely from one is self-consistent (kcal_per_serving == per-100g kcal),
            # so the basis cross-check cannot catch it. Real labels almost never land on
            # 100.0 exactly. Decline to the knowledge estimator, where 100 g stays legal
            # for the rare genuinely-100 g product (it isn't anchored on search tables).
            _logger.info("grounded serving_grams=100 for food=%s — per-100g echo, declining", food_ref(item.name))
            return None
        return EstimatedFood(
            per_100g=est.per_100g,
            serving_grams=est.serving_grams,
            unit_conversions=est.unit_conversions,
            sources=_extract_sources(resp.content),
            kcal_per_serving=est.kcal_per_serving,
        )

    async def _search(self, prompt: str, allowed: list[str] | None) -> Any:
        web_search: dict[str, Any] = {
            "type": "web_search_20250305",
            "name": "web_search",
            # 2, not 3: each search's result blocks eat max_tokens; two authoritative hits
            # answer every label question this lane sees, and the third search was the
            # single biggest reason the JSON line got truncated away (eval 2026-07-30).
            "max_uses": 2,
        }
        if allowed:
            web_search["allowed_domains"] = allowed
        return await self._ensure_client().messages.create(
            model=self._model,
            # Search-result blocks count against this budget alongside the JSON line —
            # 1500 truncated roughly a third of grounded lookups before they could answer.
            max_tokens=4000,
            tools=[web_search],
            messages=[{"role": "user", "content": prompt}],
        )


def _json_from_blocks(blocks: list) -> dict[str, Any] | None:
    """The first parseable JSON object across the reply's text blocks, or None."""
    text = "".join(b.text for b in blocks if getattr(b, "type", "") == "text")
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        return None
    try:
        parsed = json.loads(text[start : end + 1])
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _text_and_results_only(blocks: list) -> list[dict[str, Any]]:
    """Replay content for the JSON-only follow-up turn: keep text and search results
    (the evidence), drop server_tool_use blocks — resending those requires re-declaring
    the tool, and the follow-up must NOT search again, just write the JSON."""
    out: list[dict[str, Any]] = []
    for b in blocks:
        if getattr(b, "type", "") == "text" and b.text.strip():
            out.append({"type": "text", "text": b.text})
    if not out:
        out.append({"type": "text", "text": "(searched; results reviewed)"})
    return out


def _registrable_domain(url: str) -> str:
    """Provider identity for dedupe: last two host labels (foods.fatsecret.com and
    androidembeddedregional.fatsecret.com are the SAME source, and showing both inflates
    the trust row — field report 2026-07)."""
    host = re.sub(r"^[a-z]+://", "", url.lower()).split("/", 1)[0].split(":", 1)[0]
    return ".".join(host.rsplit(".", 2)[-2:]) if host else url


def _extract_sources(blocks: list) -> tuple[FoodSource, ...]:
    """Deterministic source list from web_search tool-result blocks (url+title), deduped by
    registrable domain (one entry per provider), capped at 4. Error results ('content' is
    an object) yield nothing."""
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
            if not url:
                continue
            domain = _registrable_domain(url)
            if domain in seen:
                continue
            seen.add(domain)
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
            # Version gate: a row written by an older estimator (e.g. before the count-unit
            # / per-piece fixes) is a MISS, so the food re-estimates under current rules
            # instead of serving stale numbers forever. Also re-validate the per-100g on
            # read (cheap) so a historically-bad row can't linger.
            if int(payload.get("estimator_version", 0)) >= ESTIMATOR_VERSION:
                try:
                    # Re-validate CONVERSIONS too, not just the per-100g: a poisoned
                    # per-piece weight in a current-version row would otherwise bypass
                    # the fences forever, for every user (the caches are shared).
                    revalidated = validate_estimate(
                        {
                            "per_100g": payload["per_100g"],
                            "serving_grams": payload["serving_grams"],
                            "kcal_per_serving": payload["kcal_per_serving"],
                            "unit_conversions": payload.get("unit_conversions") or {},
                        }
                    )
                    if revalidated is not None:
                        return EstimatedFood(
                            per_100g=NutrientProfile(**payload["per_100g"]),
                            serving_grams=float(payload["serving_grams"]),
                            unit_conversions=revalidated.unit_conversions,
                            sources=tuple(
                                FoodSource(url=str(s.get("url", "")), title=str(s.get("title", "")))
                                for s in (payload.get("sources") or [])
                                if s.get("url")
                            ),
                            kcal_per_serving=revalidated.kcal_per_serving,
                        )
                except (KeyError, TypeError, ValueError) as exc:
                    _logger.warning("estimate cache row corrupt for food=%s (%s) — miss", food_ref(key), exc)

        result = await self._inner.estimate(item)
        if result is not None:
            profile = {
                "estimator_version": ESTIMATOR_VERSION,
                "per_100g": result.per_100g.model_dump(),
                "serving_grams": result.serving_grams,
                "kcal_per_serving": result.kcal_per_serving,
                "unit_conversions": result.unit_conversions,
                "sources": [{"url": s.url, "title": s.title} for s in result.sources],
            }
            # UPSERT by query_key (UNIQUE): a stale-version row exists when the version gate
            # above rejected it — overwrite it rather than 500 on the unique violation.
            if rows:
                await self._db.update("usda_cache", {"query_key": key}, {"profile": profile})
            else:
                try:
                    await self._db.insert(
                        "usda_cache", {"query_key": key, "fdc_id": None, "profile": profile}
                    )
                except UniqueViolationError:
                    # A concurrent writer beat us to this key — their row is equally valid.
                    await self._db.update("usda_cache", {"query_key": key}, {"profile": profile})
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
