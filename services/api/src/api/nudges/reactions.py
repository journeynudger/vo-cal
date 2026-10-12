"""How the person answered a nudge, and what the engine does about it (decision 67).

The store holds the answers (append-only, the person's record). ``effects`` is a pure function
from those rows to the engine's memory for this person: which nudges are silent, which are
muted, whose slot moved later, whose cooldown grew. The rules are the designer's, from Lorenzo's
own nudge policy ("When a nudge generates no response three times: Retire it. Don't escalate.")
and Serein's invitation layer ("If dismissed twice, decay aggressively."), encoded once here and
applied by nudges/engine.py; nothing here chooses words.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import Enum
from typing import Any
from uuid import UUID, uuid4

from pydantic import BaseModel, Field

from ..db import SupportsDatabase

# Three dismissals in a row with no act between: the nudge is silent for this long.
SILENCE_AFTER_DISMISSALS = 3
SILENCE_DAYS = 30
# "Wrong time" moves the slot an hour later, at most this many hours.
MAX_LATER_HOURS = 2
# "Too often" doubles the cooldown each time, at most this many times.
MAX_DOUBLINGS = 3


class ReactionKind(str, Enum):
    DISMISSED = "dismissed"
    ACTED = "acted"
    WRONG_TIME = "wrong_time"
    NOT_FOR_ME = "not_for_me"
    TOO_OFTEN = "too_often"
    UNMUTE = "unmute"


class ReactionRequest(BaseModel):
    """POST /nudges/reactions: one answer to one nudge."""

    nudge_id: str = Field(min_length=1, max_length=40)
    kind: ReactionKind


class MutedNudge(BaseModel):
    """A nudge the person said was not for them, as Settings lists it ("Muted", "Turn back on")."""

    id: str
    title: str


@dataclass(frozen=True)
class Effects:
    """The engine's memory for one person."""

    silenced: frozenset[str] = frozenset()
    muted: frozenset[str] = frozenset()
    # Hours to add to the nudge's slot (0, 1 or 2).
    later_hours: dict[str, int] = field(default_factory=dict)
    # The factor on the nudge's cooldown (1, 2, 4 or 8).
    cooldown_factor: dict[str, int] = field(default_factory=dict)

    def speaks(self, nudge_id: str) -> bool:
        return nudge_id not in self.silenced and nudge_id not in self.muted


class ReactionsStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def append(self, *, user_id: UUID, nudge_id: str, kind: ReactionKind) -> dict[str, Any]:
        return await self._db.insert(
            "nudge_reactions",
            {
                "id": str(uuid4()),
                "user_id": str(user_id),
                "nudge_id": nudge_id,
                "kind": kind.value,
            },
        )

    async def rows(self, user_id: UUID) -> list[dict[str, Any]]:
        return await self._db.select("nudge_reactions", {}, user_id=user_id)


def effects(rows: list[dict[str, Any]], now: datetime) -> Effects:
    """The rules, once. Rows this build cannot read (an unknown kind, no timestamp) are skipped,
    never a 500 on the plan path."""
    by_nudge: dict[str, list[tuple[datetime, ReactionKind]]] = {}
    for row in rows:
        kind = _kind(row.get("kind"))
        when = _when(row.get("created_at"), now)
        nudge_id = row.get("nudge_id")
        if kind is None or when is None or not isinstance(nudge_id, str):
            continue
        by_nudge.setdefault(nudge_id, []).append((when, kind))

    silenced: set[str] = set()
    muted: set[str] = set()
    later: dict[str, int] = {}
    factor: dict[str, int] = {}
    for nudge_id, answers in by_nudge.items():
        answers.sort(key=lambda a: a[0])
        # Muted: the latest of "not for me" and "unmute" decides.
        last_mute = max((w for w, k in answers if k is ReactionKind.NOT_FOR_ME), default=None)
        last_unmute = max((w for w, k in answers if k is ReactionKind.UNMUTE), default=None)
        if last_mute is not None and (last_unmute is None or last_mute > last_unmute):
            muted.add(nudge_id)
        # Silenced: dismissals since the last act, three or more, the latest inside the window.
        since_act = []
        for when, kind in answers:
            if kind is ReactionKind.ACTED:
                since_act = []
            elif kind is ReactionKind.DISMISSED:
                since_act.append(when)
        if len(since_act) >= SILENCE_AFTER_DISMISSALS and now - since_act[-1] <= timedelta(days=SILENCE_DAYS):
            silenced.add(nudge_id)
        wrong = sum(1 for _, k in answers if k is ReactionKind.WRONG_TIME)
        if wrong:
            later[nudge_id] = min(wrong, MAX_LATER_HOURS)
        often = sum(1 for _, k in answers if k is ReactionKind.TOO_OFTEN)
        if often:
            factor[nudge_id] = 2 ** min(often, MAX_DOUBLINGS)
    return Effects(
        silenced=frozenset(silenced),
        muted=frozenset(muted),
        later_hours=later,
        cooldown_factor=factor,
    )


def _kind(value: object) -> ReactionKind | None:
    try:
        return ReactionKind(str(value))
    except ValueError:
        return None


def _when(value: object, now: datetime) -> datetime | None:
    if isinstance(value, datetime):
        when = value
    elif isinstance(value, str):
        try:
            when = datetime.fromisoformat(value)
        except ValueError:
            return None
    else:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=now.tzinfo)
    return when
