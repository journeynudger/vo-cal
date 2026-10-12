"""Intent to effect and answer (decision 71, spec 5.4). Deterministic, through the stores
Settings already writes: a setting said is the same record as a setting tapped."""

from __future__ import annotations

from datetime import date
from uuid import UUID
from zoneinfo import ZoneInfo

from ..db import SupportsDatabase
from ..meals.router import today_for
from ..nudges.catalog import CATALOG
from ..nudges.reactions import ReactionKind, ReactionRequest, ReactionsStore
from ..tracking.router import apply_update
from ..tracking.schemas import TrackingPreference, TrackingUpdate
from ..tracking.store import TrackingStore
from . import lines
from .schemas import (
    AssistChange,
    AssistPointer,
    AssistReply,
    AssistTurn,
    AssistUndo,
    Intent,
    ReplyKind,
)


def _reply(kind: ReplyKind, line: str, **fields: object) -> AssistReply:
    return AssistReply(kind=kind, line=line, turn=AssistTurn(role="app", text=line), **fields)  # type: ignore[arg-type]


def _told(line: str, change: AssistChange | None = None) -> AssistReply:
    return _reply("told", line, change=change)


async def answer(
    db: SupportsDatabase, user_id: UUID, intent: Intent, *, day: date, tz_zone: ZoneInfo
) -> AssistReply:
    """The one dispatch. Every branch returns a reply whose line is the catalog's."""
    if intent.kind == "meal":
        return _reply("meal", lines.MEAL)
    if intent.kind == "other":
        return _told(lines.OTHER)
    if intent.kind == "show":
        return await _show(db, user_id, intent, day=day, tz_zone=tz_zone)
    if intent.kind in ("mute", "unmute"):
        return await _mute(db, user_id, intent)
    current = await TrackingStore(db).latest(user_id)
    if intent.kind == "set_mode":
        return await _set_mode(db, user_id, intent, current)
    if intent.kind == "set_focus":
        return await _set_focus(db, user_id, intent, current)
    if intent.kind == "set_level":
        return await _set_level(db, user_id, intent, current)
    if intent.kind == "set_anchor":
        return await _set_anchor(db, user_id, intent, current)
    return await _set_frictions(db, user_id, intent, current)


async def _set_mode(db: SupportsDatabase, user_id: UUID, intent: Intent, current: TrackingPreference) -> AssistReply:
    if intent.mode is None:
        return _told(lines.OTHER)
    row = AssistChange(icon="slider.horizontal.3", title="How I track", value=lines.MODE_SHORT[intent.mode])
    if intent.mode is current.mode:
        return _told(lines.mode_already(intent.mode), row)
    await apply_update(db, user_id, TrackingUpdate(mode=intent.mode))
    return _reply(
        "changed", lines.mode_changed(intent.mode), change=row,
        undo=AssistUndo(tracking=TrackingUpdate(mode=current.mode)),
    )


async def _set_focus(db: SupportsDatabase, user_id: UUID, intent: Intent, current: TrackingPreference) -> AssistReply:
    focus = [m for m in current.focus_metrics if m not in intent.focus_remove]
    focus += [m for m in intent.focus_add if m not in focus]
    value = ", ".join(lines.FOCUS_LABELS[m] for m in focus) or lines.NOTHING_EXTRA
    row = AssistChange(icon="plus.circle", title="Also show", value=value)
    if focus == current.focus_metrics:
        if intent.focus_add:
            return _told(lines.focus_already_on(intent.focus_add[0]), row)
        if intent.focus_remove:
            return _told(lines.focus_already_off(intent.focus_remove[0]), row)
        return _told(lines.OTHER)
    await apply_update(db, user_id, TrackingUpdate(focus_metrics=focus))
    line = lines.focus_on(intent.focus_add[0]) if intent.focus_add else lines.focus_off(intent.focus_remove[0])
    return _reply(
        "changed", line, change=row,
        undo=AssistUndo(tracking=TrackingUpdate(focus_metrics=list(current.focus_metrics))),
    )


