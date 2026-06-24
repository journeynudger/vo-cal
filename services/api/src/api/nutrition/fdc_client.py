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

from ..config import settings
from ..db import SupportsDatabase
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


def normalize_query(term: str) -> str:
    """Cache key: lowercased, whitespace-collapsed search term."""
    return re.sub(r"\s+", " ", term.lower().strip())


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

    async def resolve(self, term: str) -> FdcResult | None:
        """Resolve a food name to a per-100g profile, cache-first.

        Returns ``None`` on any failure (no key, network error, no hit, no
        usable nutrients) — the resolver degrades gracefully. Never raises.
        """
        key = normalize_query(term)

        cached = await self._cache_get(key)
        if cached is not None:
            return cached

        if not self._api_key:
            logger.info("FDC: no API key — skipping live lookup for %r", key)
            return None

        try:
            fdc_id, description = await self._search(key)
            if fdc_id is None:
                return None
            detail = await self._detail(fdc_id)
            if detail is None:
                return None
        except (httpx.HTTPError, ValueError, KeyError) as exc:
            logger.warning("FDC lookup failed for %r: %s", key, exc)
            return None

        profile = profile_from_detail(detail)
        if profile.kcal == 0 and profile.protein == 0 and profile.carbs == 0 and profile.fat == 0:
            # No usable macros — treat as a miss rather than caching zeros.
            return None

        result = FdcResult(fdc_id=fdc_id, description=description, profile=profile)
        await self._cache_put(key, result)
        return result

    # -- cache (Database seam; usda_cache is a shared reference table) --------

    async def _cache_get(self, key: str) -> FdcResult | None:
        rows = await self._db.select("usda_cache", {"query_key": key})
        if not rows:
            return None
        row = rows[0]
        profile_data = row.get("profile")
        if not profile_data:
            return None
        return FdcResult(
            fdc_id=int(row["fdc_id"]),
            description=profile_data.get("description", key),
            profile=NutrientProfile(**profile_data["per_100g"]),
        )

    async def _cache_put(self, key: str, result: FdcResult) -> None:
        await self._db.insert(
            "usda_cache",
            {
                "query_key": key,
                "fdc_id": result.fdc_id,
                "profile": {
                    "description": result.description,
                    "per_100g": result.profile.model_dump(),
                },
            },
        )

    # -- HTTP -----------------------------------------------------------------

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            base_url=_FDC_BASE,
            timeout=self._timeout,
            transport=self._transport,
            params={"api_key": self._api_key},
        )

    async def _search(self, term: str) -> tuple[int | None, str]:
        # POST (JSON body), not GET: FDC's GET /foods/search rejects the dataType
        # filter with 400 — both the repeated-param form httpx emits for a list and
        # the comma-separated form. The POST endpoint takes dataType as a JSON array
        # and is the documented filtered search. Verified live 2026-06-24 against
        # api.nal.usda.gov (GET 400 / POST 200). MockTransport tests key on the
        # request path, so the recorded-fixture suite is unaffected by the method.
        async with self._client() as client:
            resp = await client.post(
                "/foods/search",
                json={
                    "query": term,
                    "dataType": [*_PREFERRED_DATA_TYPES, "Branded"],
                    "pageSize": 10,
                },
            )
            resp.raise_for_status()
            foods = resp.json().get("foods", [])
        if not foods:
            return None, ""
        best = _rank_search_hits(foods)[0]
        return int(best["fdcId"]), best.get("description", term)

    async def _detail(self, fdc_id: int) -> dict[str, Any] | None:
        async with self._client() as client:
            resp = await client.get(f"/food/{fdc_id}", params={"format": "full"})
            resp.raise_for_status()
            return resp.json()
