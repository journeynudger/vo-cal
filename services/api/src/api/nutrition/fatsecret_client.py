"""FatSecret Platform API client: the long-tail food database, with servings.

Where it sits (2026-09-24, owner's ask: "is FatSecret better than USDA?"): after the
curated dictionary and its suffix heads, BEFORE the estimator and USDA FDC, for generic and
branded items alike. A FatSecret row is a database read (about 200 ms, cached forever after)
that carries what USDA's per-100 g rows never do: the label's serving, cups, pieces, slices.
The estimator (a paid, nondeterministic model read) becomes the fallback for what FatSecret
does not have; FDC stays last, and scripts/food-source-eval measures whether it is reached.

Two calls per novel food:

- ``POST /rest/server.api method=foods.search`` (v1, scope basic): candidates with a
  "Per 100g - Calories: 250kcal | Fat: 12.00g | ..." description, a food_type of Generic
  or Brand, and a brand_name for brands.
- ``POST /rest/server.api method=food.get.v4``: the chosen food's servings, every number a
  string: calories, carbohydrate, protein, fat, fiber, metric_serving_amount and unit,
  number_of_units, measurement_description ("cup", "slice", "medium"), is_default.

Design constraints, the same as the FDC client's:

- Read-through cache through the Database seam (``usda_cache`` rows keyed "fs:<term>"),
  so a repeat food costs zero calls and prices identically every time.
- Graceful degradation: no credentials, the platform refusing this IP (error 21, which
  is what an unlisted IP gets), a network error, no hit, no usable serving: ``None``,
  never a raise. A parse must not 500 because a database is down.
- The relevance gate: every content word of the query must appear in the chosen row's
  name (or brand), or the row is a miss; full-text search returns "apple crisp" for
  "apple" and the resolver must never price it.
- The model never sees these numbers (AGENTS.md #6): a serving becomes a per-100 g
  profile and unit conversions in deterministic code here.

Access: FatSecret allow-lists caller IPs per application. This Mac and the Fly machine's
egress address must be listed in the platform dashboard (found 2026-09-24: the first live
call answered error 21 for 96.246.134.132; the production egress was 152.236.10.30).
"""

from __future__ import annotations

import base64
import logging
import time
from dataclasses import dataclass, field
from typing import Any

import httpx
from pydantic import ValidationError

from ..config import settings
from ..db import SupportsDatabase, UniqueViolationError
from .estimator import food_ref
from .fdc_client import is_relevant, normalize_query
from .schemas import NutrientProfile

logger = logging.getLogger(__name__)

TOKEN_URL = "https://oauth.fatsecret.com/connect/token"
API_URL = "https://platform.fatsecret.com/rest/server.api"
CACHE_PREFIX = "fs:"
_SEARCH_RESULTS = 8
# A token lasts a day; refresh a minute early so a request never carries an expiring one.
_TOKEN_SLACK_SECONDS = 60.0

# FatSecret measurement descriptions → the contract's units (nutrition/resolver.py to_grams
# reads "cup", "tbsp", "tsp", "slice", "piece", "scoop" and "ml" as grams per unit).
_MEASUREMENT_UNITS: dict[str, str] = {
    "cup": "cup",
    "tbsp": "tbsp",
    "tablespoon": "tbsp",
    "tsp": "tsp",
    "teaspoon": "tsp",
    "slice": "slice",
    "scoop": "scoop",
    "piece": "piece",
    "medium": "piece",
    "small": "piece",
    "large": "piece",
    "whole": "piece",
    "each": "piece",
    "item": "piece",
    "link": "piece",
    "patty": "piece",
    "bar": "piece",
    "egg": "piece",
    "fillet": "piece",
    "breast": "piece",
    "thigh": "piece",
    "wing": "piece",
    "leg": "piece",
    "package": "piece",
    "container": "piece",
    "bottle": "piece",
    "can": "piece",
    "sandwich": "piece",
    "burrito": "piece",
    "bowl": "piece",
    "taco": "piece",
}


