"""The reader of a sentence that is not food (decision 71).

Two clients behind one seam, the parser's pattern (parser/llm.py):

- ``AnthropicAssistClient``: ``settings.assist_model`` (Haiku 4.5), the system prompt cached,
  the one tool forced, so the model's only output is the form (schemas.Intent). ``max_tokens``
  300: a form, never prose.
- ``RulesAssistClient``: a deterministic keyword reading of the same form, for the offline
  suite (``TEST_MODE``) and a dev server without a key. The feature degrades to the rules,
  never to silence; a model error is an honest failure (the router's 502), never a guess.

Neither client ever sees a number the person logged; the sentence and the thread are the input,
the form is the output, and the apply step (apply.py) does everything else.
"""

from __future__ import annotations

import re
from typing import Any, Protocol

from pydantic import ValidationError

from ..config import settings
from .schemas import AssistTurn, Intent

PROMPT_VERSION = "vocal-assist-2026-10-04.1"
TOOL_NAME = "answer_request"

_MODES = ["habits", "calories", "five", "macros", "meal_plan"]
_FOCUS = ["protein", "fiber", "water", "produce", "carbs", "fat", "sugar", "sodium"]
_LEVELS = ["essential", "standard", "off"]
_ANCHORS = ["after_eating", "when_seated", "before_bed", "own"]
_FRICTIONS = ["forgetting", "portions", "eating_out", "time"]
_SUBJECTS = ["consistency", "calories", "protein", "water", "produce", "fiber", "plan"]
_SHOWN = [*_FOCUS, "calories", "today", "week", "protocol", "plan", "settings", "notifications", "profile"]


def _enum(values: list[str], description: str) -> dict[str, Any]:
    return {"type": "string", "enum": values, "description": description}


def _enum_list(values: list[str], description: str) -> dict[str, Any]:
    return {"type": "array", "items": {"type": "string", "enum": values}, "description": description}


# JSON Schema for the forced tool. Kept in lockstep with schemas.Intent.
TOOL_SCHEMA: dict[str, Any] = {
    "name": TOOL_NAME,
    "description": (
        "Record what the person asked Vo-Cal for, as a form. Call this exactly once. "
        "Never write prose: the app has every sentence it will say."
    ),
    "input_schema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["kind"],
        "properties": {
            "kind": _enum(
                ["set_mode", "set_focus", "set_level", "set_anchor", "set_frictions",
                 "mute", "unmute", "show", "meal", "other"],
                "set_mode: change how they track. set_focus: add or remove a tile on Today. "
                "set_level: how much the app says (stop all reminders = off). set_anchor: when "
                "they log. set_frictions: what gets in the way. mute/unmute: quiet or wake the "
                "reminders about one subject. show: a number from today or a surface. meal: the "
                "sentence describes eating, however vaguely. other: anything Vo-Cal does not do.",
            ),
            "mode": _enum(_MODES, "set_mode: habits (no numbers), calories (one number), five (calories, protein, produce, fiber, water), macros, meal_plan."),
            "focus_add": _enum_list(_FOCUS, "set_focus: tiles to add to Today."),
            "focus_remove": _enum_list(_FOCUS, "set_focus: tiles to take off Today."),
            "level": _enum(_LEVELS, "set_level: essential (only when slipping), standard (coach me), off (nothing)."),
            "anchor": _enum(_ANCHORS, "set_anchor: after_eating, when_seated, before_bed, own (their own moment)."),
            "frictions_add": _enum_list(_FRICTIONS, "set_frictions: forgetting, portions, eating_out, time (it takes too long)."),
            "frictions_remove": _enum_list(_FRICTIONS, "set_frictions: what no longer gets in the way."),
            "subject": _enum(_SUBJECTS, "mute/unmute: the reminders about this subject. consistency = reminders about the day itself."),
            "show": _enum(_SHOWN, "show: a metric from today, or a surface (week, protocol for targets and their whys, plan, settings, notifications, profile for weight and goal)."),
        },
    },
}

