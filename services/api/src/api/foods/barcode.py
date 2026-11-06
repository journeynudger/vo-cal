"""Barcode food lookup: the packaged food a code names, from its label data.

Requirement (2026-11-06): scan the barcode on a package and the phone shows "Oat & Almond Bar,
Bite Best, 1 bar (50 g), 210 cal", then logs it. Label data is the source of truth and the
model is never asked (AGENTS.md #6): every number here is a provider's own label value, scaled
by arithmetic where the provider states a per-100 g profile and a serving weight.

The ladder, cheapest and most trusted first:

1. The ``usda_cache`` row ``bc:<GTIN-13>``: the finished BarcodeFood, so a repeat scan costs
   zero calls and reads identically every time (the same shared reference table and key
   discipline as the FatSecret and FDC clients).
2. FatSecret ``food.find_id_for_barcode`` then ``food.get.v4`` (nutrition/fatsecret_client.py),
   when credentials are configured: weighed label servings, the best US packaged-food data.
3. Open Food Facts, a keyless community database: per-100 g nutriments plus the serving size.

Every failure is a miss, never a raise: a provider outage must read as "no food found for that
barcode" so the person can type or speak the food instead, never as a 500.
"""

from __future__ import annotations

import logging
import math
import re
from typing import Any

import httpx
from pydantic import BaseModel, ValidationError

from ..db import SupportsDatabase, UniqueViolationError
from ..nutrition.fatsecret_client import FatSecretClient, FatSecretResult
from ..nutrition.schemas import NutrientProfile

logger = logging.getLogger(__name__)

CACHE_PREFIX = "bc:"
OPENFOODFACTS_URL = (
    "https://world.openfoodfacts.org/api/v2/product/{code}.json"
    "?fields=product_name,brands,nutriments,serving_size,serving_quantity,serving_quantity_unit"
)
# Open Food Facts asks every client to identify itself and may refuse an anonymous one.
USER_AGENT = "VoCal/0.1 (https://vo-cal.fly.dev)"

# SaveLabelFoodRequest caps name at 120 and brand at 80: a scanned food must always be
# saveable as a label food without the phone trimming it first.
_NAME_MAX = 120
_BRAND_MAX = 80
_DESCRIPTION_MAX = 80
# 1 kcal = 4.184 kJ. EU labels print kJ first and some Open Food Facts rows carry only that.
_KJ_PER_KCAL = 4.184
# Pure fat is 900 kcal per 100 g, so more than this is a kJ figure sitting in a kcal field.
# Such a row is a miss: a wrong 4,000 cal beats no food only if nobody reads it.
_MAX_KCAL_PER_100G = 1000.0

_SEPARATORS = re.compile(r"[\s-]+")
# ASCII digits only: Python's \d also matches Arabic-Indic and other Unicode digits.
_DIGITS = re.compile(r"[0-9]{8,14}")


class BarcodeFood(BaseModel):
    """A packaged food read from its barcode, as the phone shows it and then logs it."""

    barcode: str
    name: str
    brand: str | None = None
    # The whole default serving as the label states it (what "1 bar (50 g)" contains).
    per_serving: NutrientProfile
    serving_grams: float | None = None
    serving_description: str
    # None when the provider gives no weight to scale from (a "1 serving" restaurant row).
    per_100g: NutrientProfile | None = None
    source: str  # "fatsecret" | "openfoodfacts"


def _digits(code: str) -> str | None:
    cleaned = _SEPARATORS.sub("", code)
    return cleaned if _DIGITS.fullmatch(cleaned) else None


def normalize_barcode(code: str) -> str | None:
    """Spaces and dashes stripped, 8 to 14 digits only, else ``None``.

    EAN-8, UPC-A (12) and EAN-13 are left-padded with zeros to a 13-digit GTIN, the form
    FatSecret takes. A 14-digit GTIN-14 keeps its own form (Open Food Facts reads it as is);
    ``gtin13`` takes its last 13 digits for FatSecret.
    """
    digits = _digits(code)
    if digits is None:
        return None
    return digits if len(digits) == 14 else digits.zfill(13)


def gtin13(normalized: str) -> str:
    """The cache and FatSecret form of a normalized code. Exact for a GTIN-14 whose packaging
    digit is 0; a case-pack code with another digit has a different check digit, so FatSecret
    misses it and Open Food Facts (asked with all 14 digits) answers instead."""
    return normalized[-13:]


def _num(value: Any) -> float | None:
    """A finite number from a JSON number or numeric string; ``None`` for anything else."""
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _text(value: Any, limit: int) -> str:
    return " ".join(value.split())[:limit].strip() if isinstance(value, str) else ""


