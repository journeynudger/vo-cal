"""USDA FoodData Central client — long-tail coverage, never on the hot path.

Dictionary-first resolution handles common foods (nutrition/dictionary.py);
this client covers the long tail (e.g. "spanakopita"). Two endpoints:

- ``GET /v1/foods/search`` — SR Legacy + Foundation preferred over Branded
  (cleaner per-100g basis, no serving-size guessing).
- ``GET /v1/food/{fdcId}``  — full nutrient list for the chosen food.

Design constraints (B2):

- **Read-through cache** via the Database seam (``usda_cache`` table), keyed by
  normalized search term and by fdc_id. Repeat foods cost zero FDC calls.
- **Graceful degradation**: FDC unreachable / key missing / no hit ⇒ return
  ``None`` (the resolver turns that into an unresolved item + a missing_detail).
  This client NEVER raises out to the request handler — a parse must not 500
  because USDA is down (AGENTS.md: a parse failure is not a capture failure).
- The LLM never sees these numbers (AGENTS.md #6): mapping nutrient IDs to a
  ``NutrientProfile`` is pure deterministic code.
"""

from __future__ import annotations

import logging
import re
from typing import Any

import httpx
from pydantic import ValidationError

from ..config import settings
from ..db import SupportsDatabase, UniqueViolationError
from .estimator import food_ref
from .schemas import NutrientProfile

logger = logging.getLogger(__name__)

_FDC_BASE = "https://api.nal.usda.gov/fdc/v1"

# USDA nutrient IDs → our canonical macros (per 100 g; FDC reports per 100 g).
_KCAL_IDS = (1008,)  # Energy (kcal)
_PROTEIN_IDS = (1003,)
_CARB_IDS = (1005,)  # Carbohydrate, by difference
_FAT_IDS = (1004,)  # Total lipid (fat)
_FIBER_IDS = (1079,)  # Fiber, total dietary

# Prefer clean reference data types over branded label values.
_PREFERRED_DATA_TYPES = ["Foundation", "SR Legacy", "Survey (FNDDS)"]

# Query words that carry no food identity for the relevance gate below.
_QUERY_STOPWORDS = frozenset({"the", "and", "with", "of", "raw", "cooked", "fresh", "plain"})


def normalize_query(term: str) -> str:
    """Cache key: lowercased, whitespace-collapsed search term."""
    return re.sub(r"\s+", " ", term.lower().strip())


def _query_tokens(term: str) -> list[str]:
    seen: list[str] = []
    for token in re.findall(r"[a-z0-9%]+", term.lower()):
        if len(token) >= 3 and token not in _QUERY_STOPWORDS and token not in seen:
            seen.append(token)
    return seen


def _one_edit_apart(a: str, b: str) -> bool:
    """Levenshtein distance of at most one, for words of six letters or more only: a
    database spelling ("Spanakopitta", "yoghurt") must not lose a food it plainly names,
    and a short word ("rice" vs "ride") must never gain one."""
    if len(a) < 6 or len(b) < 6 or abs(len(a) - len(b)) > 1:
        return False
    if a == b:
        return True
    if len(a) == len(b):
        return sum(x != y for x, y in zip(a, b, strict=True)) == 1
    longer, shorter = (a, b) if len(a) > len(b) else (b, a)
    i = j = 0
    skipped = False
    while i < len(longer) and j < len(shorter):
        if longer[i] == shorter[j]:
            i += 1
            j += 1
        elif skipped:
            return False
        else:
            skipped = True
            i += 1
    return True


def _token_in(token: str, text: str) -> bool:
    # Substring match plus the two English plural shapes USDA descriptions use
    # ("Apples, raw" for apple; "Cherries, sweet" for cherry; "tomato" in "Tomatoes"),
    # then one letter of tolerance for long words (FatSecret's "Spanakopitta", 2026-09-24).
    if token in text:
        return True
    if token.endswith("ies") and token[:-3] + "y" in text:
        return True
    if token.endswith("y") and token[:-1] + "ies" in text:
        return True
    if token.endswith("s") and token[:-1] in text:
        return True
    return any(_one_edit_apart(token, word) for word in re.findall(r"[a-z0-9%]+", text))


def words_agree(a: str, b: str) -> bool:
    """The same word up to a plural, or one letter of tolerance for a long one."""
    return a == b or _token_in(a, b) or _token_in(b, a) or _one_edit_apart(a, b)


