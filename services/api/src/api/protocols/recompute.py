"""Recompute all active protocols against the current engine (maintenance pass).

Why this exists: the 2026-07 calorie fixes (the auto-deficit cap; sex plumbing) changed
what the engine produces for a given intake. Protocols generated BEFORE the fix keep
their stale targets until the user regenerates — a user who set up during the bug is
stuck on ~1690 kcal forever unless something recomputes them. This pass re-runs
``compute_protocol`` over every user's LATEST intake and supersedes the active protocol
only where the numbers actually moved.

Determinism + immutability (AGENTS.md #6, #5): the engine is pure, so this is safe and
idempotent — a correct protocol recomputes to itself and is left untouched (no version
churn). A changed protocol is SUPERSEDED (new immutable version), never rewritten in
place. Owner scoping is preserved: each supersede runs under its own user_id.

This is a service-role sweep (reads every user's rows via ``user_id=None``); it is only
ever reached through the admin-gated, audit-logged endpoint in ``admin/router.py``.
"""

from __future__ import annotations

import logging
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ValidationError

from ..db import SupportsDatabase
from ..intake.store import IntakeStore
from .engine import compute_protocol
from .schemas import IntakeProfile, ProtocolTargets
from .store import ProtocolsStore
from .why import build_whys

_logger = logging.getLogger(__name__)

# The nutrition numbers that define a protocol. If none of these move, the stored
# protocol already matches the current engine and is left alone (no new version).
_COMPARE_FIELDS = (
    "kcal", "protein", "protein_min", "protein_max", "carbs", "fat",
    "fiber", "water_oz", "produce_servings", "meals_per_day",
)


class ProtocolChange(BaseModel):
    """One corrected protocol (protocol id only — no user identity in the payload)."""

    protocol_id: str
    old_kcal: int
    new_kcal: int
    new_version: int


class RecomputeResult(BaseModel):
    """Summary of a recompute sweep. Counts + a bounded sample of changes."""

    scanned: int
    corrected: int
    unchanged: int
    skipped_no_intake: int
    skipped_invalid_intake: int
    dry_run: bool
    changes: list[ProtocolChange]


def _targets_json(targets: ProtocolTargets, whys: dict[str, str]) -> dict[str, Any]:
    """Serialize targets (+whys) to the stored jsonb shape — mirrors protocols/router.py."""
    return targets.model_copy(update={"whys": whys}).model_dump(mode="json")


def _changed(stored: ProtocolTargets, fresh: ProtocolTargets) -> bool:
    return any(getattr(stored, f) != getattr(fresh, f) for f in _COMPARE_FIELDS)


async def recompute_active_protocols(
    db: SupportsDatabase, *, dry_run: bool = False, sample_limit: int = 50
) -> RecomputeResult:
    """Re-run the engine over every active protocol; supersede only where targets moved.

    ``dry_run`` computes and counts but writes nothing — a safe preview before committing.
    A protocol with no recoverable intake (older accounts, or intake never completed) is
    counted and skipped, never guessed. The sweep is idempotent: a second run over the
    same data reports everything unchanged.
    """
    protocols_store = ProtocolsStore(db)
    intake_store = IntakeStore(db)

    # Service-role read: every active protocol across all users (user_id=None = unscoped).
    active_rows = await db.select("protocols", {"active": True}, user_id=None)

    scanned = corrected = unchanged = skipped_no_intake = skipped_invalid = 0
    changes: list[ProtocolChange] = []

    for row in active_rows:
        scanned += 1
        user_id = UUID(str(row["user_id"]))

        intake_row = await intake_store.latest(user_id)
        if intake_row is None:
            skipped_no_intake += 1
            continue
        try:
            profile = IntakeProfile.model_validate(intake_row["answers"])
        except ValidationError:
            # A malformed/legacy intake is not something to guess around — leave the
            # protocol as-is and count it so the sweep's totals stay honest.
            skipped_invalid += 1
            continue

        try:
            stored = ProtocolTargets.model_validate(_with_whys(row["targets"], row.get("whys")))
        except ValidationError:
            skipped_invalid += 1
            continue

        computation = compute_protocol(profile)
        fresh = computation.targets
        if not _changed(stored, fresh):
            unchanged += 1
            continue

        corrected += 1
        if len(changes) < sample_limit:
            changes.append(
                ProtocolChange(
                    protocol_id=str(row["id"]),
                    old_kcal=stored.kcal,
                    new_kcal=fresh.kcal,
                    new_version=int(row["version"]) + 1,
                )
            )
        if not dry_run:
            whys = build_whys(profile, computation.facts, fresh)
            await protocols_store.supersede(
                user_id=user_id,
                targets=_targets_json(fresh, whys),
                whys=whys,
            )

    _logger.info(
        "[recompute] scanned=%d corrected=%d unchanged=%d no_intake=%d invalid=%d dry_run=%s",
        scanned, corrected, unchanged, skipped_no_intake, skipped_invalid, dry_run,
    )
    return RecomputeResult(
        scanned=scanned,
        corrected=corrected,
        unchanged=unchanged,
        skipped_no_intake=skipped_no_intake,
        skipped_invalid_intake=skipped_invalid,
        dry_run=dry_run,
        changes=changes,
    )


def _with_whys(targets: dict[str, Any], whys: dict[str, Any] | None) -> dict[str, Any]:
    merged = dict(targets)
    if whys:
        merged["whys"] = whys
    return merged