def _scale(profile: NutrientProfile, factor: float) -> NutrientProfile:
    return NutrientProfile(
        kcal=round(profile.kcal * factor, 1),
        protein=round(profile.protein * factor, 1),
        carbs=round(profile.carbs * factor, 1),
        fat=round(profile.fat * factor, 1),
        fiber=round(profile.fiber * factor, 1),
        sugar_g=None if profile.sugar_g is None else round(profile.sugar_g * factor, 1),
        sodium_mg=None if profile.sodium_mg is None else round(profile.sodium_mg * factor, 1),
    )


# -- Open Food Facts -----------------------------------------------------------------


def _profile(nutriments: dict[str, Any], suffix: str) -> NutrientProfile | None:
    """One nutrient profile from the ``_100g`` or ``_serving`` keys, or ``None`` when the
    product states no energy there. A macro it does not state is 0 (the contract's field is
    not optional), sugar and sodium stay None (not known, never 0). Open Food Facts reports
    sodium in grams, the contract wants milligrams."""
    kcal = _num(nutriments.get(f"energy-kcal{suffix}"))
    if kcal is None:
        kilojoules = _num(nutriments.get(f"energy{suffix}"))
        kcal = None if kilojoules is None else round(kilojoules / _KJ_PER_KCAL, 1)
    if kcal is None:
        return None
    protein, carbs, fat, fiber = (
        _num(nutriments.get(f"{key}{suffix}")) or 0.0
        for key in ("proteins", "carbohydrates", "fat", "fiber")
    )
    if min(kcal, protein, carbs, fat, fiber) < 0:
        # A serving that cannot be eaten is not a serving (as in the FatSecret client).
        return None
    sugar = _num(nutriments.get(f"sugars{suffix}"))
    sodium_g = _num(nutriments.get(f"sodium{suffix}"))
    return NutrientProfile(
        kcal=kcal,
        protein=protein,
        carbs=carbs,
        fat=fat,
        fiber=fiber,
        sugar_g=sugar if sugar is not None and sugar >= 0 else None,
        sodium_mg=None if sodium_g is None or sodium_g < 0 else round(sodium_g * 1000, 1),
    )


def _serving_amount(product: dict[str, Any]) -> tuple[float | None, str]:
    """The serving's weight and its unit when the product states a usable one. A volume (ml)
    is kept as stated: Open Food Facts' per-100 values for a drink are per 100 ml, so scaling
    by the millilitres is right, and ``serving_grams`` reads it at water density like the
    FatSecret client does."""
    amount = _num(product.get("serving_quantity"))
    unit = str(product.get("serving_quantity_unit") or "g").strip().lower()
    if amount is None or amount <= 0 or unit not in ("g", "ml"):
        return None, unit
    return amount, unit


def parse_openfoodfacts(payload: Any, barcode: str) -> BarcodeFood | None:
    """A BarcodeFood from an Open Food Facts ``/api/v2/product`` body, or ``None``.

    Per serving: the per-100 profile scaled by ``serving_quantity`` when the product states
    one; else the label's own ``*_serving`` values; else the per-100 profile itself as a
    "100 g" serving. A product with no energy, or with no name, is a miss.
    """
    if not isinstance(payload, dict) or payload.get("status") != 1:
        return None
    product = payload.get("product")
    if not isinstance(product, dict):
        return None
    name = _text(product.get("product_name"), _NAME_MAX)
    nutriments = product.get("nutriments")
    if not name or not isinstance(nutriments, dict):
        return None
    per_100g = _profile(nutriments, "_100g")
    if per_100g is not None and per_100g.kcal > _MAX_KCAL_PER_100G:
        return None
    per_label = _profile(nutriments, "_serving")
    amount, unit = _serving_amount(product)
    size_text = _text(product.get("serving_size"), _DESCRIPTION_MAX)
    if per_100g is not None and amount is not None:
        per_serving = _scale(per_100g, amount / 100.0)
        serving_grams: float | None = amount
        description = size_text or f"{amount:g} {unit}"
    elif per_label is not None:
        per_serving, serving_grams, description = per_label, amount, size_text or "1 serving"
    elif per_100g is not None:
        per_serving, serving_grams, description = per_100g, 100.0, "100 g"
    else:
        return None
    # "brands" is a comma-separated list, the first being the product's own.
    brand = _text(str(product.get("brands") or "").split(",")[0], _BRAND_MAX) or None
    return BarcodeFood(
        barcode=barcode,
        name=name,
        brand=brand,
        per_serving=per_serving,
        serving_grams=serving_grams,
        serving_description=description,
        per_100g=per_100g,
        source="openfoodfacts",
    )