def is_relevant(term: str, description: str) -> bool:
    """Every content word of the query must name something in the row's description.

    Requirement: FDC's full-text ranking is fuzzy and the chosen row was never compared to
    the query, so "cosmic crisp apple" priced USDA's "Desserts, apple crisp,
    prepared-from-recipe" (161 kcal/100 g) as an apple (field incident 2026-09-23). A row
    that does not name every word the user said is not that food; the search moves to the
    next ranked row and ends in a miss rather than a wrong food.
    """
    tokens = _query_tokens(term)
    if not tokens:
        return False
    lowered = description.lower()
    return all(_token_in(t, lowered) for t in tokens)


def _first_nutrient(nutrients: dict[int, float], ids: tuple[int, ...]) -> float:
    for nutrient_id in ids:
        if nutrient_id in nutrients:
            return nutrients[nutrient_id]
    return 0.0


def _nutrient_map_from_detail(detail: dict[str, Any]) -> dict[int, float]:
    """Pull {nutrient_id: amount} from a /food/{id} detail payload.

    Handles both the Foundation/SR shape (foodNutrients[].nutrient.id +
    .amount) and the abridged shape (foodNutrients[].nutrientId + .value).
    """
    out: dict[int, float] = {}
    for fn in detail.get("foodNutrients", []):
        nutrient = fn.get("nutrient")
        if isinstance(nutrient, dict) and "id" in nutrient:
            nid = nutrient["id"]
            amount = fn.get("amount")
        else:
            nid = fn.get("nutrientId")
            amount = fn.get("value")
        if nid is not None and amount is not None:
            out[int(nid)] = float(amount)
    return out


def profile_from_detail(detail: dict[str, Any]) -> NutrientProfile:
    """Map a USDA /food/{id} detail payload to a per-100g NutrientProfile."""
    nutrients = _nutrient_map_from_detail(detail)
    return NutrientProfile(
        kcal=_first_nutrient(nutrients, _KCAL_IDS),
        protein=_first_nutrient(nutrients, _PROTEIN_IDS),
        carbs=_first_nutrient(nutrients, _CARB_IDS),
        fat=_first_nutrient(nutrients, _FAT_IDS),
        fiber=_first_nutrient(nutrients, _FIBER_IDS),
    )


