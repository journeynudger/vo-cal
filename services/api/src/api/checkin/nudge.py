"""Mid-week SITUATIONAL nudging engine (Phase G, decision #32 — the highest-rated pillar).

Francesco rates proactive, *during-the-week* nudging above voice-first ("that's
the game changer"). This module is the deterministic half: given a user's recent
logging signals it picks ONE situational nudge from a fixed BANK of templates
encoding Francesco's actual coaching moves. The LLM phrasing layer is later and
sits on top of this output — it may not invent triggers, numbers, or branches
(AGENTS.md #6: deterministic code calculates; the LLM extracts/phrases).

Why deterministic + a bank, not a model: the trigger logic (which situation a
user is in) and the move (which advice fires) are the IP. A model picking the
move would be unauditable and could drift; the bank is testable and explainable.

Design notes:
- **Mid-week timing.** Nudges are meant to catch a slipping stretch BEFORE the
  week's midpoint so the week doesn't run off the rails (PRODUCT_BRIEF: "detect a
  stressful stretch before the week's midpoint"). ``is_mid_week`` gates the
  slipping-class rules; the no-log-today and water rules fire any day.
- **No double-firing.** Exactly one nudge is selected per evaluation, by a fixed
  priority order over the bank. Selection is total: ``ALL_CLEAR`` fires when
  nothing else does, so the engine always returns a structured result.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from enum import Enum

# Week runs Monday(0)..Sunday(6); the midpoint is Thursday. "Before the midpoint"
# means Mon/Tue/Wed (weekday < 3) — early enough that a corrective nudge can still
# change how the week ends, which is the entire point of mid-week vs end-of-week.
_MIDWEEK_CUTOFF_WEEKDAY = 3

# A day without a log by this many hours reads as "haven't logged today".
_NO_LOG_TODAY_HOURS = 16.0

# Adherence floors. Logging fewer than this many days by mid-week is "slipping".
_SLIPPING_DAYS_BY_MIDWEEK = 2

# Calorie target band. Well under target by mid-week (under-eating / not logging
# the full day) is its own situation distinct from slipping on day count.
_UNDER_TARGET_RATIO = 0.7

# Adherence ratios for produce/water are 0..1 (fraction of the daily target hit).
_WATER_BEHIND_RATIO = 0.6
_PRODUCE_BEHIND_RATIO = 0.5


class NudgeTrigger(str, Enum):
    """The situation a nudge responds to. Stable string ids — stored + asserted."""

    NO_LOG_TODAY = "no_log_today"
    STRESS_SLIPPING = "stress_slipping"
    MID_WEEK_SLIPPING = "mid_week_slipping"
    WATER_BEHIND = "water_behind"
    PRODUCE_BEHIND = "produce_behind"
    UNDER_TARGET = "under_target"
    ALL_CLEAR = "all_clear"


@dataclass(frozen=True)
class NudgeSignals:
    """Recent logging signals for one user, as of ``weekday`` (Mon=0..Sun=6).

    All deterministic inputs; the caller (router/store) assembles these from
    durable rows — this module never reads the database.
    """

    weekday: int
    days_logged_this_week: int
    last_log_age_hours: float | None
    avg_kcal_vs_target: float | None = None  # ratio: logged kcal / target kcal
    water_adherence: float | None = None  # 0..1 fraction of daily water target
    produce_adherence: float | None = None  # 0..1 fraction of daily produce target
    stress_flag: bool = False

    @property
    def is_mid_week(self) -> bool:
        """True before the week's midpoint (Mon/Tue/Wed) — the actionable window."""
        return self.weekday < _MIDWEEK_CUTOFF_WEEKDAY


@dataclass(frozen=True)
class Nudge:
    """A selected situational nudge. ``message`` is the deterministic fallback copy;
    the later phrasing layer may rewrite it but may not change trigger/branches."""

    trigger: NudgeTrigger
    message: str
    branch_options: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "trigger": self.trigger.value,
            "message": self.message,
            "branch_options": list(self.branch_options),
        }


@dataclass(frozen=True)
class _BankRule:
    """One entry in the situational-advice bank: when it fires + what it says."""

    trigger: NudgeTrigger
    fires: Callable[[NudgeSignals], bool]
    message: str
    branch_options: list[str]


