"""Every sentence the bar's answer says, final (decision 71, spec 5.5).

The anatomy rule of the nudge catalog applies: recognition, invitation, agency; no exclamation
mark; no feeling the engine did not measure; no grade; under 140 characters so the line fits the
sheet in one breath. ``every_line`` enumerates them for the test that pins the rule.
"""

from __future__ import annotations

from collections.abc import Iterator

from ..nudges.catalog import title_for
from ..tracking.projection import check_slots_for
from ..tracking.schemas import FocusMetric, Friction, LogAnchor, NudgeLevel, TrackingMode

MODE_TITLES: dict[TrackingMode, str] = {
    TrackingMode.HABITS: "Build better habits",
    TrackingMode.CALORIES: "Watch my calories",
    TrackingMode.METHOD: "Calories, protein, fat, produce, fiber, water",
    TrackingMode.MACROS: "Track my macros",
    TrackingMode.MEAL_PLAN: "Follow a meal plan",
}
MODE_SHORT: dict[TrackingMode, str] = {
    TrackingMode.HABITS: "Habits",
    TrackingMode.CALORIES: "Calories",
    TrackingMode.METHOD: "The method",
    TrackingMode.MACROS: "Macros",
    TrackingMode.MEAL_PLAN: "Meal plan",
}
# The mode inside a sentence: a menu title as a sentence's object read as one ("You're following
# Watch my calories now."; the 2026-10-16 audit, C18).
MODE_INLINE: dict[TrackingMode, str] = {
    TrackingMode.HABITS: "habits",
    TrackingMode.CALORIES: "calories",
    TrackingMode.METHOD: "the method",
    TrackingMode.MACROS: "macros",
    TrackingMode.MEAL_PLAN: "a meal plan",
}
# What the person asks for, by the word they use, to the panel's metric and its label.
METRICS: dict[str, tuple[str, str]] = {
    "calories": ("kcal", "Calories"),
    "protein": ("protein", "Protein"),
    "carbs": ("carbs", "Carbs"),
    "fat": ("fat", "Fat"),
    "fiber": ("fiber", "Fiber"),
    "water": ("water", "Water"),
    "produce": ("produce", "Produce"),
    "sugar": ("sugar", "Sugar"),
    "sodium": ("sodium", "Sodium"),
}
FOCUS_LABELS: dict[FocusMetric, str] = {
    FocusMetric.PROTEIN: "Protein",
    FocusMetric.FIBER: "Fiber",
    FocusMetric.WATER: "Water",
    FocusMetric.PRODUCE: "Produce",
    FocusMetric.CARBS: "Carbs",
    FocusMetric.FAT: "Fat",
    FocusMetric.SUGAR: "Sugar",
    FocusMetric.SODIUM: "Sodium",
}
LEVEL_LINES: dict[NudgeLevel, str] = {
    NudgeLevel.ESSENTIAL: "Vo-Cal will say something only when you're slipping.",
    NudgeLevel.STANDARD: "Vo-Cal will coach you along the way. Never more than two a day.",
    NudgeLevel.OFF: "Vo-Cal will say nothing. Your weekly check-in still shows when it's due.",
}
LEVEL_SHORT: dict[NudgeLevel, str] = {
    NudgeLevel.ESSENTIAL: "Only when slipping",
    NudgeLevel.STANDARD: "Coach me",
    NudgeLevel.OFF: "Nothing",
}
ANCHOR_PHRASES: dict[LogAnchor, str] = {
    LogAnchor.AFTER_EATING: "right after you eat",
    LogAnchor.WHEN_SEATED: "when you sit back down",
    LogAnchor.BEFORE_BED: "before bed",
    LogAnchor.OWN: "your own moment",
}
ANCHOR_SHORT: dict[LogAnchor, str] = {
    LogAnchor.AFTER_EATING: "Right after I eat",
    LogAnchor.WHEN_SEATED: "When I sit back down",
    LogAnchor.BEFORE_BED: "Before bed",
    LogAnchor.OWN: "My own moment",
}
FRICTION_TITLES: dict[Friction, str] = {
    Friction.FORGETTING: "I forget",
    Friction.PORTIONS: "Portions and amounts",
    Friction.EATING_OUT: "Eating out",
    Friction.TIME: "It takes too long",
}
FRICTION_MOVES: dict[Friction, str] = {
    Friction.FORGETTING: "A reminder in the evening when a meal is still unlogged.",
    Friction.PORTIONS: "A question about an amount you left vague, more often.",
    Friction.EATING_OUT: "The photo path, right on the bar.",
    Friction.TIME: "Each meal offered as a usual, until you have a few.",
}
# "The {x} reminders": the category as an adjective.
SUBJECT_WORDS: dict[str, str] = {
    "consistency": "daily",
    "calories": "calorie",
    "protein": "protein",
    "water": "water",
    "produce": "produce",
    "fiber": "fiber",
    "plan": "meal plan",
}
POINTER_LINES: dict[str, str] = {
    "today": "It's on Today.",
    "week": "Your week is on Today, under your meals.",
    "protocol": "Your targets and their whys are in My protocol.",
    "plan": "Your plan is in Settings, under Meal plan.",
    "settings": "How you track lives in Settings.",
    "notifications": "Reminders live in Settings, under Notifications.",
    "profile": "Your details and your goal are in Settings, under My details.",
}
POINTER_TITLES: dict[str, str] = {
    "today": "Today",
    "week": "Today",
    "protocol": "My protocol",
    "plan": "Meal plan",
    "settings": "Settings",
    "notifications": "Notifications",
    "profile": "My details",
}

