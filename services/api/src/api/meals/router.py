"""Meals API: confirm a parsed meal into a durable log, list a day, soft-delete.

Confirm is the handoff the whole product turns on. The server:
  - recomputes totals from the confirmed items (never trusts client math),
  - diffs confirmed-vs-parsed into append-only ``corrections`` (training data +
    audit trail; AGENTS.md),
  - is idempotent by ``client_meal_id`` so outbox/offline retries are safe.
"""

from __future__ import annotations

import logging
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
from ..parser.certainty import build_certainty, item_from_stored, weekly_focus
from ..parser.compose import analyze as analyze_composition
from ..parser.schemas import MealType, ParsedItem
from ..parser.store import ParsesStore
from ..protocols.store import ProtocolsStore
from .schemas import (
    AppendToMealRequest,
    ConfirmedItem,
    DayMeals,
    LogMealRequest,
    MealLog,
    SavedMeal,
    UpdateMealRequest,
    WaterLog,
    WaterLogRequest,
    WeeklySummary,
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

_logger = logging.getLogger(__name__)


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


async def _parse_transcript(db: Db, parse_id: UUID | None, user_id: UUID) -> str:
    """The transcript stored on the owning parse row, or "" when unavailable.

    The composition verdict depends on the transcript (side-phrases, "with"-links);
    re-analyzing at confirm WITHOUT it priced a different meal than the preview the
    user approved (field bug 2026-07: CTA said 827 kcal, the durable row got 377).
    Owner-scoped lookup; a missing/foreign parse falls back to the conservative
    transcript-less analysis unchanged.
    """
    if parse_id is None:
        return ""
    row = await ParsesStore(db).get(parse_id, user_id)
    payload = (row or {}).get("payload") or {}
    return str(payload.get("transcript") or "")


async def _reresolve(
    db: Db, items: list[ConfirmedItem], transcript: str = ""
) -> list[ConfirmedItem]:
    """Server-recompute each confirmed item's macros/grams from its identity (NN#6, RT-02).

    The client's grams/macros/source are advisory and never trusted into durable totals; we
    re-resolve through the same deterministic engine the parse used, threading the chosen
    ``variant`` so a variant food doesn't regress to its family default. confidence is left
    as sent (a display/trust signal, not a nutrition number) — RT-02 is macro authority.
    """
    resolver = _build_resolver(db)
    # Composed-meal grammar (parser/compose.py) applies at confirm too: without this, a
    # container the PARSE correctly zeroed ("sandwich" + its ingredients) would be re-priced
    # right back to its 450-kcal generic here — the double-count would return at store time.
    # The transcript (from the owning parse row) keeps this verdict IDENTICAL to the
    # preview's — same inputs, same suppression.
    composition = analyze_composition([(i.name, i.amount) for i in items], transcript)
    out: list[ConfirmedItem] = []
    for idx, item in enumerate(items):
        # A manual correction is the user's own ground truth: trust their macros/grams verbatim
        # and never re-resolve (the one exception to RT-02). Confidence is full — they confirmed it.
        if item.manual:
            out.append(
                item.model_copy(
                    update={"source": ResolutionSource.MANUAL, "is_estimate": False, "confidence": 1.0}
                )
            )
            continue
        if idx in composition.suppressed_indices:
            # Zero-calorie display grouping — the components carry the meal.
            out.append(
                item.model_copy(
                    update={
                        "grams": 0.0,
                        "macros": Macros.zero(),
                        "source": ResolutionSource.DICTIONARY,
                        "is_estimate": False,
                    }
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
                    "sources": (
                        [{"url": src.url, "title": src.title} for src in resolved.sources]
                        if resolved.sources
                        else None
                    ),
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
    items = await _reresolve(db, req.items, await _parse_transcript(db, req.parse_id, user_id))
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

    # [store]: durable meal_logs row committed — the "logged" rung. Ids/counts/confidence
    # only; macro values stay out of server logs (MUST-NOT #5).
    _logger.info(
        "[store] meal=%s parse=%s items=%d confidence=%.2f",
        row["id"], req.parse_id, len(items), confidence,
    )
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
    tz: str | None = Query(
        None, description="IANA timezone of the requesting device; overrides the profile tz"
    ),
) -> DayMeals:
    # Same tz resolution as /today: device param wins, else profile, else UTC. Without
    # this the two endpoints bucketed the SAME log onto different days whenever the
    # profile tz (default UTC) disagreed with the device (deferred item from #18).
    day = _parse_day(date)
    tz_zone = _zone_or_none(tz) or await _user_tz(db, user_id)
    start = datetime.combine(day, datetime.min.time(), tzinfo=tz_zone)
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
    tz: str | None = Query(
        None, description="IANA timezone of the requesting device; overrides the profile tz"
    ),
) -> TodayResponse:
    """Targets (active protocol or documented stub) vs. consumed vs. remaining.

    The day window is tz-aware: the device's ``tz`` param when sent, else the profile
    tz (default UTC). The param exists because nothing writes profiles.tz yet, so every
    user bucketed by UTC — an evening ET log (00:00+ UTC) landed on TOMORROW's day and
    "disappeared" from Today (field bug 2026-07). An unknown tz name falls back to the
    profile path rather than 422 — a bad clock label must not block reading the day.
    Targets come from the active protocol read directly through the Database seam (NOT
    the protocols package — avoids coupling); pre-onboarding it falls back to
    ``STUB_TARGETS`` so Today renders from the first log.
    """
    day = _parse_day(date)
    tz_zone = _zone_or_none(tz) or await _user_tz(db, user_id)
    start = datetime.combine(day, datetime.min.time(), tzinfo=tz_zone)
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


@router.get("/summary", response_model=WeeklySummary)
async def weekly_summary(
    user_id: CurrentUser,
    db: Db,
    date: str = Query(..., description="Week END day, YYYY-MM-DD in the user's timezone"),
    tz: str | None = Query(
        None, description="IANA timezone of the requesting device; overrides the profile tz"
    ),
) -> WeeklySummary:
    """The check-in's capture-quality week: consistency + certainty + one focus tip.

    Registered BEFORE /{meal_id} so the literal path isn't shadowed. Stored meals are
    re-scored deterministically (certainty.py adapters) — no schema migration, and the
    numbers stay recomputable from source (derived data, ARCHITECTURE immutability).
    The stored transcript isn't re-fetched: weekly aggregation cares about missing
    details and score bands, not per-utterance hedging.
    """
    day = _parse_day(date)
    tz_zone = _zone_or_none(tz) or await _user_tz(db, user_id)
    week_start_day = day - timedelta(days=6)
    start = datetime.combine(week_start_day, datetime.min.time(), tzinfo=tz_zone)
    end = datetime.combine(day, datetime.min.time(), tzinfo=tz_zone) + timedelta(days=1)

    rows = await MealsStore(db).list_between(user_id, start, end)
    scores: list[int] = []
    details_per_meal: list[list[str]] = []
    days_logged: set = set()
    total_kcal = 0.0
    for row in rows:
        items = [item_from_stored(i) for i in (row.get("items") or [])]
        scored = build_certainty(items, float(row.get("confidence") or 0.0), "")
        if items:
            scores.append(scored.score)
            details_per_meal.append(scored.missing_details)
        total_kcal += float((row.get("totals") or {}).get("kcal") or 0.0)
        days_logged.add(datetime.fromisoformat(row["logged_at"]).astimezone(tz_zone).date())

    sufficient = len(rows) >= 3
    detail, tip = weekly_focus(details_per_meal) if sufficient else (None, None)
    return WeeklySummary(
        week_start=week_start_day.isoformat(),
        week_end=day.isoformat(),
        meals_logged=len(rows),
        days_logged=len(days_logged),
        avg_kcal=round(total_kcal / len(days_logged)) if days_logged else None,
        avg_certainty=round(sum(scores) / len(scores)) if scores else None,
        most_common_missing_detail=detail,
        focus_tip=tip,
        sufficient_data=sufficient,
    )


@router.get("/usuals", response_model=list[SavedMeal])
async def list_usuals(user_id: CurrentUser, db: Db) -> list[SavedMeal]:
    """The user's saved meal templates ("usuals"), newest first — one-tap re-log.

    Registered BEFORE /{meal_id} (like /today and /summary) so the literal path isn't
    parsed as a meal UUID and 404'd. There is no "log a usual" endpoint on purpose:
    re-logging is a plain POST /meals carrying these items with a null parse_id, so a
    re-log goes through the SAME re-resolution and totals recompute as a spoken meal —
    a template can never write stale macros, and there is no second confirm path to
    drift (Non-Negotiable #6, RT-02).
    """
    rows = await MealsStore(db).list_saved_meals(user_id)
    return [SavedMeal.model_validate(row) for row in rows]


@router.delete("/usuals/{usual_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_usual(usual_id: str, user_id: CurrentUser, db: Db) -> None:
    """Forget a saved template. Hard delete — see MealsStore.delete_saved_meal for why a
    template is not a capture. Meals already logged from it are untouched."""
    try:
        uid = UUID(usual_id)
    except ValueError as e:
        # A non-UUID path id is simply "not found", never a 500 (mirrors delete_meal).
        raise HTTPException(status.HTTP_404_NOT_FOUND, "usual not found") from e
    if not await MealsStore(db).delete_saved_meal(uid, user_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "usual not found")


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
    stored_parse_id = existing.get("parse_id")
    items = await _reresolve(
        db,
        req.items,
        await _parse_transcript(db, UUID(stored_parse_id) if stored_parse_id else None, user_id),
    )
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


@router.post("/{meal_id}/append", response_model=MealLog)
async def append_to_meal(
    meal_id: str, req: AppendToMealRequest, user_id: CurrentUser, db: Db
) -> MealLog:
    """Append a new voice capture's items to an already-logged meal — the "add more"
    flow: open a meal, speak, and the items join THAT meal instead of minting a new
    one (beta feedback 2026-08-19: one-by-one loggers got a new "Meal N" per food,
    and the only fix was delete-and-redo).

    The appended utterance keeps its full capture → transcript → parse chain; only
    this derived meal_logs row changes (INVARIANTS §7: meal logs are recomputable
    projections — the raw artifacts stay append-only). Every appended item mints an
    ``item_appended`` corrections row, which is the durable audit/provenance record.
    """
    store = MealsStore(db)
    existing = await _load_owned_meal(store, meal_id, user_id)
    existing_items = [ConfirmedItem(**i) for i in (existing.get("items") or [])]

    # Idempotent replay: appended items are stamped with their source parse. A client
    # retry after a network flake (commit landed, response lost) finds this parse's
    # items already present and returns the meal unchanged instead of doubling food.
    if req.parse_id is not None and any(
        i.appended_from_parse == str(req.parse_id) for i in existing_items
    ):
        return await _to_response(store, existing)

    stamped = [
        item.model_copy(
            update={"appended_from_parse": str(req.parse_id) if req.parse_id else None}
        )
        for item in req.items
    ]
    merged = existing_items + stamped
    if len(merged) > 50:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "this meal is full - log the rest as a new meal",
        )

    # Composition needs BOTH utterances: "a turkey sandwich" logged first, then "with
    # the bread, turkey, and provolone" appended must compose exactly as one spoken
    # meal would (container zeroes, components carry) — so the re-resolve sees the
    # original and appended transcripts sentence-joined, mirroring the iOS amend flow.
    stored_parse_id = existing.get("parse_id")
    original_tx = await _parse_transcript(
        db, UUID(stored_parse_id) if stored_parse_id else None, user_id
    )
    appended_tx = await _parse_transcript(db, req.parse_id, user_id)
    transcript = ". ".join(t for t in (original_tx, appended_tx) if t)

    items = await _reresolve(db, merged, transcript)
    totals = _totals(items)
    confidence = _meal_confidence(items)
    meal_type = existing.get("meal_type") or MealType.UNSPECIFIED.value
    updated = await store.update_items(
        UUID(existing["id"]),
        user_id,
        items=[i.model_dump(mode="json") for i in items],
        totals=totals.model_dump(),
        confidence=confidence,
        name=existing.get("name"),
        meal_type=meal_type,
    )
    if updated is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "meal not found")

    base = len(existing_items)
    for offset, item in enumerate(items[base:]):
        await store.insert_correction(
            meal_log_id=existing["id"],
            item_index=base + offset,
            field="item_appended",
            parsed_value=None,
            confirmed_value=item.model_dump(mode="json"),
        )
    # [store]: ids/counts only; macro values stay out of server logs (MUST-NOT #5).
    _logger.info(
        "[store] meal=%s append parse=%s items+=%d confidence=%.2f",
        existing["id"], req.parse_id, len(stamped), confidence,
    )
    return MealLog(
        id=UUID(existing["id"]),
        name=existing.get("name"),
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

    # Pair confirmed items with parsed items by IDENTITY, not position: the client
    # splits water out and the user deletes/reorders, so a positional diff minted
    # corrections against the WRONG item (water(0) vs eggs(0) produced name/amount/
    # grams "corrections" nobody made — poisoning the training/audit table). Exact
    # normalized name claims first; unclaimed same-position slots cover in-place
    # renames; anything else is a user ADDITION (diff vs {}).
    def _name_key(value: object) -> str:
        return str(value or "").strip().lower()

    unclaimed = set(range(len(parsed_items)))
    matches: list[int | None] = [None] * len(items)
    for ci, confirmed in enumerate(items):
        key = _name_key(confirmed.name)
        for pi in range(len(parsed_items)):
            if pi in unclaimed and _name_key(parsed_items[pi].get("name")) == key:
                matches[ci] = pi
                unclaimed.discard(pi)
                break
    for ci in range(len(items)):
        if matches[ci] is None and ci in unclaimed:
            matches[ci] = ci
            unclaimed.discard(ci)

    count = 0
    for index, confirmed in enumerate(items):
        pi = matches[index]
        parsed = parsed_items[pi] if pi is not None else {}
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
    # Parsed items the user dropped before logging are their own signal: the parser
    # extracted something that wasn't kept. Water is EXCLUDED — the client routes it
    # to the hydration tally by design, so its absence here is routing, not a
    # correction (it would stamp "1 correction" on every water-containing meal).
    for pi in sorted(unclaimed):
        parsed_kcal = float(((parsed_items[pi].get("macros") or {}).get("kcal")) or 0.0)
        if parsed_kcal == 0.0 and "water" in _name_key(parsed_items[pi].get("name")):
            continue
        await store.insert_correction(
            meal_log_id=meal_log_id,
            item_index=pi,
            field="item_removed",
            parsed_value=_norm(parsed_items[pi].get("name")),
            confirmed_value=None,
        )
        CORRECTIONS.labels(field="item_removed").inc()
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


def _zone_or_none(name: str | None) -> ZoneInfo | None:
    """A ZoneInfo for a client-sent IANA name, or None (unknown/absent → profile path)."""
    if not name:
        return None
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return None


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
    """The user's active protocol row, read through ProtocolsStore.

    Today stays decoupled from the Phase F ENGINE (it only consumes the ``targets``
    jsonb), but it must share the STORE's read path: get_active self-heals the
    zero-active gap left by an interrupted supersede, and a raw table read here
    silently served STUB_TARGETS (2000 kcal / 120 g) on the one screen that most
    needed the real numbers (field incident 2026-08-19). Store = durable truth;
    the engine import boundary is unchanged.
    """
    return await ProtocolsStore(db).get_active(user_id)


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
