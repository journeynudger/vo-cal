"""Meals API: confirm a parsed meal into a durable log, list a day, soft-delete.

Confirm is the handoff the whole product turns on. The server:
  - recomputes totals from the confirmed items (never trusts client math),
  - diffs confirmed-vs-parsed into append-only ``corrections`` (training data +
    audit trail; AGENTS.md),
  - is idempotent by ``client_meal_id`` so outbox/offline retries are safe.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, HTTPException, Query, status

from ..dependencies import CurrentUser, Db
from ..metrics import CORRECTIONS
from ..nutrition.schemas import Macros
from ..parser.schemas import MealType
from ..parser.store import ParsesStore
from .schemas import (
    ConfirmedItem,
    DayMeals,
    LogMealRequest,
    MealLog,
    WaterLog,
    WaterLogRequest,
)
from .store import MealsStore, WaterStore
from .today import (
    TodayMeal,
    TodayResponse,
    consumed_from_day,
    protein_band_from_protocol,
    remaining_of,
    targets_from_protocol,
)

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
    day = _parse_day(date)
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


@router.post("/water", response_model=WaterLog, status_code=status.HTTP_201_CREATED)
async def log_water(req: WaterLogRequest, user_id: CurrentUser, db: Db) -> WaterLog:
    """Append water to the day's tally; it shows up in /today.consumed.water."""
    logged_at = req.logged_at or datetime.now(UTC)
    row = await WaterStore(db).add(
        user_id=user_id, amount_oz=req.amount_oz, logged_at=logged_at
    )
    return WaterLog(
        id=row["id"],
        amount_oz=float(row["amount_oz"]),
        logged_at=datetime.fromisoformat(row["logged_at"]),
    )


@router.get("/today", response_model=TodayResponse)
async def today(
    user_id: CurrentUser,
    db: Db,
    date: str = Query(..., description="YYYY-MM-DD in the user's timezone"),
) -> TodayResponse:
    """Targets (active protocol or documented stub) vs. consumed vs. remaining.

    The day window is tz-aware from the profile (default UTC). Targets come from
    the active protocol read directly through the Database seam (NOT the protocols
    package — avoids coupling); pre-onboarding it falls back to ``STUB_TARGETS``
    so Today renders from the first log.
    """
    day = _parse_day(date)
    tz = await _user_tz(db, user_id)
    start = datetime.combine(day, datetime.min.time(), tzinfo=tz)
    end = start + timedelta(days=1)

    meals_store = MealsStore(db)
    rows = await meals_store.list_between(user_id, start, end)
    water_oz = await WaterStore(db).total_between(user_id, start, end)
    protocol_row = await _active_protocol(db, user_id)

    targets, is_stub = targets_from_protocol(protocol_row)
    consumed = consumed_from_day(rows, water_oz)
    remaining = remaining_of(targets, consumed)
    protein_min, protein_max = protein_band_from_protocol(protocol_row, targets.protein)

    today_meals = [
        TodayMeal(
            id=row["id"],
            name=row.get("name"),
            meal_type=row.get("meal_type") or MealType.UNSPECIFIED.value,
            logged_at=row["logged_at"],
            totals={k: float(v) for k, v in (row.get("totals") or {}).items()},
        )
        for row in rows
    ]

    return TodayResponse(
        date=date,
        targets=targets,
        consumed=consumed,
        remaining=remaining,
        meals=today_meals,
        avg_confidence=_avg_confidence(rows),
        targets_are_stub=is_stub,
        protein_min=protein_min,
        protein_max=protein_max,
    )


@router.delete("/{meal_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_meal(meal_id: str, user_id: CurrentUser, db: Db) -> None:
    try:
        mid = UUID(meal_id)
    except ValueError as e:
        # A non-UUID path id is simply "not found", never a 500 (uncaught ValueError).
        raise HTTPException(status.HTTP_404_NOT_FOUND, "meal not found") from e
    store = MealsStore(db)
    ok = await store.tombstone(mid, user_id, when=datetime.now(UTC))
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


def _parse_day(date: str) -> date:
    try:
        # Localized by the caller via combine(..., tzinfo=tz); the naive parse is intentional.
        return datetime.strptime(date, "%Y-%m-%d").date()  # noqa: DTZ007
    except ValueError as exc:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "date must be YYYY-MM-DD"
        ) from exc


async def _active_protocol(db: Db, user_id) -> dict | None:
    """The user's active protocol row, read directly through the Database seam.

    Queried by table name (NOT via the protocols package) to keep Today decoupled
    from the Phase F engine — Today only consumes the ``targets`` jsonb. At most
    one active row exists per user (the partial unique index in the migration).
    """
    rows = await db.select("protocols", {"active": True}, user_id=user_id)
    return rows[0] if rows else None


def _avg_confidence(rows: list[dict]) -> float:
    """kcal-weighted mean meal confidence across the day (matches log weighting)."""
    pairs = [
        (float(r.get("confidence") or 0.0), float((r.get("totals") or {}).get("kcal") or 0.0))
        for r in rows
    ]
    if not pairs:
        return 0.0
    weight = sum(w for _, w in pairs)
    if weight == 0:
        return round(sum(c for c, _ in pairs) / len(pairs), 4)
    return round(sum(c * w for c, w in pairs) / weight, 4)
