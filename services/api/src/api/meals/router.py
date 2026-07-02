"""Meals API: confirm a parsed meal into a durable log, list a day, soft-delete.

Confirm is the handoff the whole product turns on. The server:
  - recomputes totals from the confirmed items (never trusts client math),
  - diffs confirmed-vs-parsed into append-only ``corrections`` (training data +
    audit trail; AGENTS.md),
  - is idempotent by ``client_meal_id`` so outbox/offline retries are safe.
"""

from __future__ import annotations

import re
from datetime import UTC, date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, HTTPException, Query, status

from ..db import UniqueViolationError
from ..dependencies import CurrentUser, Db
from ..metrics import CORRECTIONS
from ..nutrition.build import build_resolver
from ..nutrition.resolver import Resolver
from ..nutrition.schemas import Macros, ResolutionSource
from ..parser.schemas import MealType, ParsedItem
from ..parser.store import ParsesStore
from .schemas import (
    ConfirmedItem,
    DayMeals,
    LogMealRequest,
    MealLog,
    UpdateMealRequest,
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

# ParsedItem.fat_ratio contract pattern — ConfirmedItem.fat_ratio is free-form, so a
# user-edited junk ratio must degrade to "unspecified" on re-resolution, not 422 the log.
_FAT_RATIO_RE = re.compile(r"^\d{2}/\d{1,2}$")


def _totals(items: list[ConfirmedItem]) -> Macros:
    total = Macros.zero()
    for item in items:
        total = total + item.macros
    return total


def _build_resolver(db: Db) -> Resolver:
    # Confirm path: estimate unknown foods (flagged) so a logged meal never silently shows
    # 0 kcal. This deliberately differs from the parse preview, which leaves unknowns
    # unresolved — see nutrition/build.py for the single construction site and the reasoning.
    return build_resolver(db, estimate_unknowns=True)


async def _reresolve(db: Db, items: list[ConfirmedItem]) -> list[ConfirmedItem]:
    """Server-recompute each confirmed item's macros/grams from its identity (NN#6, RT-02).

    The client's grams/macros/source are advisory and never trusted into durable totals; we
    re-resolve through the same deterministic engine the parse used, threading the chosen
    ``variant`` so a variant food doesn't regress to its family default. confidence is left
    as sent (a display/trust signal, not a nutrition number) — RT-02 is macro authority.
    """
    resolver = _build_resolver(db)
    out: list[ConfirmedItem] = []
    for item in items:
        # A manual correction is the user's own ground truth: trust their macros/grams verbatim
        # and never re-resolve (the one exception to RT-02). Confidence is full — they confirmed it.
        if item.manual:
            out.append(
                item.model_copy(
                    update={"source": ResolutionSource.MANUAL, "is_estimate": False, "confidence": 1.0}
                )
            )
            continue
        parsed = ParsedItem(
            name=item.name,
            amount=item.amount,
            unit=item.unit,
            state=item.state,
            fat_ratio=item.fat_ratio if item.fat_ratio and _FAT_RATIO_RE.match(item.fat_ratio) else None,
            variant=item.variant,
            brand=item.brand,
            prep_method=item.prep_method,
            confidence=item.confidence,
        )
        resolved = await resolver.resolve_item(parsed)
        out.append(
            item.model_copy(
                update={
                    "grams": resolved.grams,
                    "macros": resolved.macros,
                    "fat_ratio": resolved.resolved_fat_ratio or item.fat_ratio,
                    "variant": resolved.resolved_variant or item.variant,
                    "source": resolved.source,
                    "is_estimate": resolved.is_estimate,
                }
            )
        )
    return out


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

    # Server recomputes per-item macros/grams from identity — client numbers are never
    # trusted into durable totals (Non-Negotiable #6, RT-02).
    items = await _reresolve(db, req.items)
    totals = _totals(items)
    confidence = _meal_confidence(items)
    logged_at = req.logged_at or datetime.now(UTC)
    items_json = [i.model_dump(mode="json") for i in items]

    try:
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
    except UniqueViolationError:
        # A concurrent replay committed this client_meal_id between our check and
        # insert: return the already-committed meal unchanged rather than 500 (the
        # corrections/save effects were applied by the winner). (RT-08/12 class.)
        existing = await store.get_by_client_id(user_id, req.client_meal_id)
        if existing is None:
            raise
        return await _to_response(store, existing)

    corrections = await _record_corrections(store, db, row["id"], req.parse_id, items, user_id)
    if req.save_as_usual:
        await store.insert_saved_meal(
            user_id=user_id,
            name=req.name or "Saved meal",
            items=items_json,
            totals=totals.model_dump(),
        )

    return _build_response(row, items, totals, confidence, corrections)


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
    """Append water to the day's tally; it shows up in /today.consumed.water.

    Idempotent by client_water_id (mirrors confirm): a replayed POST returns the
    existing entry instead of double-counting a dashboard pillar (RT-13).
    """
    store = WaterStore(db)

    existing = await store.get_by_client_id(user_id, req.client_water_id)
    if existing is not None:
        return _water_response(existing, deduped=True)

    logged_at = req.logged_at or datetime.now(UTC)
    try:
        row = await store.add(
            user_id=user_id,
            client_water_id=req.client_water_id,
            amount_oz=req.amount_oz,
            logged_at=logged_at,
        )
    except UniqueViolationError:
        # Concurrent replay won the race between the check above and this insert.
        existing = await store.get_by_client_id(user_id, req.client_water_id)
        if existing is None:
            raise
        return _water_response(existing, deduped=True)
    return _water_response(row)


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


@router.get("/{meal_id}", response_model=MealLog)
async def get_meal(meal_id: str, user_id: CurrentUser, db: Db) -> MealLog:
    """The full logged meal (items + macros) — backs the iOS edit screen."""
    store = MealsStore(db)
    row = await _load_owned_meal(store, meal_id, user_id)
    return await _to_response(store, row)


@router.put("/{meal_id}", response_model=MealLog)
async def update_meal(
    meal_id: str, req: UpdateMealRequest, user_id: CurrentUser, db: Db
) -> MealLog:
    """Edit an already-logged meal: re-resolve items (trusting manual corrections), recompute
    totals + confidence, persist. The Today totals recompute on the next /today fetch."""
    store = MealsStore(db)
    existing = await _load_owned_meal(store, meal_id, user_id)
    items = await _reresolve(db, req.items)
    totals = _totals(items)
    confidence = _meal_confidence(items)
    name = req.name if req.name is not None else existing.get("name")
    current_type = existing.get("meal_type") or MealType.UNSPECIFIED.value
    meal_type = (req.meal_type.value if req.meal_type is not None else current_type)
    updated = await store.update_items(
        UUID(existing["id"]),
        user_id,
        items=[i.model_dump(mode="json") for i in items],
        totals=totals.model_dump(),
        confidence=confidence,
        name=name,
        meal_type=meal_type,
    )
    if updated is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "meal not found")
    return MealLog(
        id=UUID(existing["id"]),
        name=name,
        meal_type=MealType(meal_type),
        items=items,
        totals=totals,
        confidence=confidence,
        logged_at=datetime.fromisoformat(existing["logged_at"]),
        corrections_count=await store.count_corrections(existing["id"]),
    )


