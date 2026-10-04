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
"""

from __future__ import annotations

from dataclasses import dataclass

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
            "Welcome back! No need to catch up on missed days. Today is a fresh page. "
            "One logged meal puts you right back in rhythm."
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
            "Stressful stretch, and it's early in the week. Keep it light: repeat a day you "
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
            "The week is thin so far. Repeat a day you tracked well: the same meals, one log "
            "each. No thinking required, still tracking."
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
            "Nothing logged yet today. A ten-second voice note keeps the day honest. "
            "Just say what you had; we'll do the math."
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
        message=(
            "Anything from today still unlogged? A sentence now keeps the day whole."
        ),
        pro_tip="Even 'a sandwich' is a log. The amounts can come later.",
        priority=68,
        cooldown_days=1,
        trigger="evening_unlogged",
        slot=(20, 0),
        # It protects the logging habit, so it speaks at the quiet level too; the trigger itself
        # is gated on the person having asked for it (decision 66), never on the mode.
        essential=True,
    ),
    Nudge(
        id="treat_headroom",
        category="calories",
        message=(
            "Good news: you've got comfortable room left today. If you've been eyeing a "
            "treat, tonight fits your plan. Enjoy it, log it, no guilt."
        ),
        pro_tip="A treat that's planned is a win, not a slip. Say it like any other food and move on.",
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
            "You're a bit light on protein so far, and dinner is a great place to close the "
            "gap. Chicken, fish, Greek yogurt, or tofu all get you there fast."
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
            "Water check: you're under halfway to today's goal. A glass now and one with "
            "each meal quietly gets you the rest of the way."
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
        message=(
            "You're well under target so far today, and under-eating stalls progress too. "
            "Anything you haven't logged yet?"
        ),
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
            "Feeling snacky? Boost your fiber! Foods like oats, beans, or an apple can "
            "help curb cravings while keeping you full longer."
        ),
        pro_tip=(
            "Think of fiber as your hunger helper. Pre-portion some trail mix or grab "
            "pre-washed fruits and veggies for busy days."
        ),
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
        message=(
            "You're closing the day right around your target. Nicely played. A light "
            "evening keeps it landed."
        ),
        pro_tip="If late-night hunger shows up, sparkling water or herbal tea usually settles it.",
        priority=25,
        cooldown_days=3,
        trigger="evening_on_track",
        modes=_CALORIE_MODES,
    ),
)