SYSTEM_PROMPT = """\
You read one sentence a person typed or said into Vo-Cal, a voice-first nutrition tracker, after \
the meal parser found no food in it. Fill the answer_request form and nothing else. You never \
write a sentence the person reads and never a number: the app has its own words and its own \
arithmetic.

Rules:
- A sentence that describes eating or drinking, however vaguely ("I had a thing", "a bowl of \
  something", "lunch was big"), is kind "meal". The app will ask them to say it again.
- "Stop all reminders", "leave me alone", "no notifications" is set_level off, never mute. \
  "Only when I'm slipping" is set_level essential. "Coach me" is set_level standard.
- "Stop the protein reminders", "no more water tips" is mute with the subject. "Bring them \
  back", "turn the water ones on" is unmute.
- "Switch to habits", "just calories", "I want to track macros", "follow a meal plan" is \
  set_mode. "Also show fiber", "add sugar", "take sugar off" is set_focus.
- "I'll log before bed", "right after I eat", "when I sit back down" is set_anchor. "I forget", \
  "portions are hard", "I eat out a lot", "it takes too long" is set_frictions add; "I don't \
  forget anymore" removes.
- A question about today's amounts ("how much protein do I have left", "calories so far") is \
  show with the metric. "How's my week", "show my week" is show week. "Why is my protein 160", \
  "what are my targets" is show protocol. "Change my weight", "my goal" is show profile. \
  "Where are the reminders" is show notifications.
- Use the thread only to resolve a follow-up ("actually, coach me" after a level change).
- Anything Vo-Cal does not do (recipes, the weather, chat) is kind "other".
"""


class AssistError(Exception):
    """The reader produced no form."""


class AssistClient(Protocol):
    name: str

    async def extract(self, text: str, thread: list[AssistTurn]) -> dict[str, Any]: ...


def build_messages(text: str, thread: list[AssistTurn]) -> list[dict[str, Any]]:
    """The thread as alternating turns, then the sentence as the last user turn. The API wants
    user first and roles alternating: a leading app turn is dropped, consecutive same-role turns
    are joined."""
    messages: list[dict[str, Any]] = []
    for turn in thread:
        role = "user" if turn.role == "person" else "assistant"
        if not messages and role == "assistant":
            continue
        if messages and messages[-1]["role"] == role:
            messages[-1]["content"] = f"{messages[-1]['content']}\n{turn.text}"
            continue
        messages.append({"role": role, "content": turn.text})
    if messages and messages[-1]["role"] == "user":
        messages[-1]["content"] = f"{messages[-1]['content']}\n{text}"
    else:
        messages.append({"role": "user", "content": text})
    return messages


def parse_intent(raw: dict[str, Any]) -> Intent:
    """The form, validated; a form this build cannot read is ``other``, never a guess."""
    try:
        return Intent.model_validate(raw)
    except ValidationError:
        return Intent(kind="other")


class AnthropicAssistClient:
    """The model reader: the parser client's shape (parser/llm.py AnthropicParserClient)."""

    name = "model"

    def __init__(self, client: Any | None = None, *, model: str | None = None, max_tokens: int = 300) -> None:
        self.model = model or settings.assist_model
        self._max_tokens = max_tokens
        self._client = client  # lazily built if None

    def _ensure_client(self) -> Any:
        if self._client is None:
            from anthropic import AsyncAnthropic  # noqa: PLC0415  (lazy heavy SDK)

            self._client = AsyncAnthropic(api_key=settings.anthropic_api_key)
        return self._client

    async def extract(self, text: str, thread: list[AssistTurn]) -> dict[str, Any]:
        try:
            response = await self._ensure_client().messages.create(
                model=self.model,
                max_tokens=self._max_tokens,
                system=[{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}],
                tools=[TOOL_SCHEMA],
                tool_choice={"type": "tool", "name": TOOL_NAME},
                messages=build_messages(text, thread),
            )
        except Exception as exc:  # the SDK's errors, the network's: one honest failure upstream
            raise AssistError(str(exc)) from exc
        for block in response.content:
            if getattr(block, "type", None) == "tool_use" and block.name == TOOL_NAME:
                return dict(block.input)
        msg = f"Model response contained no {TOOL_NAME} tool call"
        raise AssistError(msg)