# -- The BANK -----------------------------------------------------------------
# Encodes Francesco's actual situational moves. Ordered by priority: the FIRST
# rule whose predicate matches is the one nudge that fires (no double-firing).
# A no-log-today / stress signal outranks adherence nudges because a silent or
# struggling user is the higher-stakes situation to reach.


def _no_log_today(s: NudgeSignals) -> bool:
    # Never logged at all, or the last log is older than the no-log-today window.
    return s.last_log_age_hours is None or s.last_log_age_hours >= _NO_LOG_TODAY_HOURS


def _stress_slipping(s: NudgeSignals) -> bool:
    # A stressful stretch detected BEFORE the midpoint while days are thin — the
    # exact case the mid-week pillar exists to catch before the week derails.
    return s.stress_flag and s.is_mid_week and s.days_logged_this_week < _SLIPPING_DAYS_BY_MIDWEEK


def _mid_week_slipping(s: NudgeSignals) -> bool:
    # Slipping on day count by mid-week (no stress flag — that's the rule above).
    return s.is_mid_week and s.days_logged_this_week < _SLIPPING_DAYS_BY_MIDWEEK


def _under_target(s: NudgeSignals) -> bool:
    return s.avg_kcal_vs_target is not None and s.avg_kcal_vs_target < _UNDER_TARGET_RATIO


def _water_behind(s: NudgeSignals) -> bool:
    return s.water_adherence is not None and s.water_adherence < _WATER_BEHIND_RATIO


def _produce_behind(s: NudgeSignals) -> bool:
    return s.produce_adherence is not None and s.produce_adherence < _PRODUCE_BEHIND_RATIO


_BANK: tuple[_BankRule, ...] = (
    _BankRule(
        trigger=NudgeTrigger.NO_LOG_TODAY,
        fires=_no_log_today,
        message="Haven't seen a log today — rough day?",
        branch_options=[
            "Rough day — keep it light",
            "Just busy — quick log now",
            "All good — I'll log later",
        ],
    ),
    _BankRule(
        trigger=NudgeTrigger.STRESS_SLIPPING,
        fires=_stress_slipping,
        message=(
            "Stressful stretch and we're early in the week. Repeat a day you "
            "tracked perfectly — zero friction, still tracking."
        ),
        branch_options=[
            "Repeat my best day",
            "Just log one meal",
            "Not today",
        ],
    ),
    _BankRule(
        trigger=NudgeTrigger.MID_WEEK_SLIPPING,
        fires=_mid_week_slipping,
        message=(
            "We're slipping a little this week. Repeat a day you tracked "
            "perfectly to get the streak back — no thinking required."
        ),
        branch_options=[
            "Repeat my best day",
            "Log right now",
            "Remind me tonight",
        ],
    ),
    _BankRule(
        trigger=NudgeTrigger.WATER_BEHIND,
        fires=_water_behind,
        message="Stay on that water so this week doesn't go like last week.",
        branch_options=[
            "Logging water now",
            "Remind me in an hour",
        ],
    ),
    _BankRule(
        trigger=NudgeTrigger.PRODUCE_BEHIND,
        fires=_produce_behind,
        message="Light on fruits and veg so far — add a serving to your next meal.",
        branch_options=[
            "On it",
            "Remind me at dinner",
        ],
    ),
    _BankRule(
        trigger=NudgeTrigger.UNDER_TARGET,
        fires=_under_target,
        message=(
            "You're well under target — under-eating stalls progress too. "
            "Anything you haven't logged yet?"
        ),
        branch_options=[
            "Add a meal I missed",
            "That's really all I ate",
        ],
    ),
)

# Fired when no bank rule matches — keeps selection total so the engine always
# returns a structured nudge (callers branch on ``ALL_CLEAR`` to suppress delivery).
_ALL_CLEAR = Nudge(
    trigger=NudgeTrigger.ALL_CLEAR,
    message="Nice work staying on it this week.",
    branch_options=[],
)


def select_nudge(signals: NudgeSignals) -> Nudge:
    """Pick exactly one situational nudge from the bank for these signals.

    First-match-wins over the priority-ordered bank, so a single evaluation
    never produces two nudges. Returns ``ALL_CLEAR`` when nothing fires.
    """
    for rule in _BANK:
        if rule.fires(signals):
            return Nudge(
                trigger=rule.trigger,
                message=rule.message,
                branch_options=list(rule.branch_options),
            )
    return _ALL_CLEAR