def _rank_search_hits(foods: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Prefer Foundation/SR/Survey over Branded; keep API order within a tier."""

    def tier(food: dict[str, Any]) -> int:
        data_type = food.get("dataType", "")
        return _PREFERRED_DATA_TYPES.index(data_type) if data_type in _PREFERRED_DATA_TYPES else 99

    return sorted(foods, key=tier)


class FdcResult:
    """A resolved FDC food: the chosen fdc_id, description, and per-100g profile."""

    def __init__(self, fdc_id: int, description: str, profile: NutrientProfile) -> None:
        self.fdc_id = fdc_id
        self.description = description
        self.profile = profile


class FdcClient:
    """Async FDC client with read-through caching through the Database seam.

    The HTTP transport is injectable (``transport``) so tests drive recorded
    responses with zero network (httpx.MockTransport). Live tests pass no
    transport and hit the real API behind the ``live_fdc`` marker.
    """

    def __init__(
        self,
        db: SupportsDatabase,
        *,
        api_key: str | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
        timeout: float = 5.0,
    ) -> None:
        self._db = db
        self._api_key = api_key if api_key is not None else settings.usda_fdc_api_key
        self._transport = transport
        self._timeout = timeout

    async def resolve(self, term: str, *, branded: bool = False) -> FdcResult | None:
        """Resolve a food name to a per-100g profile, cache-first.

        ``branded`` admits USDA's Branded (label) rows and is set only for items the user
        gave a brand for, queried as "<brand> <name>". Brand-less items search the
        reference types only: a generic "bread" or "apple" must never price off a random
        label row (field report 2026-09-23). Both modes apply the relevance gate.

        Returns ``None`` on any failure (no key, network error, no hit, no
        usable nutrients) — the resolver degrades gracefully. Never raises.
        """
        key = normalize_query(term) + (" [branded]" if branded else "")

        cached, stale = await self._cache_get(key, term)
        if cached is not None:
            return cached

        if not self._api_key:
            logger.info("FDC: no API key — skipping live lookup for food=%s", food_ref(key))
            return None

        try:
            fdc_id, description = await self._search(term, branded)
            if fdc_id is None:
                return None
            detail = await self._detail(fdc_id)
            if detail is None:
                return None
            # Inside the guard: a malformed detail payload (non-numeric amount, out-of-range
            # value) must degrade to a miss, not 500. profile_from_detail does int()/float()
            # and constructs a NutrientProfile (allow_inf_nan=False), any of which can raise.
            profile = profile_from_detail(detail)
        except (httpx.HTTPError, ValueError, KeyError, TypeError, ValidationError) as exc:
            logger.warning("FDC lookup failed for food=%s: %s", food_ref(key), exc)
            return None

        if profile.kcal == 0 and profile.protein == 0 and profile.carbs == 0 and profile.fat == 0:
            # No usable macros — treat as a miss rather than caching zeros.
            return None

        result = FdcResult(fdc_id=fdc_id, description=description, profile=profile)
        await self._cache_put(key, result, replace=stale)
        return result

    # -- cache (Database seam; usda_cache is a shared reference table) --------

    async def _cache_get(self, key: str, term: str) -> tuple[FdcResult | None, bool]:
        """(cached result, stale-row-present). A row whose description no longer passes the
        relevance gate (written before the gate existed — the apple-crisp row for "cosmic
        crisp apple") is a miss that the next live fetch REPLACES, so a poisoned shared row
        cannot keep pricing every user's food."""
        rows = await self._db.select("usda_cache", {"query_key": key})
        if not rows:
            return None, False
        row = rows[0]
        profile_data = row.get("profile")
        if not profile_data:
            return None, True
        # A corrupt cache row (bad fdc_id, missing/invalid per_100g) is a miss, never a 500 —
        # the cache must not be able to take down a parse that the live path would survive.
        try:
            result = FdcResult(
                fdc_id=int(row["fdc_id"]),
                description=profile_data.get("description", key),
                profile=NutrientProfile(**profile_data["per_100g"]),
            )
        except (KeyError, TypeError, ValueError, ValidationError) as exc:
            logger.warning(
                "FDC cache row corrupt for food=%s (%s) — treating as miss", food_ref(key), exc
            )
            return None, True
        if not is_relevant(term, result.description):
            logger.info("FDC cache row irrelevant for food=%s — refetching", food_ref(key))
            return None, True
        return result, False

    async def _cache_put(self, key: str, result: FdcResult, *, replace: bool = False) -> None:
        if replace:
            await self._db.update("usda_cache", {"query_key": key}, self._cache_fields(key, result))
            return
        # The cache is shared across users: two concurrent misses on the same novel
        # food both fetch FDC and both insert; the loser's 23505 must not propagate
        # into /parse (this client NEVER raises out to the request handler) — the
        # winner's row is the same data.
        try:
            await self._insert_cache_row(key, result)
        except UniqueViolationError:
            return

    @staticmethod
    def _cache_fields(key: str, result: FdcResult) -> dict[str, Any]:
        return {
            "query_key": key,
            "fdc_id": result.fdc_id,
            "profile": {
                "description": result.description,
                "per_100g": result.profile.model_dump(),
            },
        }

    async def _insert_cache_row(self, key: str, result: FdcResult) -> None:
        await self._db.insert("usda_cache", self._cache_fields(key, result))

    # -- HTTP -----------------------------------------------------------------

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            base_url=_FDC_BASE,
            timeout=self._timeout,
            transport=self._transport,
            params={"api_key": self._api_key},
        )

    async def _search(self, term: str, branded: bool) -> tuple[int | None, str]:
        # POST (JSON body), not GET: FDC's GET /foods/search rejects the dataType
        # filter with 400 — both the repeated-param form httpx emits for a list and
        # the comma-separated form. The POST endpoint takes dataType as a JSON array
        # and is the documented filtered search. Verified live 2026-06-24 against
        # api.nal.usda.gov (GET 400 / POST 200). MockTransport tests key on the
        # request path, so the recorded-fixture suite is unaffected by the method.
        data_types = [*_PREFERRED_DATA_TYPES, "Branded"] if branded else list(_PREFERRED_DATA_TYPES)
        async with self._client() as client:
            resp = await client.post(
                "/foods/search",
                json={"query": term, "dataType": data_types, "pageSize": 10},
            )
            resp.raise_for_status()
            foods = resp.json().get("foods", [])
        if not branded:
            # Belt and braces with the dataType request filter: a brand-less item must never
            # price off a label row even if the API (or a recorded fixture) returns one.
            foods = [f for f in foods if f.get("dataType") in _PREFERRED_DATA_TYPES]
        # First RELEVANT row by tier (Foundation/SR/Survey before Branded), never the raw
        # top hit: full-text ranking put "Desserts, apple crisp" first for "cosmic crisp apple".
        for food in _rank_search_hits(foods):
            description = str(food.get("description") or "")
            if is_relevant(term, description):
                return int(food["fdcId"]), description
        logger.info("FDC: no relevant row among %d hits for food=%s", len(foods), food_ref(term))
        return None, ""

    async def _detail(self, fdc_id: int) -> dict[str, Any] | None:
        async with self._client() as client:
            resp = await client.get(f"/food/{fdc_id}", params={"format": "full"})
            resp.raise_for_status()
            return resp.json()