# The rules. Explicit words only: a reading that changes a setting must be one the person would
# recognise in their own sentence; everything unsure is "other" (the honest no) or "meal".
_SHOW = re.compile(r"\b(how much|how many|how far|how am i|how'?s|how is|what'?s left|left|so far|show|where|see|open|remaining|why|what are)\b")
_SET = re.compile(r"\b(switch|follow|track|watch|change|use|go back|go to|set|put me|move me|start|i want to|i'?d like to|just|only|mode)\b")
_STOP = re.compile(r"\b(stop|mute|turn off|no more|quiet|silence|enough|don'?t remind|don'?t send|fewer|without)\b")
_START = re.compile(r"\b(turn .* on|turn on|unmute|bring .* back|back on|resume|wake)\b")
_ALL = re.compile(r"\b(all|every|everything|any|notifications|alerts)\b")
_REMINDER = re.compile(r"\b(remind\w*|nudge\w*|tip\w*|notification\w*|alert\w*|ones|them|messages|pings?)\b")
_LEVEL_OFF = re.compile(r"\b(nothing|no reminders|no tips|leave me alone|check in myself|say nothing)\b")
_LEVEL_ESSENTIAL = re.compile(r"\b(only when|slipping|essential|less often|fewer|less)\b")
_LEVEL_STANDARD = re.compile(r"\b(coach me|coach|more tips|along the way|more often)\b")
_LOGGING = re.compile(r"\b(log|logging|check[- ]?ins?|remind\w*|track)\b")
_ALSO_SHOW = re.compile(r"\b(also show|also track|add|include|put .* on|show .* too|bring .* on)\b")
_REMOVE = re.compile(r"\b(take .* off|remove|hide|drop|don'?t show|stop showing|off today)\b")
_MEAL = re.compile(r"\b(i had|i ate|ate|had a|had some|had an|for (breakfast|lunch|dinner)|a bowl|a plate|a cup of|and some|snack|drank|eating)\b")
_SUBJECTS_RX: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bprotein\b"), "protein"),
    (re.compile(r"\b(water|hydrat\w*)\b"), "water"),
    (re.compile(r"\b(produce|vegetable\w*|veg|veggies|fruit\w*)\b"), "produce"),
    (re.compile(r"\b(fiber|fibre)\b"), "fiber"),
    (re.compile(r"\b(calorie\w*|kcal|treat\w*)\b"), "calories"),
    (re.compile(r"\b(plan|meal plan)\b"), "plan"),
    (re.compile(r"\b(day|daily|quiet days|consistency)\b"), "consistency"),
]
_METRICS_RX: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bprotein\b"), "protein"),
    (re.compile(r"\b(calorie\w*|kcal)\b"), "calories"),
    (re.compile(r"\bcarb\w*\b"), "carbs"),
    (re.compile(r"\bfats?\b"), "fat"),
    (re.compile(r"\b(fiber|fibre)\b"), "fiber"),
    (re.compile(r"\b(water|hydrat\w*)\b"), "water"),
    (re.compile(r"\b(produce|vegetable\w*|veg|veggies|fruit\w*)\b"), "produce"),
    (re.compile(r"\bsugar\w*\b"), "sugar"),
    (re.compile(r"\b(sodium|salt)\b"), "sodium"),
]
_SURFACES_RX: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bweek\b"), "week"),
    (re.compile(r"\b(protocol|targets?|why)\b"), "protocol"),
    (re.compile(r"\b(meal plan|plan)\b"), "plan"),
    (re.compile(r"\b(notification\w*|reminder\w*)\b"), "notifications"),
    (re.compile(r"\b(weight|goal|details?|height|age)\b"), "profile"),
    (re.compile(r"\bsettings?\b"), "settings"),
    (re.compile(r"\btoday\b"), "today"),
]
_MODES_RX: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bhabits?\b"), "habits"),
    (re.compile(r"\bmacros?\b"), "macros"),
    (re.compile(r"\bmeal plan\b"), "meal_plan"),
    (re.compile(r"\b(the five|five things)\b"), "five"),
    (re.compile(r"\bcalorie\w*\b"), "calories"),
]
_ANCHORS_RX: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\b(before bed|at night|end of the day|all at once|before i sleep)\b"), "before_bed"),
    (re.compile(r"\b(right after|after i eat|after eating|as i eat|after each meal|after every meal)\b"), "after_eating"),
    (re.compile(r"\b(sit back down|at my desk|when i sit|back at my desk)\b"), "when_seated"),
    (re.compile(r"\b(my own moment|whenever|own time|my own time)\b"), "own"),
]
_FRICTIONS_RX: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bforget\w*\b"), "forgetting"),
    (re.compile(r"\b(portion\w*|amounts?)\b"), "portions"),
    (re.compile(r"\b(eat out|eating out|restaurant\w*)\b"), "eating_out"),
    (re.compile(r"\b(too long|no time|takes long|takes forever)\b"), "time"),
]
# The metrics a person can add to Today as a tile; calories is the card and never one.
_FOCUS_WORDS: dict[str, str] = {
    "protein": "protein", "carbs": "carbs", "fat": "fat", "fiber": "fiber",
    "water": "water", "produce": "produce", "sugar": "sugar", "sodium": "sodium",
}


