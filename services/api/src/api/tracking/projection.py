"""What a mode shows: the one place that answers it (decision 59).

Pure data and pure functions. The engine computes the whole protocol for everyone; this module
says which of it a mode prints, whether checks fire, which keys the reveal shows, and whether
the week card and the Health line belong on the page. Every surface asks here, so the mode
governs every printed number, not only the cards (the Rams review, R8).
"""

from __future__ import annotations

from dataclasses import dataclass

from .schemas import (
    CheckSlots,
    Experience,
    FocusMetric,
    Friction,
    LogAnchor,
    NudgeLevel,
    TrackingMode,
)

# The protocol keys each mode reveals, in the order the reveal lists them. Habits shows its
# two counts (water, produce) because the tiles on Today show the same counts and the reveal
# may not contradict the page it leads to (spec R12, variant a, decided by this build).
_REVEAL: dict[TrackingMode, tuple[str, ...]] = {
    TrackingMode.HABITS: ("water", "produce"),
    TrackingMode.CALORIES: ("kcal",),
    TrackingMode.FIVE: ("kcal", "protein", "water", "fiber", "produce"),
    TrackingMode.MACROS: ("kcal", "protein", "carbs", "fat", "fiber"),
    TrackingMode.MEAL_PLAN: ("kcal", "protein", "water", "fiber", "produce"),
}

# The metrics a mode already prints as tiles (a focus metric adds one that is not here).
_OWN_METRICS: dict[TrackingMode, tuple[str, ...]] = {
    TrackingMode.HABITS: ("water", "produce"),
    TrackingMode.CALORIES: (),
    TrackingMode.FIVE: ("protein", "produce", "water", "fiber"),
    TrackingMode.MACROS: ("protein", "carbs", "fat"),
    TrackingMode.MEAL_PLAN: ("protein", "produce", "water", "fiber"),
}


@dataclass(frozen=True)
class Projection:
    mode: TrackingMode
    # False only in habits mode: no calories on cards, rows, chips, the result or the week.
    prints_numbers: bool
    # False in habits mode: a check's job is to make a shown number right (spec R3).
    checks_enabled: bool
    reveal_keys: tuple[str, ...]
    shows_week_card: bool
    shows_health_line: bool
    own_metrics: tuple[str, ...]


def projection_for(mode: TrackingMode) -> Projection:
    numeric = mode is not TrackingMode.HABITS
    return Projection(
        mode=mode,
        prints_numbers=numeric,
        checks_enabled=numeric,
        reveal_keys=_REVEAL[mode],
        shows_week_card=numeric,
        shows_health_line=numeric,
        own_metrics=_OWN_METRICS[mode],
    )


def extra_metrics(mode: TrackingMode, focus: list[FocusMetric]) -> list[FocusMetric]:
    """The focus metrics that add a tile: the ones the mode does not already print, in the
    order the person listed them, without repeats."""
    own = set(_OWN_METRICS[mode])
    seen: set[str] = set()
    out: list[FocusMetric] = []
    for metric in focus:
        if metric.value in own or metric.value in seen:
            continue
        seen.add(metric.value)
        out.append(metric)
    return out


def offerable_focus(mode: TrackingMode) -> list[FocusMetric]:
    """The metrics Settings → How I track may offer under "Also show": every focus metric the
    mode does not already print, in the enum's order (spec 6.8). The client lists what it is
    sent, so a new metric reaches the page without a client build."""
    own = set(_OWN_METRICS[mode])
    return [metric for metric in FocusMetric if metric.value not in own]


def check_slots_for(anchor: LogAnchor | None) -> CheckSlots:
    """When the two consistency checks fire (decision 69, spec 6.3). The after-eating logger
    keeps today's hours; the one who logs when they sit back down is checked an hour later; the
    before-bed logger has no late-morning check at all and an evening one after dinner. ``OWN``
    and never asked move nothing. Budgets, quiet hours and cooldowns are the engine's and do not
    move here."""
    match anchor:
        case LogAnchor.WHEN_SEATED:
            return CheckSlots(late_morning="12:30", evening="20:00")
        case LogAnchor.BEFORE_BED:
            return CheckSlots(late_morning=None, evening="20:30")
        case _:
            return CheckSlots()


def experience_for(
    level: NudgeLevel | None, frictions: list[Friction], anchor: LogAnchor | None = None
) -> Experience:
    """What how-much-the-app-says, what-gets-in-the-way and when-you-log change (decisions 66
    and 69; the specs' 6.4 and 6.3). Each friction moves exactly one thing; the level gates the
    invitations; the anchor moves the two consistency checks. A person never asked (``level``
    None) keeps today's behaviour: the phone's own level stands and the ladder's invitations may
    speak, because that is what every account from before the question lived under and nothing
    may change under them. The before-bed logger's evening check exists whether or not they
    said they forget: the evening is their one moment, so it is the one check that fits."""
    return Experience(
        nudge_level=level,
        offers_invitations=level is None or level is NudgeLevel.STANDARD,
        evening_reminder=Friction.FORGETTING in frictions or anchor is LogAnchor.BEFORE_BED,
        amount_checks="eager" if Friction.PORTIONS in frictions else "standard",
        bar_hint="photo" if Friction.EATING_OUT in frictions else "default",
        seed_usuals=Friction.TIME in frictions,
        check_slots=check_slots_for(anchor),
    )
