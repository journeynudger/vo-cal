"""``/foods/personal``: the foods a person declares and then speaks by name.

- ``GET /foods/personal`` lists the live ones (Settings > My foods).
- ``POST /foods/personal`` saves a food from its label (per-serving numbers as printed;
  calories computed with the Atwater factors when the label's are not given).
- ``POST /foods/personal/batch`` saves a recipe: the confirmed ingredients of a parse are
  re-resolved by the meals engine, summed, and divided by the servings the batch makes.
- ``DELETE /foods/personal/{id}`` retires one (a mark; meals priced with it keep their
  identity).
- ``GET /foods/barcode/{code}`` reads a packaged food from its barcode (foods/barcode.py); the
  phone shows it and then saves it through ``POST /foods/personal`` as a label food.

Saving a name the person already has versions it: the old row is retired, the new one
inserted, in that order, so the partial unique index never refuses a rename of the numbers.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

import httpx
from fastapi import APIRouter, Depends, HTTPException, status

from ..config import settings
from ..db import UniqueViolationError
from ..dependencies import CurrentUser, Db, get_current_user
from ..meals.router import reresolve_items
from ..nutrition.fatsecret_client import FatSecretClient
from ..nutrition.schemas import Macros, NutrientProfile
from .barcode import BarcodeFood, lookup_barcode, normalize_barcode
from .schemas import PersonalFood, SaveBatchFoodRequest, SaveLabelFoodRequest
from .store import PersonalFoodsStore

router = APIRouter(prefix="/foods", tags=["foods"])


def get_barcode_transport() -> httpx.AsyncBaseTransport | None:
    """The HTTP transport for barcode providers: ``None`` (the real network) in production.
    The suite overrides it with an ``httpx.MockTransport`` so every provider answers from a
    recorded fixture and the offline guard in tests/conftest.py never trips."""
    return None


BarcodeTransportDep = Annotated[httpx.AsyncBaseTransport | None, Depends(get_barcode_transport)]


def _clean_aliases(name: str, aliases: list[str]) -> list[str]:
    seen: set[str] = {name.strip().lower()}
    out: list[str] = []
    for alias in aliases:
        cleaned = " ".join(alias.split())
        if cleaned and cleaned.lower() not in seen:
            seen.add(cleaned.lower())
            out.append(cleaned[:120])
    return out


def _to_response(row: dict) -> PersonalFood:
    return PersonalFood(
        id=UUID(str(row["id"])),
        name=row["name"],
        aliases=list(row.get("aliases") or []),
        per_serving=NutrientProfile.model_validate(row["per_serving"]),
        serving_grams=row.get("serving_grams"),
        servings_per_package=row.get("servings_per_package"),
        source=row.get("source") or "label",
        created_at=datetime.fromisoformat(row["created_at"]),
    )


async def _save(
    store: PersonalFoodsStore,
    user_id: UUID,
    *,
    name: str,
    aliases: list[str],
    per_serving: NutrientProfile,
    serving_grams: float | None,
    servings_per_package: float | None,
    source: str,
    provenance: dict | None,
) -> PersonalFood:
    name = " ".join(name.split())
    await store.retire_by_name(user_id, name, when=datetime.now(UTC))
    try:
        row = await store.insert(
            user_id=user_id,
            name=name,
            aliases=_clean_aliases(name, aliases),
            per_serving=per_serving.model_dump(),
            serving_grams=serving_grams,
            servings_per_package=servings_per_package,
            source=source,
            provenance=provenance,
        )
    except UniqueViolationError as e:
        # Two saves of the same name raced; the other one won and is the live row.
        raise HTTPException(status.HTTP_409_CONFLICT, "that food was just saved; try again") from e
    return _to_response(row)


def _label_provenance(req: SaveLabelFoodRequest) -> dict | None:
    # A food saved from a scan keeps the code and brand it was read from; a typed label has
    # neither, and its provenance stays empty as before.
    barcode = (req.barcode or "").strip() or None
    brand = (req.brand or "").strip() or None
    if barcode is None and brand is None:
        return None
    return {"barcode": barcode, "brand": brand}


@router.get(
    "/barcode/{code}",
    response_model=BarcodeFood,
    dependencies=[Depends(get_current_user)],
)
async def get_barcode_food(code: str, db: Db, transport: BarcodeTransportDep) -> BarcodeFood:
    if normalize_barcode(code) is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "a barcode is 8 to 14 digits")
    # Gated on credentials only, not on settings.fatsecret_enabled: that flag guards the new
    # "fatsecret" ResolutionSource on the wire (nutrition/build.py), and a barcode result
    # reaches the phone as a label food, never as that source.
    fatsecret = (
        FatSecretClient(db, transport=transport)
        if settings.fatsecret_client_id and settings.fatsecret_client_secret
        else None
    )
    food = await lookup_barcode(db, code, fatsecret=fatsecret, transport=transport)
    if food is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no food found for that barcode")
    return food


@router.get("/personal", response_model=list[PersonalFood])
async def list_personal_foods(user_id: CurrentUser, db: Db) -> list[PersonalFood]:
    rows = await PersonalFoodsStore(db).list_active(user_id)
    return [_to_response(row) for row in rows]


@router.post("/personal", response_model=PersonalFood, status_code=status.HTTP_201_CREATED)
async def save_label_food(req: SaveLabelFoodRequest, user_id: CurrentUser, db: Db) -> PersonalFood:
    per_serving = req.per_serving.profile()
    if per_serving.kcal == 0 and (per_serving.protein or per_serving.carbs or per_serving.fat):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "calories cannot be 0 with macros")
    return await _save(
        PersonalFoodsStore(db),
        user_id,
        name=req.name,
        aliases=req.aliases,
        per_serving=per_serving,
        serving_grams=req.serving_grams,
        servings_per_package=req.servings_per_package,
        source="label",
        provenance=_label_provenance(req),
    )


@router.post("/personal/batch", response_model=PersonalFood, status_code=status.HTTP_201_CREATED)
async def save_batch_food(req: SaveBatchFoodRequest, user_id: CurrentUser, db: Db) -> PersonalFood:
    # The same engine as a meal confirm: identities from the owning parse row when given,
    # every number recomputed server-side (AGENTS.md #6), manual items trusted as their own.
    items = await reresolve_items(db, user_id, req.items, parse_id=req.parse_id)
    totals = Macros.zero()
    grams = 0.0
    for item in items:
        totals = totals + item.macros
        grams += float(item.grams or 0.0)
    if totals.kcal <= 0:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "the batch priced to 0 calories; set the ingredients first",
        )
    n = float(req.servings)
    per_serving = NutrientProfile(
        kcal=round(totals.kcal / n, 1),
        protein=round(totals.protein / n, 1),
        carbs=round(totals.carbs / n, 1),
        fat=round(totals.fat / n, 1),
        fiber=round(totals.fiber / n, 1),
    )
    serving_grams = round(grams / n, 1) if grams > 0 else None
    return await _save(
        PersonalFoodsStore(db),
        user_id,
        name=req.name,
        aliases=req.aliases,
        per_serving=per_serving,
        serving_grams=serving_grams,
        servings_per_package=n,
        source="batch",
        provenance={
            "parse_id": str(req.parse_id) if req.parse_id else None,
            "servings": n,
            "items": [i.model_dump(mode="json") for i in items],
            "totals": totals.model_dump(),
        },
    )


@router.delete("/personal/{food_id}", status_code=status.HTTP_204_NO_CONTENT)
async def retire_personal_food(food_id: str, user_id: CurrentUser, db: Db) -> None:
    try:
        fid = UUID(food_id)
    except ValueError as e:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "food not found") from e
    if not await PersonalFoodsStore(db).retire(fid, user_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "food not found")
