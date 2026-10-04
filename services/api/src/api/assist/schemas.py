"""The form the model fills and the answer the phone draws (decision 71)."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

from ..meals.today import Panel
from ..nudges.reactions import ReactionRequest
from ..tracking.schemas import (
    FocusMetric,
    Friction,
    LogAnchor,
    NudgeLevel,
    TrackingMode,
    TrackingUpdate,
)

# The nudge catalog's categories a person can quiet or wake by name (catalog.py). "All" is not a
# subject: "stop all reminders" is the level, one version, never thirteen mutes.
Subject = Literal["consistency", "calories", "protein", "water", "produce", "fiber", "plan"]
# The surfaces the answer can point to; the phone opens the one it can reach and the line names
# where the rest live.
Surface = Literal["today", "week", "protocol", "plan", "settings", "notifications", "profile"]
Shown = Literal[
    "calories", "protein", "carbs", "fat", "fiber", "water", "produce", "sugar", "sodium",
    "today", "week", "protocol", "plan", "settings", "notifications", "profile",
]
IntentKind = Literal[
    "set_mode", "set_focus", "set_level", "set_anchor", "set_frictions",
    "mute", "unmute", "show", "meal", "other",
]
ReplyKind = Literal["changed", "shown", "pointed", "told", "meal"]


class Intent(BaseModel):
    """What the person asked, as a form over the app's own vocabularies. The model fills it
    (llm.py's forced tool); a form this build cannot read is ``other``, never a guess."""

    kind: IntentKind
    mode: TrackingMode | None = None
    focus_add: list[FocusMetric] = Field(default_factory=list, max_length=8)
    focus_remove: list[FocusMetric] = Field(default_factory=list, max_length=8)
    level: NudgeLevel | None = None
    anchor: LogAnchor | None = None
    frictions_add: list[Friction] = Field(default_factory=list, max_length=4)
    frictions_remove: list[Friction] = Field(default_factory=list, max_length=4)
    subject: Subject | None = None
    show: Shown | None = None


class AssistTurn(BaseModel):
    """One turn of the thread the phone holds for the life of the sheet: the person's sentence or
    the app's catalog line. Stored nowhere."""

    role: Literal["person", "app"]
    text: str = Field(min_length=1, max_length=500)


class AssistRequest(BaseModel):
    text: str = Field(min_length=1, max_length=500)
    thread: list[AssistTurn] = Field(default_factory=list, max_length=6)
    # The person's day and zone, for a number asked for (as GET /meals/today takes them).
    date: str | None = Field(default=None, max_length=10)
    tz: str | None = Field(default=None, max_length=64)


class AssistChange(BaseModel):
    """The changed row, as Settings draws it: the icon tile, the label, the value trailing."""

    icon: str
    title: str
    value: str


class AssistPointer(BaseModel):
    surface: Surface
    title: str


class AssistUndo(BaseModel):
    """What puts it back: the previous values through PUT /tracking, the opposite reactions
    through POST /nudges/reactions. The phone applies them with the calls it already makes."""

    tracking: TrackingUpdate | None = None
    reactions: list[ReactionRequest] = Field(default_factory=list)


class AssistReply(BaseModel):
    """The answer. ``kind`` says what happened; the line is the catalog's; exactly one of
    ``change``, ``panel``, ``pointer`` is the thing shown, or none when the line is the answer.
    ``turn`` is the app's turn for the phone to append to its thread. Additive by construction:
    a phone that does not know a kind draws the line alone."""

    kind: ReplyKind
    line: str
    change: AssistChange | None = None
    panel: Panel | None = None
    pointer: AssistPointer | None = None
    undo: AssistUndo | None = None
    turn: AssistTurn
    # Who read the sentence: "model" or "rules". The phone ignores it; the log names it.
    client: str = "rules"