@dataclass(frozen=True)
class FatSecretServing:
    description: str
    measurement: str
    units: float
    metric_amount: float | None
    metric_unit: str | None
    profile: NutrientProfile  # for the whole serving, not per 100 g
    is_default: bool


@dataclass(frozen=True)
class FatSecretResult:
    food_id: int
    name: str
    brand: str | None
    food_type: str  # "Generic" | "Brand"
    per_100g: NutrientProfile
    # Grams in the default serving; None when the platform gives the serving no weight
    # (a restaurant "1 serving"): such a row prices by servings, never by a stated mass.
    serving_grams: float | None
    serving_description: str
    per_serving: NutrientProfile
    unit_conversions: dict[str, float] = field(default_factory=dict)

    @property
    def description(self) -> str:
        return f"{self.brand} {self.name}".strip() if self.brand else self.name


def _num(value: Any, default: float | None = None) -> float | None:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _as_list(value: Any) -> list[dict[str, Any]]:
    # The platform serializes a single child as an object, several as an array.
    if value is None:
        return []
    if isinstance(value, dict):
        return [value]
    if isinstance(value, list):
        return [v for v in value if isinstance(v, dict)]
    return []


def parse_serving(raw: dict[str, Any]) -> FatSecretServing | None:
    kcal = _num(raw.get("calories"))
    if kcal is None:
        return None
    profile = NutrientProfile(
        kcal=kcal,
        protein=_num(raw.get("protein"), 0.0) or 0.0,
        carbs=_num(raw.get("carbohydrate"), 0.0) or 0.0,
        fat=_num(raw.get("fat"), 0.0) or 0.0,
        fiber=_num(raw.get("fiber"), 0.0) or 0.0,
    )
    return FatSecretServing(
        description=str(raw.get("serving_description") or ""),
        measurement=str(raw.get("measurement_description") or "").strip().lower(),
        units=_num(raw.get("number_of_units"), 1.0) or 1.0,
        metric_amount=_num(raw.get("metric_serving_amount")),
        metric_unit=(str(raw.get("metric_serving_unit")).strip().lower() if raw.get("metric_serving_unit") else None),
        profile=profile,
        is_default=str(raw.get("is_default") or "") == "1",
    )


def _grams(serving: FatSecretServing) -> float | None:
    """The serving's weight in grams when the platform states one. A volume serving (ml)
    is read at water density, the resolver's own default for an unknown ml conversion."""
    if serving.metric_amount is None or serving.metric_amount <= 0:
        return None
    if serving.metric_unit == "g":
        return serving.metric_amount
    if serving.metric_unit == "oz":
        return serving.metric_amount * 28.3495
    if serving.metric_unit == "ml":
        return serving.metric_amount
    return None


def _scale(profile: NutrientProfile, factor: float) -> NutrientProfile:
    return NutrientProfile(
        kcal=round(profile.kcal * factor, 3),
        protein=round(profile.protein * factor, 3),
        carbs=round(profile.carbs * factor, 3),
        fat=round(profile.fat * factor, 3),
        fiber=round(profile.fiber * factor, 3),
    )


