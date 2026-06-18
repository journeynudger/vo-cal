"""Meals API: confirm a parsed meal into a durable log, list a day, soft-delete.

Confirm is the handoff the whole product turns on. The server:
  - recomputes totals from the confirmed items (never trusts client math),
  - diffs confirmed-vs-parsed into append-only ``corrections`` (training data +
    audit trail; AGENTS.md),
  - is idempotent by ``client_meal_id`` so outbox/offline retries are safe.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, HTTPException, Query, status

from ..dependencies import CurrentUser, Db
from ..metrics import CORRECTIONS
from ..nutrition.schemas import Macros
from ..parser.schemas import MealType
from ..parser.store import ParsesStore
from .schemas import ConfirmedItem, DayMeals, LogMealRequest, MealLog
from .store import MealsStore

router = APIRouter(prefix="/meals", tags=["meals"])

# Fields compared parsed-vs-confirmed to mint corrections.
_DIFF_FIELDS = ("name", "amount", "unit", "state", "fat_ratio", "grams")


def _totals(items: list[ConfirmedItem]) -> Macros:
    total = Macros.zero()
    for item in items:
        total = total + item.macros
    return total


def _meal_confidence(items: list[ConfirmedItem]) -> float:
    if not items:
        return 0.0
    weights = [max(i.macros.kcal, 0.0) for i in items]
    total = sum(weights)
    if total == 0:
        return round(sum(i.confidence for i in items) / len(items), 4)
    return round(sum(i.confidence * w for i, w in zip(items, weights, strict=True)) / total, 4)


def _norm(value: object) -> object:
    # Enums serialize to their value for a stable parsed-vs-confirmed comparison.
    return value.value if hasattr(value, "value") else value


@router.post("", response_model=MealLog, status_code=status.HTTP_201_CREATED)
async def log_meal(req: LogMealRequest, user_id: CurrentUser, db: Db) -> MealLog:
    store = MealsStore(db)

    existing = await store.get_by_client_id(user_id, req.client_meal_id)
    if existing is not None:
        # Idempotent replay: return the already-committed meal unchanged.
        return await _to_response(store, existing)

    totals = _totals(req.items)
    confidence = _meal_confidence(req.items)
    logged_at = req.logged_at or datetime.now(UTC)
    items_json = [i.model_dump(mode="json") for i in req.items]

    row = await store.insert_meal(
        user_id=user_id,
        client_meal_id=req.client_meal_id,
        parse_id=req.parse_id,
        name=req.name,
        meal_type=req.meal_type.value,
        items=items_json,
        totals=totals.model_dump(),
        confidence=confidence,
        logged_at=logged_at,
    )

    corrections = await _record_corrections(store, db, row["id"], req, user_id)
    if req.save_as_usual:
        await store.insert_saved_meal(
            user_id=user_id,
            name=req.name or "Saved meal",
            items=items_json,
            totals=totals.model_dump(),
        )

    return _build_response(row, req.items, totals, confidence, corrections)


@router.get("", response_model=DayMeals)
async def list_day(
    user_id: CurrentUser,
    db: Db,
    date: str = Query(..., description="YYYY-MM-DD in the user's timezone"),
) -> DayMeals:
    try:
        # Localized immediately below via combine(..., tzinfo=tz); the naive parse is intentional.
        day = datetime.strptime(date, "%Y-%m-%d").date()  # noqa: DTZ007
    except ValueError as exc:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "date must be YYYY-MM-DD"
        ) from exc

    tz = await _user_tz(db, user_id)
    start = datetime.combine(day, datetime.min.time(), tzinfo=tz)
    end = start + timedelta(days=1)

    store = MealsStore(db)
    rows = await store.list_between(user_id, start, end)
    meals = [await _to_response(store, row) for row in rows]
    totals = Macros.zero()
    for meal in meals:
        totals = totals + meal.totals
    return DayMeals(date=date, meals=meals, totals=totals)


@router.delete("/{meal_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_meal(meal_id: str, user_id: CurrentUser, db: Db) -> None:
    store = MealsStore(db)
    ok = await store.tombstone(UUID(meal_id), user_id, when=datetime.now(UTC))
    if not ok:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "meal not found")


# -- helpers -----------------------------------------------------------------


async def _record_corrections(
    store: MealsStore, db: Db, meal_log_id: str, req: LogMealRequest, user_id
) -> int:
    """Append a correction row per field that changed from the parse. Returns count."""
    if req.parse_id is None:
        return 0
    parse_row = await ParsesStore(db).get(req.parse_id, user_id)
    if parse_row is None:
        # Parse not found/owned: log the meal anyway (capture is sacred), no diff.
        return 0
    parsed_items = parse_row["payload"]["result"]["items"]

    count = 0
    for index, confirmed in enumerate(req.items):
        parsed = parsed_items[index] if index < len(parsed_items) else {}
        confirmed_data = confirmed.model_dump(mode="json")
        for field in _DIFF_FIELDS:
            before = _norm(parsed.get(field))
            after = _norm(confirmed_data.get(field))
            if before != after:
                await store.insert_correction(
                    meal_log_id=meal_log_id,
                    item_index=index,
                    field=field,
                    parsed_value=before,
                    confirmed_value=after,
                )
                CORRECTIONS.labels(field=field).inc()
                count += 1
    return count


def _build_response(
    row: dict, items: list[ConfirmedItem], totals: Macros, confidence: float, corrections: int
) -> MealLog:
    return MealLog(
        id=row["id"],
        name=row.get("name"),
        meal_type=MealType(row["meal_type"]),
        items=items,
        totals=totals,
        confidence=confidence,
        logged_at=datetime.fromisoformat(row["logged_at"]),
        corrections_count=corrections,
    )


async def _to_response(store: MealsStore, row: dict) -> MealLog:
    items = [ConfirmedItem.model_validate(i) for i in row["items"]]
    corrections = await store.count_corrections(row["id"])
    return MealLog(
        id=row["id"],
        name=row.get("name"),
        meal_type=MealType(row["meal_type"]),
        items=items,
        totals=Macros.model_validate(row["totals"]),
        confidence=row.get("confidence") or 0.0,
        logged_at=datetime.fromisoformat(row["logged_at"]),
        corrections_count=corrections,
    )


async def _user_tz(db: Db, user_id) -> ZoneInfo:
    rows = await db.select("profiles", user_id=user_id)
    name = (rows[0].get("tz") if rows else None) or "UTC"
    try:
        return ZoneInfo(name)
    except ZoneInfoNotFoundError:
        return ZoneInfo("UTC")
