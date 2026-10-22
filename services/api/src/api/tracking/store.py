"""Durable-truth access for: tracking_preferences (append-only versions).

Stores answer "what is durably true?" and nothing else (AGENTS.md, deep couplings). The
projection of a mode onto screens lives in projection.py; the composition of Today in
meals/dashboard.py.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any
from uuid import UUID, uuid4

from ..db import (
    VERSION_APPEND_ATTEMPTS,
    SupportsDatabase,
    UniqueViolationError,
    VersionRaceLostError,
)
from .schemas import (
    FocusMetric,
    Friction,
    LogAnchor,
    NudgeLevel,
    PreferenceSource,
    TrackingMode,
    TrackingPreference,
)


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
        self, user_id: UUID, change: Callable[[TrackingPreference], TrackingPreference]
    ) -> dict[str, Any]:
        """Insert the next version: ``change`` applied to the latest. A concurrent write can take
        that version first; the unique (user_id, version) index refuses this insert and ``change``
        runs again on the new latest, so both writes land.

        The change must run inside the retry. When it ran once, before it, two concurrent PUTs
        (the mode, and the reminders) both answered 200 and the second version wrote back the
        stale value of the field the first had changed: 12 times in 12 against Postgres behind
        PostgREST (2026-10-22). Raises VersionRaceLostError (a 409) when every attempt lost."""
        for _ in range(VERSION_APPEND_ATTEMPTS):
            current = await self.latest(user_id)
            nxt = change(current)
            try:
                return await self._db.insert(
                    "tracking_preferences",
                    {
                        "id": str(uuid4()),
                        "user_id": str(user_id),
                        "version": current.version + 1,
                        "mode": nxt.mode.value,
                        "focus_metrics": [m.value for m in nxt.focus_metrics],
                        "declined_offers": [str(o) for o in nxt.declined_offers],
                        "source": nxt.source.value,
                        "nudge_level": nxt.nudge_level.value if nxt.nudge_level else None,
                        "frictions": [f.value for f in nxt.frictions],
                        "log_anchor": nxt.log_anchor.value if nxt.log_anchor else None,
                    },
                )
            except UniqueViolationError:
                continue
        raise VersionRaceLostError("tracking_preferences")


def preference_from_row(row: dict[str, Any]) -> TrackingPreference:
    """Lenient on jsonb shape: an unknown metric or mode in a stored list is dropped, never a
    500 on a read path (a future client may write a value this build does not know)."""
    return TrackingPreference(
        mode=_mode_or_default(row.get("mode")),
        focus_metrics=_enum_list(row.get("focus_metrics"), FocusMetric),
        declined_offers=[str(o) for o in (row.get("declined_offers") or []) if isinstance(o, str)],
        source=_source_or_chosen(row.get("source")),
        version=int(row.get("version") or 0),
        created_at=row.get("created_at"),
        nudge_level=_level_or_none(row.get("nudge_level")),
        frictions=_enum_list(row.get("frictions"), Friction),
        log_anchor=_anchor_or_none(row.get("log_anchor")),
    )


def _anchor_or_none(value: object) -> LogAnchor | None:
    if value is None:
        return None
    try:
        return LogAnchor(str(value))
    except ValueError:
        return None  # a later client's anchor reads as never asked, never a 500


def _level_or_none(value: object) -> NudgeLevel | None:
    if value is None:
        return None
    try:
        return NudgeLevel(str(value))
    except ValueError:
        return None


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