async def _fetch_openfoodfacts(
    digits: str,
    barcode: str,
    *,
    transport: httpx.AsyncBaseTransport | None,
    timeout: float,
) -> BarcodeFood | None:
    try:
        async with httpx.AsyncClient(
            timeout=timeout, transport=transport, headers={"User-Agent": USER_AGENT}
        ) as client:
            response = await client.get(OPENFOODFACTS_URL.format(code=digits))
        if response.status_code == 404:
            # Its answer for an unknown product: status 0 in a 404 body. Routine, not a fault.
            return None
        response.raise_for_status()
        return parse_openfoodfacts(response.json(), barcode)
    except (httpx.HTTPError, ValueError, KeyError, TypeError, ValidationError) as exc:
        # The exception text of an HTTP error carries the URL, and so the barcode.
        logger.warning("Open Food Facts lookup failed: %s", type(exc).__name__)
        return None


# -- FatSecret -----------------------------------------------------------------------


def _from_fatsecret(barcode: str, result: FatSecretResult) -> BarcodeFood | None:
    name = _text(result.name, _NAME_MAX)
    if not name:
        return None
    return BarcodeFood(
        barcode=barcode,
        name=name,
        brand=_text(result.brand, _BRAND_MAX) or None,
        per_serving=result.per_serving,
        serving_grams=result.serving_grams,
        serving_description=_text(result.serving_description, _DESCRIPTION_MAX) or "1 serving",
        # An unweighed serving makes the client's per_100g a copy of the serving: not a
        # per-100 g figure, so it is not offered as one.
        per_100g=result.per_100g if result.serving_grams else None,
        source="fatsecret",
    )


# -- cache (Database seam; usda_cache is a shared reference table) -------------------


async def _cache_get(db: SupportsDatabase, key: str) -> tuple[BarcodeFood | None, bool]:
    """(food, stale): a corrupt row is a miss that the next put replaces in place, so one
    bad row cannot cost two provider calls on every scan of that code forever."""
    rows = await db.select("usda_cache", {"query_key": key})
    if not rows:
        return None, False
    try:
        return BarcodeFood.model_validate(rows[0].get("profile")), False
    except (KeyError, TypeError, ValueError, ValidationError) as exc:
        logger.warning("barcode cache row corrupt (%s), treating as miss", type(exc).__name__)
        return None, True


async def _cache_put(
    db: SupportsDatabase,
    key: str,
    food: BarcodeFood,
    provider_id: int | None,
    *,
    replace: bool,
) -> None:
    fields = {
        "query_key": key,
        "fdc_id": provider_id,
        "profile": {"provider": food.source, **food.model_dump(mode="json")},
    }
    if replace:
        await db.update("usda_cache", {"query_key": key}, fields)
        return
    try:
        await db.insert("usda_cache", fields)
    except UniqueViolationError:
        # Two scans of a new code raced; the other one's row is the same food.
        return


# -- the ladder ----------------------------------------------------------------------


async def lookup_barcode(
    db: SupportsDatabase,
    code: str,
    *,
    fatsecret: FatSecretClient | None,
    transport: httpx.AsyncBaseTransport | None = None,
    timeout: float = 5.0,
) -> BarcodeFood | None:
    """The packaged food for a scanned code, cache-first, or ``None`` when no provider has it.

    ``transport`` serves the Open Food Facts call (the FatSecret client carries its own), so
    a test replays recorded responses with zero network. Logs the code's length and the
    provider only: neither the code nor the product name.
    """
    digits = _digits(code)
    normalized = normalize_barcode(code)
    if digits is None or normalized is None:
        return None
    key = CACHE_PREFIX + gtin13(normalized)
    cached, stale = await _cache_get(db, key)
    if cached is not None:
        logger.info("barcode lookup: digits=%d provider=%s cache=hit", len(digits), cached.source)
        # Served for the form that was scanned, whichever form first filled the row.
        return cached.model_copy(update={"barcode": normalized})

    found: tuple[BarcodeFood, int | None] | None = None
    if fatsecret is not None:
        result = await fatsecret.resolve_barcode(gtin13(normalized))
        food = None if result is None else _from_fatsecret(normalized, result)
        if food is not None and result is not None:
            found = (food, result.food_id)
    if found is None:
        food = await _fetch_openfoodfacts(digits, normalized, transport=transport, timeout=timeout)
        if food is not None:
            found = (food, None)
    if found is None:
        logger.info("barcode lookup: digits=%d provider=none", len(digits))
        return None
    food, provider_id = found
    logger.info("barcode lookup: digits=%d provider=%s cache=miss", len(digits), food.source)
    await _cache_put(db, key, food, provider_id, replace=stale)
    return food