async def _set_level(db: SupportsDatabase, user_id: UUID, intent: Intent, current: TrackingPreference) -> AssistReply:
    if intent.level is None:
        return _told(lines.OTHER)
    row = AssistChange(icon="bell", title="Reminders", value=lines.LEVEL_SHORT[intent.level])
    if intent.level is current.nudge_level:
        return _told(lines.LEVEL_LINES[intent.level], row)
    await apply_update(db, user_id, TrackingUpdate(nudge_level=intent.level))
    # A level never chosen cannot be put back to "never asked" (None keeps); no Undo then.
    undo = AssistUndo(tracking=TrackingUpdate(nudge_level=current.nudge_level)) if current.nudge_level else None
    return _reply("changed", lines.LEVEL_LINES[intent.level], change=row, undo=undo)


async def _set_anchor(db: SupportsDatabase, user_id: UUID, intent: Intent, current: TrackingPreference) -> AssistReply:
    if intent.anchor is None:
        return _told(lines.OTHER)
    row = AssistChange(icon="clock", title="When you log", value=lines.ANCHOR_SHORT[intent.anchor])
    if intent.anchor is current.log_anchor:
        return _told(lines.anchor_line(intent.anchor), row)
    await apply_update(db, user_id, TrackingUpdate(log_anchor=intent.anchor))
    undo = AssistUndo(tracking=TrackingUpdate(log_anchor=current.log_anchor)) if current.log_anchor else None
    return _reply("changed", lines.anchor_line(intent.anchor), change=row, undo=undo)


async def _set_frictions(db: SupportsDatabase, user_id: UUID, intent: Intent, current: TrackingPreference) -> AssistReply:
    frictions = [f for f in current.frictions if f not in intent.frictions_remove]
    frictions += [f for f in intent.frictions_add if f not in frictions]
    value = ", ".join(lines.FRICTION_TITLES[f] for f in frictions) or lines.NOTHING
    row = AssistChange(icon="hand.raised", title="What gets in the way", value=value)
    if frictions == current.frictions:
        if intent.frictions_add:
            return _told(lines.friction_added(intent.frictions_add[0]), row)
        if intent.frictions_remove:
            return _told(lines.friction_removed(intent.frictions_remove[0]), row)
        return _told(lines.OTHER)
    await apply_update(db, user_id, TrackingUpdate(frictions=frictions))
    line = (
        lines.friction_added(intent.frictions_add[0]) if intent.frictions_add
        else lines.friction_removed(intent.frictions_remove[0])
    )
    return _reply(
        "changed", line, change=row,
        undo=AssistUndo(tracking=TrackingUpdate(frictions=list(current.frictions))),
    )


async def _mute(db: SupportsDatabase, user_id: UUID, intent: Intent) -> AssistReply:
    if intent.subject is None:
        return _told(lines.OTHER)
    ids = [n.id for n in CATALOG if n.category == intent.subject]
    if not ids:
        return _told(lines.OTHER)
    quiet = intent.kind == "mute"
    kind = ReactionKind.NOT_FOR_ME if quiet else ReactionKind.UNMUTE
    opposite = ReactionKind.UNMUTE if quiet else ReactionKind.NOT_FOR_ME
    store = ReactionsStore(db)
    for nudge_id in ids:
        await store.append(user_id=user_id, nudge_id=nudge_id, kind=kind)
    title = lines.muted_value(intent.subject)
    row = AssistChange(
        icon="bell.slash", title="Muted", value=title if quiet else f"{title} back on"
    )
    return _reply(
        "changed", lines.muted(intent.subject) if quiet else lines.unmuted(intent.subject), change=row,
        undo=AssistUndo(reactions=[ReactionRequest(nudge_id=i, kind=opposite) for i in ids]),
    )


async def _show(
    db: SupportsDatabase, user_id: UUID, intent: Intent, *, day: date, tz_zone: ZoneInfo
) -> AssistReply:
    if intent.show is None:
        return _told(lines.OTHER)
    if intent.show in lines.METRICS:
        metric, label = lines.METRICS[intent.show]
        today = await today_for(db, user_id, day, tz_zone)
        # Habits prints no number anywhere (decision 58): the line names the switch, never
        # a number the person chose not to see.
        if not today.prints_numbers:
            return _told(lines.NO_NUMBERS)
        panel = next((p for p in today.panels if p.metric == metric), None)
        if panel is None:
            return _told(lines.not_on_today(label))
        return _reply("shown", lines.shown(label), panel=panel)
    surface = intent.show
    return _reply(
        "pointed", lines.POINTER_LINES[surface],
        pointer=AssistPointer(surface=surface, title=lines.POINTER_TITLES[surface]),  # type: ignore[arg-type]
    )