def build_result(food: dict[str, Any]) -> FatSecretResult | None:
    """Turn a ``food.get`` payload into the identity's numbers, deterministically.

    per 100 g comes from a weighed serving (a "100 g" serving when the row has one, else
    the default weighed serving); unit conversions come from every weighed serving whose
    measurement names a contract unit; an unweighed default serving (restaurant rows) makes
    per_100g equal per_serving with no serving weight, the personal-foods convention.
    """
    servings = [s for s in (parse_serving(r) for r in _as_list((food.get("servings") or {}).get("serving"))) if s]
    if not servings:
        return None
    default = next((s for s in servings if s.is_default), servings[0])
    weighed = [(s, _grams(s)) for s in servings]
    weighed = [(s, g) for s, g in weighed if g]
    hundred = next((s for s, g in weighed if abs(g - 100.0) < 0.01), None)
    if hundred is not None:
        per_100g = hundred.profile
    elif weighed:
        base, grams = next(((s, g) for s, g in weighed if s is default), weighed[0])
        per_100g = _scale(base.profile, 100.0 / grams)
    else:
        per_100g = default.profile
    default_grams = _grams(default)
    if default_grams is None and weighed:
        default, default_grams = weighed[0]
    conversions: dict[str, float] = {}
    for serving, grams in weighed:
        unit = _MEASUREMENT_UNITS.get(serving.measurement)
        if unit and serving.units > 0 and unit not in conversions:
            conversions[unit] = round(grams / serving.units, 3)
        if serving.metric_unit == "ml" and serving.metric_amount and "ml" not in conversions:
            conversions["ml"] = 1.0
    food_id = _num(food.get("food_id"))
    if food_id is None:
        return None
    return FatSecretResult(
        food_id=int(food_id),
        name=str(food.get("food_name") or "").strip(),
        brand=(str(food.get("brand_name")).strip() or None) if food.get("brand_name") else None,
        food_type=str(food.get("food_type") or "Generic"),
        per_100g=per_100g,
        serving_grams=default_grams,
        serving_description=default.description,
        per_serving=default.profile,
        unit_conversions=conversions,
    )


def rank_candidates(term: str, foods: list[dict[str, Any]], *, branded: bool) -> list[dict[str, Any]]:
    """Relevance first, then Generic before Brand for a brand-less query (a generic "bread"
    must never price off a random label row), Brand first for a branded one."""
    relevant: list[dict[str, Any]] = []
    for food in foods:
        name = str(food.get("food_name") or "")
        brand = str(food.get("brand_name") or "")
        if is_relevant(term, f"{brand} {name}".strip()):
            relevant.append(food)

    def tier(food: dict[str, Any]) -> int:
        is_brand = str(food.get("food_type") or "") == "Brand"
        return (0 if is_brand else 1) if branded else (1 if is_brand else 0)

    return sorted(relevant, key=tier)


