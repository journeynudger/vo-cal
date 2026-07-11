"""Deterministic nudge planning: signals + ledger + local clock -> NudgePlan.

Pure function of its inputs (AGENTS.md #6): same signals, ledger, and local time
always produce the same plan. The engine owns the product's delivery promises
(Settings copy): NEVER more than two nudges a day, quiet hours respected, and a
nudge on cooldown stays silent. The client's ledger ({id: "yyyy-MM-dd"}) is the
delivery record — day precision, advisory, prunable.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta

from .catalog import CATALOG, Nudge
from .schemas import NudgeCard, NudgePlan, ScheduledNudge

DAILY_BUDGET = 2
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
            return s.meals_today >= 1 and s.kcal_target > 0 and remaining >= 350
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
        case "streak":
            return s.days_logged_this_week >= 5
        case "evening_on_track":
            remaining = s.kcal_target - s.kcal_consumed
            return s.meals_today >= 2 and s.kcal_target > 0 and 0 <= remaining <= 300 and hour >= 19
    return False


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


def plan(signals: NudgeSignals, ledger: dict[str, str], now_local: datetime) -> NudgePlan:
    """Build the plan: one immediate card at most, future local fires for the rest,
    all inside today's two-nudge budget (the client records scheduled-today fires
    in the same ledger, so budget math holds across re-plans)."""
    today = now_local.date()
    budget = DAILY_BUDGET - _shown_today(ledger, today)
    if budget <= 0:
        return NudgePlan()

    candidates = [
        n
        for n in sorted(CATALOG, key=lambda n: n.priority, reverse=True)
        if _triggered(n, signals, now_local) and not _on_cooldown(n, ledger, today)
    ]

    immediate: list[NudgeCard] = []
    scheduled: list[ScheduledNudge] = []
    for nudge in candidates:
        if budget <= 0:
            break
        # The no-log reminder is a SCHEDULED touch until late morning — poking someone
        # at 8am for not having logged breakfast yet is noise, not coaching.
        prefers_slot = nudge.trigger == "no_log_by_late_morning" and now_local.hour < 11
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

    return NudgePlan(immediate=immediate, scheduled=scheduled)
