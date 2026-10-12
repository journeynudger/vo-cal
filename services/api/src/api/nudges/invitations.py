"""The ladder as an offer the person accepts (decision 62): pure, deterministic.

Up: habits → calories after 14 of the last 21 days logged; calories → protein as a focus after
15 of 21. Down: any numeric mode with fewer than 3 logged days in the last 14, when the week
before that still had logs (a new account is not invited down on day one). Never a mode the
person declined ("Don't offer this again"). The engine places an invitation only on a day no
other nudge fired, inside the nudge budget, with a 14-day cooldown by direction through the
ledger (the card id is the ledger key). No rank, level name or celebration: the copy names the
fact and the offer, nothing else (the Rams review, R6 and Q3).
"""

from __future__ import annotations

from dataclasses import dataclass

from ..tracking.schemas import FocusMetric, TrackingMode, offer_key

UP_AFTER_DAYS_OF_21 = 14
PROTEIN_AFTER_DAYS_OF_21 = 15
DOWN_UNDER_DAYS_OF_14 = 3
COOLDOWN_DAYS = 14

_DOWN: dict[TrackingMode, TrackingMode] = {
    TrackingMode.CALORIES: TrackingMode.HABITS,
    TrackingMode.FIVE: TrackingMode.CALORIES,
    TrackingMode.MACROS: TrackingMode.FIVE,
    TrackingMode.MEAL_PLAN: TrackingMode.FIVE,
}
_DOWN_WORDS: dict[TrackingMode, str] = {
    TrackingMode.HABITS: "Just the habits.",
    TrackingMode.CALORIES: "Just your calories.",
    TrackingMode.FIVE: "Calories, protein, produce, fiber and water.",
}


@dataclass(frozen=True)
class InvitationSignals:
    mode: TrackingMode
    focus_metrics: tuple[FocusMetric, ...]
    declined_offers: frozenset[str]
    days_logged_last_21: int
    days_logged_last_14: int
    # Logged days between 15 and 21 days ago: the "they used to log" evidence a step down needs.
    days_logged_days_15_to_21: int


@dataclass(frozen=True)
class Invitation:
    offer_key: str
    direction: str  # "up" | "down"
    message: str
    pro_tip: str
    offer_mode: TrackingMode | None = None
    offer_focus: FocusMetric | None = None

    @property
    def card_id(self) -> str:
        return f"invite:{self.offer_key}"


def suggest(s: InvitationSignals) -> Invitation | None:
    """At most one invitation for these signals, or None. Up before down: a person who logged
    14 of 21 days is not also thin in the last 14."""
    if s.mode is TrackingMode.HABITS and s.days_logged_last_21 >= UP_AFTER_DAYS_OF_21:
        key = offer_key(mode=TrackingMode.CALORIES)
        if key not in s.declined_offers:
            return Invitation(
                offer_key=key,
                direction="up",
                offer_mode=TrackingMode.CALORIES,
                message=(
                    f"You've logged {s.days_logged_last_21} of the last 21 days. "
                    "Want to see your calories too?"
                ),
                pro_tip="Your habits stay where they are. Calories would sit above them.",
            )
    if (
        s.mode is TrackingMode.CALORIES
        and s.days_logged_last_21 >= PROTEIN_AFTER_DAYS_OF_21
        and FocusMetric.PROTEIN not in s.focus_metrics
    ):
        key = offer_key(focus=FocusMetric.PROTEIN)
        if key not in s.declined_offers:
            return Invitation(
                offer_key=key,
                direction="up",
                offer_focus=FocusMetric.PROTEIN,
                message=(
                    f"You've logged {s.days_logged_last_21} of the last 21 days. "
                    "Want protein next to your calories?"
                ),
                pro_tip="Protein is the one number most people add first. It shows as a band, not a target.",
            )
    down = _DOWN.get(s.mode)
    if (
        down is not None
        and s.days_logged_last_14 < DOWN_UNDER_DAYS_OF_14
        and s.days_logged_days_15_to_21 >= 1
    ):
        key = offer_key(mode=down)
        if key not in s.declined_offers:
            return Invitation(
                offer_key=key,
                direction="down",
                offer_mode=down,
                message=(
                    "Logging has been thin for two weeks. Want to keep it simple for a while? "
                    f"{_DOWN_WORDS[down]}"
                ),
                pro_tip="Nothing is lost. Your record stays whole, and you can come back any time.",
            )
    return None