class FatSecretClient:
    """Async FatSecret client with a process-wide token and read-through caching.

    The HTTP transport is injectable (``transport``) so tests replay recorded responses
    with zero network (httpx.MockTransport); the live path runs behind ``live_fatsecret``.
    """

    _token: str | None = None
    _token_expires_at: float = 0.0

    def __init__(
        self,
        db: SupportsDatabase,
        *,
        client_id: str | None = None,
        client_secret: str | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
        timeout: float = 5.0,
    ) -> None:
        self._db = db
        self._client_id = client_id if client_id is not None else settings.fatsecret_client_id
        self._client_secret = client_secret if client_secret is not None else settings.fatsecret_client_secret
        self._transport = transport
        self._timeout = timeout

    @property
    def configured(self) -> bool:
        return bool(self._client_id and self._client_secret)

    async def resolve(self, term: str, *, branded: bool = False) -> FatSecretResult | None:
        """The best FatSecret row for a food name, cache-first. ``None`` on any failure."""
        key = CACHE_PREFIX + normalize_query(term) + (" [branded]" if branded else "")
        cached, stale = await self._cache_get(key, term)
        if cached is not None:
            return cached
        if not self.configured:
            logger.info("FatSecret: no credentials, skipping food=%s", food_ref(key))
            return None
        try:
            result = await self._lookup(term, branded)
        except (httpx.HTTPError, ValueError, KeyError, TypeError, ValidationError) as exc:
            logger.warning("FatSecret lookup failed for food=%s: %s", food_ref(key), exc)
            return None
        if result is None:
            return None
        if result.per_100g.kcal == 0 and result.per_100g.protein == 0 and result.per_100g.carbs == 0 and result.per_100g.fat == 0:
            return None
        await self._cache_put(key, result, replace=stale)
        return result

    # -- HTTP ----------------------------------------------------------------------

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(timeout=self._timeout, transport=self._transport)

    async def _access_token(self, client: httpx.AsyncClient) -> str:
        now = time.monotonic()
        cls = type(self)
        if cls._token and now < cls._token_expires_at:
            return cls._token
        basic = base64.b64encode(f"{self._client_id}:{self._client_secret}".encode()).decode()
        response = await client.post(
            TOKEN_URL,
            data={"grant_type": "client_credentials", "scope": "basic"},
            headers={"Authorization": f"Basic {basic}"},
        )
        response.raise_for_status()
        payload = response.json()
        token = str(payload["access_token"])
        expires_in = float(payload.get("expires_in") or 3600)
        cls._token = token
        cls._token_expires_at = now + max(60.0, expires_in - _TOKEN_SLACK_SECONDS)
        return token

    async def _call(self, client: httpx.AsyncClient, method: str, **params: Any) -> dict[str, Any]:
        token = await self._access_token(client)
        response = await client.post(
            API_URL,
            data={"method": method, "format": "json", **params},
            headers={"Authorization": f"Bearer {token}"},
        )
        if response.status_code == 401:
            # The token was revoked or expired early: fetch one more and try once.
            type(self)._token = None
            token = await self._access_token(client)
            response = await client.post(
                API_URL,
                data={"method": method, "format": "json", **params},
                headers={"Authorization": f"Bearer {token}"},
            )
        response.raise_for_status()
        payload = response.json()
        error = payload.get("error") if isinstance(payload, dict) else None
        if error:
            # The platform answers 200 with an error object. Code 21 is "this IP is not
            # allowed": an operations failure, said out loud, never a 500 for the person.
            raise ValueError(f"fatsecret error {error.get('code')}: {error.get('message')}")
        return payload

    async def _lookup(self, term: str, branded: bool) -> FatSecretResult | None:
        async with self._client() as client:
            search = await self._call(client, "foods.search", search_expression=term, max_results=_SEARCH_RESULTS)
            foods = _as_list((search.get("foods") or {}).get("food"))
            for candidate in rank_candidates(term, foods, branded=branded):
                detail = await self._call(client, "food.get.v4", food_id=str(candidate.get("food_id")))
                result = build_result(detail.get("food") or {})
                if result is not None:
                    return result
        return None

    # -- cache (Database seam; usda_cache is a shared reference table) -------------

    async def _cache_get(self, key: str, term: str) -> tuple[FatSecretResult | None, bool]:
        rows = await self._db.select("usda_cache", {"query_key": key})
        if not rows:
            return None, False
        row = rows[0]
        data = row.get("profile") or {}
        try:
            result = FatSecretResult(
                food_id=int(row["fdc_id"]),
                name=str(data["name"]),
                brand=data.get("brand"),
                food_type=str(data.get("food_type") or "Generic"),
                per_100g=NutrientProfile(**data["per_100g"]),
                serving_grams=data.get("serving_grams"),
                serving_description=str(data.get("serving_description") or ""),
                per_serving=NutrientProfile(**data["per_serving"]),
                unit_conversions={str(k): float(v) for k, v in (data.get("unit_conversions") or {}).items()},
            )
        except (KeyError, TypeError, ValueError, ValidationError) as exc:
            logger.warning("FatSecret cache row corrupt for food=%s (%s), treating as miss", food_ref(key), exc)
            return None, True
        if not is_relevant(term, result.description):
            return None, True
        return result, False

    async def _cache_put(self, key: str, result: FatSecretResult, *, replace: bool = False) -> None:
        fields = {
            "query_key": key,
            "fdc_id": result.food_id,
            "profile": {
                "provider": "fatsecret",
                "name": result.name,
                "brand": result.brand,
                "food_type": result.food_type,
                "per_100g": result.per_100g.model_dump(),
                "serving_grams": result.serving_grams,
                "serving_description": result.serving_description,
                "per_serving": result.per_serving.model_dump(),
                "unit_conversions": result.unit_conversions,
            },
        }
        if replace:
            await self._db.update("usda_cache", {"query_key": key}, fields)
            return
        try:
            await self._db.insert("usda_cache", fields)
        except UniqueViolationError:
            return
