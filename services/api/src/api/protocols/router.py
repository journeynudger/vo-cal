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

from ..checkin.recommend import build_recal_inputs, recommend
from ..checkin.router import load_recal_context
from ..dependencies import CurrentUser, Db
from .engine import compute_protocol
from .schemas import (
    GenerateProtocolRequest,
    GenerateProtocolResponse,
    ProtocolTargets,
)
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

    # Deterministic "why" per target (always works; AI phrasing is a later layer).
    whys = build_whys(profile, computation.facts, computation.targets)

    store = ProtocolsStore(db)
    # supersede() owns versioning: v1 first time, deactivate-old + vN+1 on a revision.
    row = await store.supersede(
        user_id=user_id,
        targets=_targets_json(computation.targets, whys),
        whys=whys,
    )
    targets = _stamp(computation.targets, version=int(row["version"]), whys=whys)
    return GenerateProtocolResponse(
        protocol_id=row["id"],
        version=int(row["version"]),
        active=bool(row["active"]),
        targets=targets,
    )


@router.get("/active", response_model=GenerateProtocolResponse)
async def active(user_id: CurrentUser, db: Db) -> GenerateProtocolResponse:
    """The user's current active protocol, or 404 if they have not generated one."""
    row = await ProtocolsStore(db).get_active(user_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no active protocol")
    targets = ProtocolTargets.model_validate(_with_whys(row["targets"], row.get("whys")))
    return GenerateProtocolResponse(
        protocol_id=row["id"],
        version=int(row["version"]),
        active=bool(row["active"]),
        targets=targets,
    )


@router.post("/{protocol_id}/revise", response_model=GenerateProtocolResponse)
async def revise(protocol_id: UUID, user_id: CurrentUser, db: Db) -> GenerateProtocolResponse:
    """Apply the current monthly recalibration to the active protocol (Phase G).

    Re-runs the recalibration engine server-side from durable rows (never trusts client
    numbers), and if it proposes new targets, supersedes the active protocol with them:
    calories/protein/water/fiber move, the other targets + whys carry over. HOLD/DIAGNOSTICS
    branches make no change (409). ``protocol_id`` must be the caller's active protocol.
    """
    store = ProtocolsStore(db)
    active = await store.get_active(user_id)
    if active is None or str(active["id"]) != str(protocol_id):
        raise HTTPException(status.HTTP_409_CONFLICT, "not the active protocol")

    profile, _active, checkin = await load_recal_context(db, user_id)
    rec = recommend(
        build_recal_inputs(
            intake_profile=profile,
            active_kcal=int(active["targets"]["kcal"]),
            current_weight_kg=float(checkin["weight_kg"]),
            adherence_self=int(checkin["adherence_self"]),
        )
    )
    if rec.targets is None:
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"no revision recommended ({rec.kind.value})"
        )

    current = ProtocolTargets.model_validate(_with_whys(active["targets"], active.get("whys")))
    # Reconcile carbs to the new calorie budget (fat is bodyweight-based and unchanged by a
    # recalibration). Without this, carbs/fat carry over stale and the stored macros no longer
    # sum to kcal (PROTOCOL_LOGIC §4: carbs are the remainder). Clamp at 0 like the engine.
    new_carbs = max(
        0, round((rec.targets.target_kcal - rec.targets.protein_g * 4 - current.fat * 9) / 4)
    )
    revised = current.model_copy(
        update={
            "kcal": rec.targets.target_kcal,
            "protein": rec.targets.protein_g,
            "carbs": new_carbs,
            "water_oz": rec.targets.water_oz,
            "fiber": rec.targets.fiber_g,
        }
    )
    new_row = await store.supersede(
        user_id=user_id,
        targets=_targets_json(revised, revised.whys),
        whys=revised.whys,
    )
    return GenerateProtocolResponse(
        protocol_id=new_row["id"],
        version=int(new_row["version"]),
        active=bool(new_row["active"]),
        targets=_stamp(revised, version=int(new_row["version"]), whys=revised.whys),
    )


# -- helpers -----------------------------------------------------------------


def _targets_json(targets: ProtocolTargets, whys: dict[str, str]) -> dict:
    """Serialize targets (with whys) to the stored/iOS shape (camelCase aliases).

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
