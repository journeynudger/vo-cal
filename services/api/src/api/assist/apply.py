"""Intent to effect and answer (decision 71, spec 5.4). Deterministic, through the stores
Settings already writes: a setting said is the same record as a setting tapped."""

from __future__ import annotations

from datetime import UTC, date, datetime
from uuid import UUID
from zoneinfo import ZoneInfo

from ..db import SupportsDatabase
from ..meals.router import today_for
from ..nudges.catalog import CATALOG
from ..nudges.reactions import ReactionKind, ReactionRequest, ReactionsStore, effects
from ..tracking.projection import projection_for
from ..tracking.router import apply_update
from ..tracking.schemas import NudgeLevel, TrackingPreference, TrackingUpdate, offer_key
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


def _consumed(current: TrackingPreference, key: str) -> str | None:
    """``key`` when choosing it by hand removes a "Don't offer this again" (tracking/router.py),
    so the Undo puts the decline back with the rest; None otherwise."""
    return key if key in current.declined_offers else None


def _distinct(values: list) -> list:
    """In order, once each: a model form may repeat a value, and a list is stored as given."""
    return list(dict.fromkeys(values))


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
    undo = TrackingUpdate(
        mode=current.mode,
        # Moving into habits empties "Also show" (tracking/router.py), so Undo carries it back.
        focus_metrics=list(current.focus_metrics),
        decline_offer=_consumed(current, offer_key(mode=intent.mode)),
    )
    return _reply("changed", lines.mode_changed(intent.mode), change=row, undo=AssistUndo(tracking=undo))


async def _set_focus(db: SupportsDatabase, user_id: UUID, intent: Intent, current: TrackingPreference) -> AssistReply:
    # A tile the mode itself prints is on Today whatever "Also show" holds: adding it changed
    # nothing on the page, and taking it off was answered "Protein isn't on Today." beside the
    # protein tile (2026-10-22). Neither writes.
    own = set(projection_for(current.mode).own_metrics)
    owned_off = [m for m in intent.focus_remove if m.value in own]
    if owned_off and not intent.focus_add:
        return _told(lines.own_tile(owned_off[0], current.mode))
    adds = _distinct([m for m in intent.focus_add if m.value not in own])
    removes = [m for m in intent.focus_remove if m.value not in own]
    if intent.focus_add and not adds:
        return _told(lines.focus_already_on(intent.focus_add[0]))
    focus = [m for m in current.focus_metrics if m not in removes]
    focus += [m for m in adds if m not in focus]
    value = ", ".join(lines.FOCUS_LABELS[m] for m in focus) or lines.NOTHING_EXTRA
    row = AssistChange(icon="plus.circle", title="Also show", value=value)
    if focus == current.focus_metrics:
        if adds:
            return _told(lines.focus_already_on(adds[0]), row)
        if removes:
            return _told(lines.focus_already_off(removes[0]), row)
        return _told(lines.OTHER)
    await apply_update(db, user_id, TrackingUpdate(focus_metrics=focus))
    line = lines.focus_on(adds[0]) if adds else lines.focus_off(removes[0])
    declined = next(
        (key for key in (_consumed(current, offer_key(focus=m)) for m in adds) if key), None
    )
    undo = TrackingUpdate(focus_metrics=list(current.focus_metrics), decline_offer=declined)
    return _reply("changed", line, change=row, undo=AssistUndo(tracking=undo))


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
        return _told(lines.anchor_line(intent.anchor, reminders_off=current.nudge_level is NudgeLevel.OFF), row)
    await apply_update(db, user_id, TrackingUpdate(log_anchor=intent.anchor))
    undo = AssistUndo(tracking=TrackingUpdate(log_anchor=current.log_anchor)) if current.log_anchor else None
    line = lines.anchor_line(intent.anchor, reminders_off=current.nudge_level is NudgeLevel.OFF)
    return _reply("changed", line, change=row, undo=undo)


async def _set_frictions(db: SupportsDatabase, user_id: UUID, intent: Intent, current: TrackingPreference) -> AssistReply:
    frictions = [f for f in current.frictions if f not in intent.frictions_remove]
    frictions += [f for f in _distinct(intent.frictions_add) if f not in frictions]
    quiet = current.nudge_level is NudgeLevel.OFF
    value = ", ".join(lines.FRICTION_TITLES[f] for f in frictions) or lines.NOTHING
    row = AssistChange(icon="hand.raised", title="What gets in the way", value=value)
    if frictions == current.frictions:
        if intent.frictions_add:
            return _told(lines.friction_added(intent.frictions_add[0], reminders_off=quiet), row)
        if intent.frictions_remove:
            return _told(lines.friction_removed(intent.frictions_remove[0]), row)
        return _told(lines.OTHER)
    await apply_update(db, user_id, TrackingUpdate(frictions=frictions))
    line = (
        lines.friction_added(intent.frictions_add[0], reminders_off=quiet) if intent.frictions_add
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
    # Only the nudges whose state moves, and an Undo of exactly those: written blind for the whole
    # subject, "turn the water reminders back on" with nothing muted answered "changed", and its
    # Undo muted what the person never had; an Undo of a mute also woke a mute made before it.
    muted_now = effects(await store.rows(user_id), datetime.now(UTC)).muted
    moving = [i for i in ids if (i in muted_now) is not quiet]
    title = lines.muted_value(intent.subject)
    row = AssistChange(
        icon="bell.slash", title="Muted", value=title if quiet else f"{title} back on"
    )
    if not moving:
        return _told(lines.already_muted(intent.subject) if quiet else lines.already_unmuted(intent.subject))
    for nudge_id in moving:
        await store.append(user_id=user_id, nudge_id=nudge_id, kind=kind)
    return _reply(
        "changed", lines.muted(intent.subject) if quiet else lines.unmuted(intent.subject), change=row,
        undo=AssistUndo(reactions=[ReactionRequest(nudge_id=i, kind=opposite) for i in moving]),
    )


async def _show(
    db: SupportsDatabase, user_id: UUID, intent: Intent, *, day: date, tz_zone: ZoneInfo
) -> AssistReply:
    if intent.show is None:
        return _told(lines.OTHER)
    if intent.show in lines.METRICS:
        metric, label = lines.METRICS[intent.show]
        today = await today_for(db, user_id, day, tz_zone)
        panel = next((p for p in today.panels if p.metric == metric), None)
        if panel is None:
            # Habits prints no calorie or macro number (decisions 58 and 72): the line names the
            # switch, never a number the person chose not to see. What its page does draw
            # (water, produce, a tile the person added there) is answered with that tile.
            if not today.prints_numbers:
                return _told(lines.NO_NUMBERS)
            return _told(lines.not_on_today(label))
        # Before a protocol the targets are placeholders that are nobody's (Today calls them
        # "starter targets"); the answer is where the person's own numbers come from.
        if today.targets_are_stub:
            return _reply(
                "pointed", lines.NO_TARGETS_YET,
                pointer=AssistPointer(surface="profile", title=lines.POINTER_TITLES["profile"]),
            )
        return _reply("shown", lines.shown(label), panel=panel)
    surface = intent.show
    return _reply(
        "pointed", lines.POINTER_LINES[surface],
        pointer=AssistPointer(surface=surface, title=lines.POINTER_TITLES[surface]),  # type: ignore[arg-type]
    )
