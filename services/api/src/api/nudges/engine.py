"""Deterministic nudge planning: signals + ledger + local clock + mode -> NudgePlan.

Pure function of its inputs (AGENTS.md #6): same signals, ledger, and local time
always produce the same plan. The engine owns the product's delivery promises
(Settings copy), per delivery LEVEL:

- ``essential`` — only habit-protecting nudges (catalog ``essential=True``: went
  quiet / nothing logged today), at most ONE a day and ``ESSENTIAL_WEEKLY_BUDGET``
  a rolling week. The calm default for new clients (user ask 2026-08: "I'm trying
  to eliminate the non-essentials — I don't want to see one every time").
- ``standard`` — the full catalog, never more than two a day. What shipped
  clients (TestFlight ≤ build 22, which send no level) keep getting.
- ``off`` — an empty plan, honored server-side so a stale client cache can't leak
  a fire past the user's choice.

Quiet hours are respected at every level and a nudge on cooldown stays silent.
The client's ledger ({id: "yyyy-MM-dd"}) is the delivery record — day precision,
advisory, prunable.

The mode (decision 63): a nudge speaks only in the modes its catalog entry names, or when the
person added its metric as a focus, so a habits person is never told a calorie. An invitation
(invitations.py, decision 62) is placed last, only on a day no other card fired, inside the
same budget.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date, datetime, timedelta

from ..tracking.schemas import FocusMetric, TrackingMode
from .catalog import CATALOG, Nudge
from .invitations import COOLDOWN_DAYS, Invitation
from .schemas import NudgeCard, NudgePlan, ScheduledNudge

DAILY_BUDGET = 2
# Essential level: one touch a day, a few a week — a cap on total interruptions,
# not just per-nudge cooldowns (cooldowns alone still allowed a nudge nearly
# every single day by rotating ids, which read as daily noise).
ESSENTIAL_DAILY_BUDGET = 1
ESSENTIAL_WEEKLY_BUDGET = 3
QUIET_START_HOUR = 9  # no fires before 09:00 local
QUIET_END_HOUR = 21  # no fires at/after 21:00 local
_MIN_LEAD = timedelta(minutes=30)  # a scheduled fire must be meaningfully in the future


@dataclass(frozen=True)
class NudgeSignals:
    """Deterministic facts about the user's day, derived from durable rows only."""

    kcal_consumed: float
    kcal_target: float
    protein_consumed: float
    protein_target: float
    water_oz: float
    water_target: float
    fiber_consumed: float
    fiber_target: float
    meals_today: int
    days_logged_this_week: int
    days_since_last_log: int  # 0 = logged today; large when never logged
    # Added 2026-10-04 with the ported situational moves; defaulted so a caller without them
    # (and every earlier test) reads as a Thursday with no produce target and no stress.
    produce_consumed: float = 0.0
    produce_target: float = 0.0
    weekday: int = 3  # Monday = 0; the mid-week rules fire on Monday to Wednesday
    stress_flag: bool = False  # the latest check-in reads as a rough week (hunger up, energy down)
    # Meal-plan mode (decision 65): the planned meals and how many of them today's logs ticked.
    plan_slots: int = 0
    plan_logged: int = 0
    # The onboarding that asks (decision 66): the meals the person said they eat a day (the
    # protocol's meals_per_day) and whether they asked for the evening reminder ("I forget").
    planned_meals: int = 0
    evening_reminder: bool = False


# Mid-week is Monday to Wednesday: early enough that a corrective nudge can still change how
# the week ends, which is the whole point of mid-week against end-of-week (PRODUCT_BRIEF).
_MIDWEEK_LAST_WEEKDAY = 2
# "Well under target" by the evening: less than half the day's calories. Treat headroom takes
# the other half of the range, so the two calorie voices never speak to the same evening.
_UNDER_TARGET_RATIO = 0.5