# No first person: every other line speaks as the app, not as an "I" (the audit, C17).
MEAL = "No food in that. Say the meal again."
OTHER = "That's not something Vo-Cal does. Say what you ate, or ask about your day and how you track."
UNDONE = "Undone."
# The fact and a stop: a person who chose no numbers is never invited to see calories
# (decision 72), not even in an answer.
NO_NUMBERS = "Your way shows no numbers."
NO_WEEK_CARD = "Your way has no week card. The dots on the week strip are your record."
NO_PLAN_MODE = "A meal plan comes with Follow a meal plan. Your way has none."
NOTHING_EXTRA = "Nothing extra"
NOTHING = "Nothing"


def mode_changed(mode: TrackingMode) -> str:
    return f"You're following {MODE_INLINE[mode]} now."


def mode_already(mode: TrackingMode) -> str:
    return f"You're already following {MODE_INLINE[mode]}."


def focus_on(metric: FocusMetric) -> str:
    return f"{FOCUS_LABELS[metric]} is on Today now."


def focus_off(metric: FocusMetric) -> str:
    return f"{FOCUS_LABELS[metric]} is off Today now."


def focus_already_on(metric: FocusMetric) -> str:
    return f"{FOCUS_LABELS[metric]} is already on Today."


def focus_already_off(metric: FocusMetric) -> str:
    return f"{FOCUS_LABELS[metric]} isn't on Today."


def anchor_line(anchor: LogAnchor, evening_reminder: bool) -> str:
    """The moment and what it moves, with the slots the server actually set (projection.py),
    never a second table of times. The evening reminder exists only for a person who asked for
    it ("I forget") or logs before bed (experience_for), so it is named only then; "reminder"
    is the word, because "check-in" is the weekly form's (the 2026-10-16 audit, C6, A16)."""
    slots = check_slots_for(anchor)
    if slots.late_morning is None:
        return f"One reminder at {slots.evening} now, and nothing before the evening."
    times = f"{slots.late_morning} and {slots.evening}" if evening_reminder else slots.late_morning
    if anchor is LogAnchor.OWN:
        return f"Nothing moves. The {'reminders stay' if evening_reminder else 'reminder stays'} at {times}."
    verb = "reminders follow" if evening_reminder else "reminder follows"
    return f"Your {verb} {ANCHOR_PHRASES[anchor]} now: {times}."


# The friction inside a sentence, not its menu title ("Noted: I forget."; the audit, C18).
FRICTION_INLINE: dict[Friction, str] = {
    Friction.FORGETTING: "forgetting",
    Friction.PORTIONS: "portions and amounts",
    Friction.EATING_OUT: "eating out",
    Friction.TIME: "the time it takes",
}


def friction_added(friction: Friction) -> str:
    return f"Noted, {FRICTION_INLINE[friction]}. {FRICTION_MOVES[friction]}"


def friction_removed(friction: Friction) -> str:
    inline = FRICTION_INLINE[friction]
    return f"Noted. {inline[0].upper()}{inline[1:]} is off your list."


def muted(subject: str) -> str:
    return f"The {SUBJECT_WORDS[subject]} reminders stay quiet until you turn them back on."


def unmuted(subject: str) -> str:
    return f"The {SUBJECT_WORDS[subject]} reminders are back on."


def muted_value(subject: str) -> str:
    return title_for(subject)


def shown(label: str) -> str:
    return f"Your {label.lower()} today."


def not_on_today(label: str) -> str:
    return f"{label} isn't on your Today. Say 'also show {label.lower()}' and it will be."


def every_line() -> Iterator[str]:
    """Every sentence this module can say, for the anatomy test."""
    for mode in TrackingMode:
        yield mode_changed(mode)
        yield mode_already(mode)
    for metric in FocusMetric:
        yield focus_on(metric)
        yield focus_off(metric)
        yield focus_already_on(metric)
        yield focus_already_off(metric)
    for _, label in METRICS.values():
        yield shown(label)
        yield not_on_today(label)
    yield from LEVEL_LINES.values()
    for anchor in LogAnchor:
        yield anchor_line(anchor, False)
        yield anchor_line(anchor, True)
    for friction in Friction:
        yield friction_added(friction)
        yield friction_removed(friction)
    for subject in SUBJECT_WORDS:
        yield muted(subject)
        yield unmuted(subject)
    yield from POINTER_LINES.values()
    yield MEAL
    yield OTHER
    yield UNDONE
    yield NO_NUMBERS