def _first(patterns: list[tuple[re.Pattern[str], str]], text: str) -> str | None:
    for pattern, value in patterns:
        if pattern.search(text):
            return value
    return None


class RulesAssistClient:
    """The keyword reading of the same form. Deterministic, offline, conservative."""

    name = "rules"
    model = "rules"

    async def extract(self, text: str, thread: list[AssistTurn]) -> dict[str, Any]:
        del thread  # the rules read one sentence; the thread is the model's to use
        return read(text)


def read(text: str) -> dict[str, Any]:  # noqa: PLR0912  (a rule table reads as branches)
    t = " ".join(text.lower().replace("\u2019", "'").split())
    anchor = _first(_ANCHORS_RX, t)
    if anchor and _LOGGING.search(t) and not _STOP.search(t):
        return {"kind": "set_anchor", "anchor": anchor}
    if _START.search(t) and _REMINDER.search(t):
        subject = _first(_SUBJECTS_RX, t)
        if subject:
            return {"kind": "unmute", "subject": subject}
        return {"kind": "set_level", "level": "standard"}
    if _STOP.search(t) and _REMINDER.search(t):
        subject = _first(_SUBJECTS_RX, t)
        if subject and not _ALL.search(t):
            return {"kind": "mute", "subject": subject}
        return {"kind": "set_level", "level": "off"}
    if (_LEVEL_OFF.search(t) and _REMINDER.search(t)) or re.search(r"\b(leave me alone|check in myself)\b", t):
        return {"kind": "set_level", "level": "off"}
    if _LEVEL_STANDARD.search(t):
        return {"kind": "set_level", "level": "standard"}
    if _LEVEL_ESSENTIAL.search(t) and (_REMINDER.search(t) or "slipping" in t):
        return {"kind": "set_level", "level": "essential"}
    friction = _first(_FRICTIONS_RX, t)
    if friction and not _SHOW.search(t):
        if re.search(r"\b(don'?t|no longer|not anymore|anymore|stop|never)\b", t):
            return {"kind": "set_frictions", "frictions_remove": [friction]}
        return {"kind": "set_frictions", "frictions_add": [friction]}
    metric = _first(_METRICS_RX, t)
    tile = _FOCUS_WORDS.get(metric or "")
    if tile and _REMOVE.search(t):
        return {"kind": "set_focus", "focus_remove": [tile]}
    if tile and _ALSO_SHOW.search(t) and not _SHOW.search(t.replace("also show", "")):
        return {"kind": "set_focus", "focus_add": [tile]}
    if _SHOW.search(t):
        # A question about a target, the week, the plan or the person's details is about the
        # surface that holds it, even when it names a metric ("why is my protein 160").
        surface = _first(_SURFACES_RX, t)
        if surface in {"protocol", "week", "plan", "profile", "notifications", "settings"}:
            return {"kind": "show", "show": surface}
        if metric:
            return {"kind": "show", "show": metric}
        if surface:
            return {"kind": "show", "show": surface}
    mode = _first(_MODES_RX, t)
    if mode and _SET.search(t):
        return {"kind": "set_mode", "mode": mode}
    surface = _first(_SURFACES_RX, t)
    if surface and re.search(r"\b(my|the)\b", t) and not _MEAL.search(t) and surface in {"week", "protocol", "plan", "profile"}:
        return {"kind": "show", "show": surface}
    if _MEAL.search(t):
        return {"kind": "meal"}
    return {"kind": "other"}


def get_assist_client() -> AssistClient:
    """The model when a key is configured and the suite is not running; the rules otherwise."""
    if settings.test_mode or not settings.anthropic_api_key:
        return RulesAssistClient()
    return AnthropicAssistClient()