def _triggered(nudge: Nudge, s: NudgeSignals, now_local: datetime) -> bool:
    hour = now_local.hour
    match nudge.trigger:
        case "gone_quiet":
            return s.days_since_last_log >= 2
        case "no_log_by_late_morning":
            # Immediate after 11:00; also schedulable at its 11:30 slot earlier in the day.
            return s.meals_today == 0 and s.days_since_last_log < 2
        case "treat_headroom":
            remaining = s.kcal_target - s.kcal_consumed
            return (
                s.meals_today >= 1
                and s.kcal_target > 0
                and remaining >= 350
                and s.kcal_consumed >= _UNDER_TARGET_RATIO * s.kcal_target
            )
        case "under_target":
            return (
                s.meals_today >= 1
                and s.kcal_target > 0
                and hour >= 19
                and s.kcal_consumed < _UNDER_TARGET_RATIO * s.kcal_target
            )
        case "mid_week_slipping":
            return (
                s.weekday == _MIDWEEK_LAST_WEEKDAY
                and s.days_logged_this_week <= 1
                and s.meals_today == 0
            )
        case "stress_slipping":
            return (
                s.stress_flag
                and s.weekday <= _MIDWEEK_LAST_WEEKDAY
                and s.days_logged_this_week <= 1
            )
        case "produce_behind":
            return (
                s.meals_today >= 2
                and s.produce_target > 0
                and hour >= 15
                and s.produce_consumed < 0.5 * s.produce_target
            )
        case "protein_gap":
            return (
                s.meals_today >= 1
                and s.protein_target > 0
                and s.protein_consumed < 0.5 * s.protein_target
            )
        case "hydration_low":
            return s.water_target > 0 and s.water_oz < 0.5 * s.water_target and hour >= 12
        case "fiber_low":
            return (
                s.meals_today >= 2
                and s.fiber_target > 0
                and s.fiber_consumed < 0.4 * s.fiber_target
            )
        case "evening_on_track":
            remaining = s.kcal_target - s.kcal_consumed
            return s.meals_today >= 2 and s.kcal_target > 0 and 0 <= remaining <= 300 and hour >= 19
        case _:
            return _triggered_by_choice(nudge, s, hour)


def _triggered_by_choice(nudge: Nudge, s: NudgeSignals, hour: int) -> bool:
    """The triggers that exist only because the person chose something (a plan, a reminder):
    the same deterministic rule, kept apart from the metric triggers above."""
    match nudge.trigger:
        case "plan_slot_open":
            # A day under way (something logged) with a planned meal still open by evening. A
            # day with nothing logged is the habit nudges' to speak to, not the plan's.
            return (
                s.plan_slots > 0
                and s.plan_logged < s.plan_slots
                and s.meals_today >= 1
                and hour >= 19
            )
        case "evening_unlogged":
            # Only for the person who said "I forget" (decision 66): a meal they said they eat
            # is still unlogged. No hour here: before its slot the engine schedules it for the
            # evening (``_SLOT_FIRST``), and a re-plan after the meal is logged drops it. A long
            # quiet stretch is gone_quiet's to speak to, not this one's.
            return (
                s.evening_reminder
                and s.planned_meals >= 2
                and s.meals_today < s.planned_meals
                and s.days_since_last_log < 2
            )
    return False


# Triggers that are a SCHEDULED touch until their hour: poking someone at 8am for not having
# logged breakfast yet, or at noon about the evening's unlogged meal, is noise, not coaching.
# Keyed by trigger, the hour from which the nudge may be immediate instead.
_SLOT_FIRST: dict[str, int] = {"no_log_by_late_morning": 11, "evening_unlogged": 20}


def _on_cooldown(nudge: Nudge, ledger: dict[str, str], today: date) -> bool:
    shown = ledger.get(nudge.id)
    if not shown:
        return False
    try:
        shown_day = date.fromisoformat(shown)
    except ValueError:
        return False  # a corrupt ledger entry never blocks (advisory data)
    return (today - shown_day).days < nudge.cooldown_days


def _shown_today(ledger: dict[str, str], today: date) -> int:
    return sum(1 for v in ledger.values() if v == today.isoformat())


def _shown_this_week(ledger: dict[str, str], today: date) -> int:
    """Ledger entries within the rolling 7-day window ending today (inclusive).

    Corrupt entries don't count — same advisory-data posture as ``_on_cooldown``.
    """
    window_start = today - timedelta(days=6)
    count = 0
    for value in ledger.values():
        try:
            shown = date.fromisoformat(value)
        except ValueError:
            continue
        if window_start <= shown <= today:
            count += 1
    return count


def _card(nudge: Nudge) -> NudgeCard:
    return NudgeCard(
        id=nudge.id,
        category=nudge.category,
        message=nudge.message,
        pro_tip=nudge.pro_tip,
        priority=nudge.priority,
        cooldown_days=nudge.cooldown_days,
    )


def _slot_today(nudge: Nudge, now_local: datetime) -> datetime | None:
    """The nudge's preferred local fire time today, if still meaningfully ahead and
    inside quiet hours; None otherwise."""
    if nudge.slot is None:
        return None
    hour, minute = nudge.slot
    fire = now_local.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if fire < now_local + _MIN_LEAD:
        return None
    if not (QUIET_START_HOUR <= fire.hour < QUIET_END_HOUR):
        return None
    return fire


