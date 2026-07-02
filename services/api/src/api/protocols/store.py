"""Durable-truth access for: protocols.

Stores answer "what is durably true?" — no planning, no side effects beyond the
database (AGENTS.md, deep couplings). Protocol rows are IMMUTABLE except the
``active`` flag (decision #19): a new version is an insert with ``supersedes``
pointing at the prior row, and the prior row's ``active`` flag flips to false.
Targets are NEVER rewritten in place — that is the audit/immutability invariant.

The migration enforces one active protocol per user (partial unique index on
``active``); ``supersede`` deactivates the old row BEFORE inserting the new active
one so the invariant holds at every step. FakeDatabase mirrors RLS owner scoping,
so the same code is exercised offline and against the live DB.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID, uuid4

from ..db import SupportsDatabase


class ProtocolsStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def get_active(self, user_id: UUID) -> dict[str, Any] | None:
        """The user's single active protocol, or None if they have none yet."""
        rows = await self._db.select("protocols", {"active": True}, user_id=user_id)
        return rows[0] if rows else None

    async def insert(
        self,
        *,
        user_id: UUID,
        version: int,
        targets: dict[str, Any],
        whys: dict[str, str],
        supersedes: UUID | None = None,
        active: bool = True,
    ) -> dict[str, Any]:
        """Insert a new immutable protocol row. Caller deactivates the prior row
        first (see ``supersede``) so the one-active invariant is never violated.

        The row ``version`` is authoritative; we stamp it into the embedded targets
        jsonb too so a consumer reading only ``targets`` sees the same version as the
        column (the iOS ProtocolTargets carries version inline)."""
        stamped_targets = {**targets, "version": version}
        return await self._db.insert(
            "protocols",
            {
                "id": str(uuid4()),
                "user_id": str(user_id),
                "version": version,
                "supersedes": str(supersedes) if supersedes else None,
                "active": active,
                "targets": stamped_targets,
                "whys": whys,
            },
        )

    async def supersede(
        self,
        *,
        user_id: UUID,
        targets: dict[str, Any],
        whys: dict[str, str],
    ) -> dict[str, Any]:
        """Create the next version: deactivate any current active row, then insert
        a new active row whose ``supersedes`` points at the old one.

        First protocol (no active row) inserts version 1 with no supersedes. A
        revision inserts version n+1 pointing at the prior id. Deactivation happens
        BEFORE the insert so the partial unique index never sees two active rows.
        """
        current = await self.get_active(user_id)
        if current is None:
            return await self.insert(
                user_id=user_id, version=1, targets=targets, whys=whys, active=True
            )

        await self._db.update(
            "protocols",
            {"id": current["id"]},
            {"active": False},
            user_id=user_id,
        )
        return await self.insert(
            user_id=user_id,
            version=int(current["version"]) + 1,
            targets=targets,
            whys=whys,
            supersedes=UUID(current["id"]),
            active=True,
        )
