"""Durable-truth access for: tracking_preferences (append-only versions).

Stores answer "what is durably true?" and nothing else (AGENTS.md, deep couplings). The
projection of a mode onto screens lives in projection.py; the composition of Today in
meals/dashboard.py.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID, uuid4

from ..db import SupportsDatabase, UniqueViolationError
from .schemas import FocusMetric, PreferenceSource, TrackingMode, TrackingPreference


class TrackingStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def latest_row(self, user_id: UUID) -> dict[str, Any] | None:
        rows = await self._db.select("tracking_preferences", {}, user_id=user_id)
        return max(rows, key=lambda r: int(r["version"])) if rows else None

    async def latest(self, user_id: UUID) -> TrackingPreference:
        """The person's current preference, or the default (version 0, mode five) when they
        never chose: every account from before 2026-10-04 keeps today's dashboard."""
        row = await self.latest_row(user_id)
        if row is None:
            return TrackingPreference(
                mode=TrackingMode.FIVE, source=PreferenceSource.DEFAULT, version=0
            )
        return preference_from_row(row)

    async def append(
        self,
        *,
        user_id: UUID,
        mode: TrackingMode,
        focus_metrics: list[FocusMetric],
        declined_modes: list[TrackingMode],
        source: PreferenceSource,
    ) -> dict[str, Any]:
        """Insert the next version. A concurrent append races the unique (user_id, version)
        index; one retry re-reads and takes the next number, like the protocols store."""
        last: UniqueViolationError | None = None
        for _ in range(2):
            previous = await self.latest_row(user_id)
            version = int(previous["version"]) + 1 if previous else 1
            try:
                return await self._db.insert(
                    "tracking_preferences",
                    {
                        "id": str(uuid4()),
                        "user_id": str(user_id),
                        "version": version,
                        "mode": mode.value,
                        "focus_metrics": [m.value for m in focus_metrics],
                        "declined_modes": [m.value for m in declined_modes],
                        "source": source.value,
                    },
                )
            except UniqueViolationError as exc:
                last = exc
        raise last if last else RuntimeError("unreachable")


def preference_from_row(row: dict[str, Any]) -> TrackingPreference:
    """Lenient on jsonb shape: an unknown metric or mode in a stored list is dropped, never a
    500 on a read path (a future client may write a value this build does not know)."""
    return TrackingPreference(
        mode=_mode_or_default(row.get("mode")),
        focus_metrics=_enum_list(row.get("focus_metrics"), FocusMetric),
        declined_modes=_enum_list(row.get("declined_modes"), TrackingMode),
        source=_source_or_chosen(row.get("source")),
        version=int(row.get("version") or 0),
        created_at=row.get("created_at"),
    )


def _mode_or_default(value: object) -> TrackingMode:
    try:
        return TrackingMode(str(value))
    except ValueError:
        return TrackingMode.FIVE


def _source_or_chosen(value: object) -> PreferenceSource:
    try:
        return PreferenceSource(str(value))
    except ValueError:
        return PreferenceSource.CHOSEN


def _enum_list(values: object, enum_type: type) -> list:
    out: list = []
    for value in values if isinstance(values, list) else []:
        try:
            out.append(enum_type(str(value)))
        except ValueError:
            continue
    return out
