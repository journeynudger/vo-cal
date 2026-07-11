"""The nudge catalog — data, not a rule engine (AGENTS.md #6).

Each nudge: identity + the product's coaching copy + a trigger key the engine
evaluates against deterministic signals. Voice rules (Settings promise + the
certainty spec's banned-words list): empathy-first, never shame, never more than
two a day — "a gentle reminder if you go quiet, a heads-up when there's room for
a treat." Copy is final here; the client never rewrites it.

``slot`` is the preferred local delivery hour for a SCHEDULED fire (quiet hours
9:00–21:00 are enforced by the engine); None = immediate-only.
"""

from __future__ import annotations

from dataclasses import dataclass


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


CATALOG: tuple[Nudge, ...] = (
    Nudge(
        id="gone_quiet",
        category="consistency",
        message=(
            "Welcome back! No need to catch up on missed days — today is a fresh page. "
            "One logged meal puts you right back in rhythm."
        ),
        pro_tip="Log the very next thing you eat, even if it's small. Momentum beats perfection.",
        priority=80,
        cooldown_days=2,
        trigger="gone_quiet",
    ),
    Nudge(
        id="no_log_today",
        category="consistency",
        message=(
            "Nothing logged yet today — a ten-second voice note keeps your streak honest. "
            "Just say what you had; we'll do the math."
        ),
        pro_tip="Right after a meal is the easiest moment: phone up, one sentence, done.",
        priority=70,
        cooldown_days=1,
        trigger="no_log_by_late_morning",
        slot=(11, 30),
    ),
    Nudge(
        id="treat_headroom",
        category="calories",
        message=(
            "Good news: you've got comfortable room left today. If you've been eyeing a "
            "treat, tonight fits your plan — enjoy it, log it, no guilt."
        ),
        pro_tip="A treat that's planned is a win, not a slip. Say it like any other food and move on.",
        priority=60,
        cooldown_days=2,
        trigger="treat_headroom",
        slot=(19, 0),
    ),
    Nudge(
        id="protein_gap",
        category="protein",
        message=(
            "You're a bit light on protein so far — dinner is a great place to close the "
            "gap. Chicken, fish, Greek yogurt, or tofu all get you there fast."
        ),
        pro_tip="Aim for a palm-sized portion of protein at dinner and you'll land right in your band.",
        priority=55,
        cooldown_days=2,
        trigger="protein_gap",
        slot=(17, 0),
    ),
    Nudge(
        id="hydration_low",
        category="water",
        message=(
            "Water check: you're under halfway to today's goal. A glass now and one with "
            "each meal quietly gets you the rest of the way."
        ),
        pro_tip="Keep a filled bottle where you work — proximity does the remembering for you.",
        priority=50,
        cooldown_days=1,
        trigger="hydration_low",
        slot=(15, 0),
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
    ),
    Nudge(
        id="streak_momentum",
        category="consistency",
        message=(
            "Five logged days this week — that's real momentum. Consistency like this is "
            "exactly what moves the needle."
        ),
        pro_tip="Streaks survive on easy days. On busy ones, a single voice log still counts.",
        priority=30,
        cooldown_days=7,
        trigger="streak",
    ),
    Nudge(
        id="evening_on_track",
        category="calories",
        message=(
            "You're closing the day right around your target — nicely played. A light "
            "evening keeps it landed."
        ),
        pro_tip="If late-night hunger shows up, sparkling water or herbal tea usually settles it.",
        priority=25,
        cooldown_days=3,
        trigger="evening_on_track",
    ),
)