def _speaks_in(nudge: Nudge, mode: TrackingMode, focus: Sequence[FocusMetric]) -> bool:
    """A nudge may speak when the mode prints its metric, or the person added that metric."""
    if mode in nudge.modes:
        return True
    return nudge.focus_metric is not None and any(f.value == nudge.focus_metric for f in focus)


def _invitation_card(invitation: Invitation) -> NudgeCard:
    return NudgeCard(
        id=invitation.card_id,
        category="invitation",
        message=invitation.message,
        pro_tip=invitation.pro_tip,
        priority=10,
        cooldown_days=COOLDOWN_DAYS,
        kind="invitation",
        offer_mode=invitation.offer_mode.value if invitation.offer_mode else None,
        offer_focus=invitation.offer_focus.value if invitation.offer_focus else None,
        decline_key=invitation.offer_key,
    )


def plan(
    signals: NudgeSignals,
    ledger: dict[str, str],
    now_local: datetime,
    level: str = "standard",
    *,
    mode: TrackingMode = TrackingMode.FIVE,
    focus: Sequence[FocusMetric] = (),
    invitation: Invitation | None = None,
) -> NudgePlan:
    """Build the plan: one immediate card at most, future local fires for the rest,
    all inside the level's delivery budget (the client records scheduled-today fires
    in the same ledger, so budget math holds across re-plans). ``mode`` and ``focus``
    decide which nudges may speak; ``invitation`` is placed last and only on a quiet day."""
    if level == "off":
        return NudgePlan()
    essential_only = level == "essential"

    today = now_local.date()
    budget = (ESSENTIAL_DAILY_BUDGET if essential_only else DAILY_BUDGET) - _shown_today(
        ledger, today
    )
    if essential_only:
        budget = min(budget, ESSENTIAL_WEEKLY_BUDGET - _shown_this_week(ledger, today))
    if budget <= 0:
        return NudgePlan()

    candidates = [
        n
        for n in sorted(CATALOG, key=lambda n: n.priority, reverse=True)
        if (n.essential or not essential_only)
        and _speaks_in(n, mode, focus)
        and _triggered(n, signals, now_local)
        and not _on_cooldown(n, ledger, today)
    ]

    immediate: list[NudgeCard] = []
    scheduled: list[ScheduledNudge] = []
    for nudge in candidates:
        if budget <= 0:
            break
        # A slot-first nudge is a SCHEDULED touch until its hour (see ``_SLOT_FIRST``).
        slot_hour = _SLOT_FIRST.get(nudge.trigger)
        prefers_slot = slot_hour is not None and now_local.hour < slot_hour
        if not immediate and not prefers_slot:
            immediate.append(_card(nudge))
            budget -= 1
            continue
        fire = _slot_today(nudge, now_local)
        if fire is not None:
            scheduled.append(ScheduledNudge(fire_at=fire, card=_card(nudge)))
            budget -= 1

    # Quiet re-engagement: if today produced nothing to say, park tomorrow-morning's
    # gentle reminder so a user who never reopens the app still gets one soft touch.
    # Fires at 09:30 local (inside quiet hours); tomorrow's budget is untouched today.
    if not immediate and not scheduled and signals.meals_today == 0:
        no_log = next(n for n in CATALOG if n.id == "no_log_today")
        if not _on_cooldown(no_log, ledger, today):
            tomorrow = (now_local + timedelta(days=1)).replace(
                hour=9, minute=30, second=0, microsecond=0
            )
            scheduled.append(ScheduledNudge(fire_at=tomorrow, card=_card(no_log)))

    # An invitation (decision 62) is the rarest voice: only when nothing else spoke today, once
    # per direction per fortnight (its id is the ledger key), inside the same budget. It is
    # allowed at the essential level because it is about the person's own setup, not coaching.
    if (
        invitation is not None
        and budget > 0
        and not immediate
        and not scheduled
        and _shown_today(ledger, today) == 0
        and not _invitation_on_cooldown(invitation, ledger, today)
    ):
        immediate.append(_invitation_card(invitation))

    return NudgePlan(immediate=immediate, scheduled=scheduled)


def _invitation_on_cooldown(invitation: Invitation, ledger: dict[str, str], today: date) -> bool:
    shown = ledger.get(invitation.card_id)
    if not shown:
        return False
    try:
        shown_day = date.fromisoformat(shown)
    except ValueError:
        return False
    return (today - shown_day).days < COOLDOWN_DAYS
