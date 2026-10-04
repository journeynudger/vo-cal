"""Protocols routes — Phase F3 (deterministic protocol engine).

POST /protocols/generate — intake answers -> deterministic compute -> deterministic
"why" fallback -> store as the new active version (supersedes the prior) -> return
the targets + whys. GET /protocols/active — the current active protocol.

Orchestration only (parser/router.py pattern): the math is in engine.py, the prose
in why.py, durability in store.py. This router computes nothing itself (AGENTS.md #6).
The "why" layer here is the deterministic fallback; the AI phrasing enhancement
(decision #10) slots in front of ``build_whys`` later without touching the contract.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, HTTPException, status

from ..checkin.recommend import recommend
from ..checkin.router import load_recal_context, recal_inputs_from_rows
from ..dependencies import CurrentUser, Db
from ..tracking.projection import projection_for
from ..tracking.schemas import TrackingMode
from ..tracking.store import TrackingStore
from .engine import compute_protocol
from .schemas import (
    GenerateProtocolRequest,
    GenerateProtocolResponse,
    ProtocolTargets,
)
from .staleness import needs_recalibration, parse_created_at
from .store import ProtocolsStore
from .why import build_whys

router = APIRouter(prefix="/protocols", tags=["protocols"])


@router.post(
    "/generate", response_model=GenerateProtocolResponse, status_code=status.HTTP_201_CREATED
)
async def generate(
    req: GenerateProtocolRequest, user_id: CurrentUser, db: Db
) -> GenerateProtocolResponse:
    """Compute and persist the user's new active protocol from intake answers."""
    profile = req.intake
    computation = compute_protocol(profile)
    # The inferred coach inputs ride with the targets so a recalibration titrates from them
    # (PROTOCOL_LOGIC §3.3) instead of re-deriving the deficit the person already moved.
    targets = computation.targets.model_copy(
        update={
            "reduce_pct": computation.facts.reduce_pct,
            "activity_level": computation.facts.activity_level,
        }
    )

    # Deterministic "why" per target (always works; AI phrasing is a later layer).
    whys = build_whys(profile, computation.facts, targets)

    store = ProtocolsStore(db)
    # supersede() owns versioning: v1 first time, deactivate-old + vN+1 on a revision.
    row = await store.supersede(
        user_id=user_id,
        targets=_targets_json(targets, whys),
        whys=whys,
    )
    mode = req.mode or (await TrackingStore(db).latest(user_id)).mode
    return _response(
        row, _stamp(targets, version=int(row["version"]), whys=whys), reveal=_reveal(mode)
    )


@router.get("/active", response_model=GenerateProtocolResponse)
async def active(user_id: CurrentUser, db: Db) -> GenerateProtocolResponse:
    """The user's current active protocol, or 404 if they have not generated one."""
    row = await ProtocolsStore(db).get_active(user_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no active protocol")
    targets = ProtocolTargets.model_validate(_with_whys(row["targets"], row.get("whys")))
    mode = (await TrackingStore(db).latest(user_id)).mode
    return _response(row, targets, reveal=_reveal(mode))


@router.post("/{protocol_id}/revise", response_model=GenerateProtocolResponse)
async def revise(protocol_id: UUID, user_id: CurrentUser, db: Db) -> GenerateProtocolResponse:
    """Apply the current recalibration to the active protocol (decision 64).

    Re-runs the titration server-side from durable rows (never trusts client numbers). When it
    proposes a step, the engine has already recomputed the WHOLE protocol at the current weight
    with the titrated deficit, so calories, protein and its band, carbs, fat, fiber, produce,
    water and the whys are one protocol; it supersedes the active row. HOLD and DIAGNOSTICS
    make no change (409). ``protocol_id`` must be the caller's active protocol.
    """
    store = ProtocolsStore(db)
    active = await store.get_active(user_id)
    if active is None or str(active["id"]) != str(protocol_id):
        raise HTTPException(status.HTTP_409_CONFLICT, "not the active protocol")

    profile, _active, checkin = await load_recal_context(db, user_id)
    rec = recommend(recal_inputs_from_rows(profile, active, checkin))
    if rec.computation is None:
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"no revision recommended ({rec.kind.value})"
        )

    computation = rec.computation
    targets = computation.targets.model_copy(
        update={
            "reduce_pct": computation.facts.reduce_pct,
            "activity_level": computation.facts.activity_level,
        }
    )
    # The whys read the weight the protocol was built from: the check-in's, not the intake's.
    at_weight = profile.model_copy(update={"weight_lb": round(float(checkin["weight_kg"]) * 2.2046226218, 1)})
    whys = build_whys(at_weight, computation.facts, targets)
    new_row = await store.supersede(
        user_id=user_id,
        targets=_targets_json(targets, whys),
        whys=whys,
    )
    mode = (await TrackingStore(db).latest(user_id)).mode
    return _response(
        new_row, _stamp(targets, version=int(new_row["version"]), whys=whys), reveal=_reveal(mode)
    )


# -- helpers -----------------------------------------------------------------


def _response(
    row: dict, targets: ProtocolTargets, *, reveal: list[str] | None = None
) -> GenerateProtocolResponse:
    """One response shape for all three routes, so a protocol's age always travels
    with it — including on generate/revise, where the same code path is what proves a
    freshly written protocol is never served as stale."""
    created_at = parse_created_at(row.get("created_at"))
    return GenerateProtocolResponse(
        protocol_id=row["id"],
        version=int(row["version"]),
        active=bool(row["active"]),
        targets=targets,
        created_at=created_at,
        needs_recalibration=needs_recalibration(created_at),
        reveal=list(reveal or []),
    )


def _reveal(mode: TrackingMode) -> list[str]:
    return list(projection_for(mode).reveal_keys)


def _targets_json(targets: ProtocolTargets, whys: dict[str, str]) -> dict:
    """Serialize targets (with whys) to the stored/iOS shape (snake_case keys).

    The version stamped here is provisional (1); the store's supersede() returns the
    authoritative version, which the response re-stamps. The stored ``targets`` jsonb
    keeps whatever version was inserted — consistent because supersede sets it.
    """
    stamped = targets.model_copy(update={"whys": whys})
    return stamped.model_dump(mode="json")


def _stamp(targets: ProtocolTargets, *, version: int, whys: dict[str, str]) -> ProtocolTargets:
    return targets.model_copy(update={"version": version, "whys": whys})


def _with_whys(targets: dict, whys: dict | None) -> dict:
    """Reattach the dedicated ``whys`` jsonb column onto the targets dict for the
    response model. Targets already embed whys, but the standalone column is the
    source of truth if the two ever diverge in storage."""
    merged = dict(targets)
    if whys:
        merged["whys"] = whys
    return merged
