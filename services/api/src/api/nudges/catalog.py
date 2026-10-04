"""The nudge catalog — data, not a rule engine (AGENTS.md #6).

Each nudge: identity + the product's coaching copy + a trigger key the engine evaluates against
deterministic signals + the modes it may speak in (decision 63). Voice rules (the Settings
promise and the certainty spec's banned-words list): empathy-first, never shame, never more
than two a day, and never a number the person's mode does not print: the copy carries no
digits, so a habits person is never told a calorie. Copy is final here; the client never
rewrites it.

``slot`` is the preferred local delivery hour for a SCHEDULED fire (quiet hours 9:00–21:00 are
enforced by the engine); None = immediate-only.

Provenance: the situational moves (mid-week slipping, stress slipping, under target, produce
behind) are Francesco's, ported from the legacy ``checkin/nudge.py`` bank that no client ever
reached (findings ledger 46); the "streak momentum" nudge was cut as a count of the person's
own material presented as praise (the Rams audit's F3 and the protocol's B3: users, not
consumers).

The voice (decision 69, docs/design/behavior-change-spec.md B4 and 6.6): every message and pro tip
is recognition (the fact the engine has), invitation (the door), agency (nothing that takes the
choice), in that order. No exclamation mark; no feeling the engine did not measure; no grade; no
"we" (the method speaks only in the recalibration, where a coach exists); under 140 characters so
a lock screen shows it whole. test_nudges_api pins the rule over the whole catalog. The words are
final here and the phone prints them as given; the only variation is deterministic and the
person's own (``message_for``: their anchor's plan back to them, a fresh-start line on a landmark
day).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date

from ..tracking.schemas import TrackingMode

ALL_MODES: frozenset[TrackingMode] = frozenset(TrackingMode)
# Modes that print a calorie: the only ones a calorie nudge may speak in.
_CALORIE_MODES: frozenset[TrackingMode] = frozenset(
    {TrackingMode.CALORIES, TrackingMode.FIVE, TrackingMode.MACROS, TrackingMode.MEAL_PLAN}
)
_PROTEIN_MODES: frozenset[TrackingMode] = frozenset(
    {TrackingMode.FIVE, TrackingMode.MACROS, TrackingMode.MEAL_PLAN}
)
_HABIT_METRIC_MODES: frozenset[TrackingMode] = frozenset(
    {TrackingMode.HABITS, TrackingMode.FIVE, TrackingMode.MEAL_PLAN}
)


# The lock screen's title, by the catalog's category, in the person's words (decision 67): the
# subject of the person's day, never the app's name and never the nudge id.
_TITLES: dict[str, str] = {
    "consistency": "Your day",
    "calories": "Calories",
    "protein": "Protein",
    "water": "Water",
    "produce": "Produce",
    "fiber": "Fiber",
    "plan": "Your plan",
    "invitation": "How you track",
}


def title_for(category: str) -> str:
    return _TITLES.get(category, "Your day")


@dataclass(frozen=True)
class Nudge:
    id: str
    category: str
    message: str
    pro_tip: str
    priority: int  # higher wins
    cooldown_days: int
    trigger: str  # evaluated by engine._triggered
    slot: tuple[int, int] | None = None  # preferred (hour, minute) for scheduled fires
    # Essential = it protects the logging habit itself (went quiet / nothing logged / slipping).
    # Everything else is coaching garnish, silenced at the "essential" delivery level
    # (user ask 2026-08: "I'm trying to eliminate the non-essentials").
    essential: bool = False
    # The modes this nudge may fire in (decision 63). A nudge about a metric the mode does not
    # print stays silent, unless the person added that metric as a focus (``focus_metric``).
    modes: frozenset[TrackingMode] = ALL_MODES
    focus_metric: str | None = None


CATALOG: tuple[Nudge, ...] = (
    Nudge(
        id="gone_quiet",
        category="consistency",
        message=(
            "A few quiet days. Nothing to catch up on; today is its own page. One logged meal "
            "and you're back in it."
        ),
        pro_tip="Log the very next thing you eat, even if it's small. Momentum beats perfection.",
        priority=80,
        cooldown_days=2,
        trigger="gone_quiet",
        essential=True,
    ),
    Nudge(
        id="stress_slipping",
        category="consistency",
        message=(
            "A rough week by your own account, and it's early. Keep it light: repeat a day you "
            "tracked well, or log one meal and call it a day."
        ),
        pro_tip="A stressful week is not the week to be perfect. One honest log a day holds the habit.",
        priority=78,
        cooldown_days=7,
        trigger="stress_slipping",
        slot=(12, 0),
        essential=True,
    ),
    Nudge(
        id="mid_week_slipping",
        category="consistency",
        message=(
            "The week is thin so far: a day logged, at most. Repeat a day you tracked well: the "
            "same meals, one log each."
        ),
        pro_tip="Your usuals are the shortcut: tap one and the meal is logged.",
        priority=75,
        cooldown_days=7,
        trigger="mid_week_slipping",
        slot=(12, 0),
        essential=True,
    ),
    Nudge(
        id="no_log_today",
        category="consistency",
        message=(
            "Nothing logged yet today. Ten seconds covers it: say what you had, the math is done "
            "for you."
        ),
        pro_tip="Right after a meal is the easiest moment: phone up, one sentence, done.",
        priority=70,
        cooldown_days=1,
        trigger="no_log_by_late_morning",
        slot=(11, 30),
        essential=True,
    ),
    Nudge(
        id="evening_unlogged",
        category="consistency",
        message="Anything from today still unlogged? A sentence now keeps the day whole.",
        pro_tip="Even 'a sandwich' is a log. The amounts can come later.",
        priority=68,
        cooldown_days=1,
        trigger="evening_unlogged",
        slot=(20, 0),
        # It protects the logging habit, so it speaks at the quiet level too; the trigger itself
        # is gated on the person having asked for it (decision 66) or logging before bed
        # (decision 69), never on the mode.
        essential=True,
    ),
    Nudge(
        id="treat_headroom",
        category="calories",
        message=(
            "Comfortable room left today. If a treat is on your mind, tonight fits the plan. "
            "Have it, log it."
        ),
        pro_tip="A treat you planned is part of the plan. Say it like any other food.",
        priority=60,
        cooldown_days=2,
        trigger="treat_headroom",
        slot=(19, 0),
        modes=_CALORIE_MODES,
    ),
    Nudge(
        id="protein_gap",
        category="protein",
        message=(
            "Protein is light so far. Dinner can close most of the gap: chicken, fish, Greek "
            "yogurt or tofu."
        ),
        pro_tip="Aim for a palm-sized portion of protein at dinner and you'll land right in your band.",
        priority=55,
        cooldown_days=2,
        trigger="protein_gap",
        slot=(17, 0),
        modes=_PROTEIN_MODES,
        focus_metric="protein",
    ),
    Nudge(
        id="hydration_low",
        category="water",
        message=(
            "Under halfway on water. A glass now and one with each meal gets you the rest of the "
            "way."
        ),
        pro_tip="Keep a filled bottle where you work. Proximity does the remembering for you.",
        priority=50,
        cooldown_days=1,
        trigger="hydration_low",
        slot=(15, 0),
        modes=_HABIT_METRIC_MODES,
        focus_metric="water",
    ),
    Nudge(
        id="under_target",
        category="calories",
        message="Well under target so far today. Anything you haven't logged yet?",
        pro_tip="If that's really all you ate, that's the honest log. The plan assumes you eat it.",
        priority=45,
        cooldown_days=2,
        trigger="under_target",
        modes=_CALORIE_MODES,
    ),
    Nudge(
        id="produce_behind",
        category="produce",
        message=(
            "Light on fruit and veg so far. A serving with your next meal gets you most of "
            "the way there."
        ),
        pro_tip="Frozen vegetables count. So does the apple in the bag.",
        priority=40,
        cooldown_days=2,
        trigger="produce_behind",
        slot=(16, 0),
        modes=_HABIT_METRIC_MODES,
        focus_metric="produce",
    ),
    Nudge(
        id="plan_slot_open",
        category="plan",
        message=(
            "A meal on your plan is still open. Log it when you have it; the plan is there "
            "tomorrow too."
        ),
        pro_tip=(
            "A plan is a shape for the day, not a score. A day that strays from it is still "
            "a day you logged."
        ),
        priority=52,
        cooldown_days=1,
        trigger="plan_slot_open",
        slot=(19, 30),
        modes=frozenset({TrackingMode.MEAL_PLAN}),
    ),
    Nudge(
        id="fiber_boost",
        category="fiber",
        message=(
            "Fiber is behind for the day. Oats, beans or an apple with your next meal carry it, "
            "and keep you full longer."
        ),
        pro_tip="Pre-portioned trail mix, or washed fruit in the fridge, for the busy days.",
        priority=34,
        cooldown_days=3,
        trigger="fiber_low",
        slot=(15, 30),
        modes=frozenset({TrackingMode.FIVE, TrackingMode.MEAL_PLAN}),
        focus_metric="fiber",
    ),
    Nudge(
        id="evening_on_track",
        category="calories",
        message="Closing the day right around your target. A light evening keeps it there.",
        pro_tip="If late-night hunger shows up, sparkling water or herbal tea usually settles it.",
        priority=25,
        cooldown_days=3,
        trigger="evening_on_track",
        modes=_CALORIE_MODES,
    ),
)


# The voice (decision 69, spec B4 and 6.6): recognition, invitation, agency. The fact the engine
# has, then the door, then nothing that takes the choice. No exclamation mark, no feeling the
# engine did not measure, no grade, no "we" (the method speaks only in the recalibration, where a
# coach exists). test_nudges_api pins the rule over every message and pro tip.

# The late-morning check in the person's own plan's words (spec 6.3): one message per anchor,
# final here, nothing generated. ``own`` and never asked keep the plain words; the before-bed
# logger has no late-morning check at all (engine.slot_for).
_NO_LOG_BY_ANCHOR: dict[str, str] = {
    "after_eating": (
        "Nothing logged yet today. You said right after you eat: the next meal is the moment."
    ),
    "when_seated": (
        "Nothing logged yet today. You said when you sit back down: next time you do, say what "
        "you had."
    ),
}

# The recovery line on a Monday or the first of the month (Dai, Milkman and Riis 2014, the fresh
# start effect): the same nudge, the same cooldown and ledger entry, only the words.
_FRESH_START = "New week, clean page. One logged meal and you're back in it."


def is_fresh_start(day: date) -> bool:
    """A temporal landmark the person already feels: Monday, or the first of the month."""
    return day.weekday() == 0 or day.day == 1


def message_for(nudge: Nudge, anchor: str | None = None, fresh_start: bool = False) -> str:
    """The nudge's words for this person today: the plan's own words for the late-morning check
    when an anchor names them, the fresh-start line for the recovery nudge on a landmark day,
    the catalog's words otherwise."""
    if nudge.id == "no_log_today" and anchor in _NO_LOG_BY_ANCHOR:
        return _NO_LOG_BY_ANCHOR[anchor]
    if nudge.id == "gone_quiet" and fresh_start:
        return _FRESH_START
    return nudge.message