# -- helpers -----------------------------------------------------------------


async def _load_owned_meal(store: MealsStore, meal_id: str, user_id) -> dict:
    """Fetch a live, owned meal or 404 — shared by GET/PUT (a non-UUID id is just not-found)."""
    try:
        mid = UUID(meal_id)
    except ValueError as e:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "meal not found") from e
    row = await store.get(mid, user_id)
    if row is None or row.get("deleted_at"):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "meal not found")
    return row


async def _record_corrections(
    store: MealsStore, db: Db, meal_log_id: str, parse_id, items: list[ConfirmedItem], user_id
) -> int:
    """Append a correction row per field that changed from the parse. Returns count.

    Compares the server-resolved confirmed items (post-RT-02 re-resolution) against the
    parse row, so grams is server-vs-server — an unedited item produces no spurious diff.
    """
    if parse_id is None:
        return 0
    parse_row = await ParsesStore(db).get(parse_id, user_id)
    if parse_row is None:
        # Parse not found/owned: log the meal anyway (capture is sacred), no diff.
        return 0
    parsed_items = parse_row["payload"]["result"]["items"]

    count = 0
    for index, confirmed in enumerate(items):
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


def _water_response(row: dict, *, deduped: bool = False) -> WaterLog:
    return WaterLog(
        id=row["id"],
        amount_oz=float(row["amount_oz"]),
        logged_at=datetime.fromisoformat(row["logged_at"]),
        deduped=deduped,
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
