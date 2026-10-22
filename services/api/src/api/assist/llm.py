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

import asyncio
import importlib
import re
from typing import Any, Protocol

from pydantic import ValidationError

from ..config import settings
from .schemas import AssistTurn, Intent

PROMPT_VERSION = "vocal-assist-2026-10-22.1"
TOOL_NAME = "answer_request"
# The phone gives POST /assist 15 s (APIClient.swift fastTimeout). A form read after that lands a
# change the person was told failed, with no Undo on the screen, and the SDK's defaults (a
# 10-minute timeout, two retries) allowed one on a slow or overloaded call (2026-10-22 audit).
# One retry for a transient refusal, each attempt bounded, and the whole read under a wall clock:
# the SDK's timeout bounds each read, not the call.
ATTEMPT_TIMEOUT_S = 6.0
READ_BUDGET_S = 10.0

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
- A question about whether to change something ("should I switch to habits?", "what if I \
  tracked macros") changes nothing: kind "other". So does a change the person refuses ("I \
  don't want to switch", "don't stop the reminders"), and a change bounded in time, which the \
  app cannot make as said ("only on weekends", "for today", "until Monday").
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
        # The SDK's error family, known once the SDK is loaded; an injected client (tests) keeps
        # the empty tuple, so its errors propagate as they are.
        self._errors: tuple[type[BaseException], ...] = ()

    def _ensure_client(self) -> Any:
        if self._client is None:
            # Loaded on first use, by name: the SDK is heavy and most processes (the suite, a
            # key-less dev server) never need it.
            sdk = importlib.import_module("anthropic")
            self._client = sdk.AsyncAnthropic(
                api_key=settings.anthropic_api_key, timeout=ATTEMPT_TIMEOUT_S, max_retries=1
            )
            self._errors = (sdk.APIError,)
        return self._client

    async def extract(self, text: str, thread: list[AssistTurn]) -> dict[str, Any]:
        client = self._ensure_client()
        try:
            response = await asyncio.wait_for(
                client.messages.create(
                    model=self.model,
                    max_tokens=self._max_tokens,
                    system=[{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}],
                    tools=[TOOL_SCHEMA],
                    tool_choice={"type": "tool", "name": TOOL_NAME},
                    messages=build_messages(text, thread),
                ),
                timeout=READ_BUDGET_S,
            )
        except TimeoutError as exc:
            msg = f"The model read ran past its {READ_BUDGET_S:.0f} s budget"
            raise AssistError(msg) from exc
        except self._errors as exc:  # the API's refusals, timeouts and connection losses: one honest failure upstream
            raise AssistError(str(exc)) from exc
        for block in response.content:
            if getattr(block, "type", None) == "tool_use" and block.name == TOOL_NAME:
                return dict(block.input)
        msg = f"Model response contained no {TOOL_NAME} tool call"
        raise AssistError(msg)


# The rules. Explicit words only: a reading that changes a setting must be one the person would
# recognise in their own sentence; everything unsure is "other" (the honest no) or "meal".
_SHOW = re.compile(r"\b(how much|how many|how far|how am i|how'?s|how is|what'?s left|left|so far|show|where|see|open|remaining|why|what are)\b")
# A verb that takes a mode as its object; "just" and "only" count only right before the mode
# ("just calories"), and wanting counts only with the mode as what is wanted. Read loosely they
# turned "I just ate 500 calories" and "I want to cut calories" into a switch (2026-10-22).
_SET = re.compile(r"\b(switch|follow|track|watch|go back|go to|change (me )?to|set me|put me|move me|start|use|mode)\b")
_JUST_MODE = re.compile(r"\b(just|only) (the )?(habits?|calories|macros?|meal plan|five)\b")
_WANT_MODE = re.compile(r"\bi( only| just)?( want|'d like| would like) (to (track|watch|follow|see|use) )?(the |a |my )?(habits?|calories|macros?|meal plan|five)\b")
# "Fewer" is the essential level, never off; "turn ... on" spans a few words, never a clause.
_STOP = re.compile(r"\b(stop|mute|turn off|no more|quiet|silence|enough|don'?t remind|don'?t send)\b")
_START = re.compile(r"\b(turn (\w+ ){0,3}?(back )?on|turn on|unmute|bring (\w+ ){0,3}?back|back on|resume)\b")
# Every subject at once. "Notifications" and "alerts" name reminders, not all of them: "stop
# the protein notifications" turned every reminder off.
_ALL = re.compile(r"\b(all|every|everything|any)\b")
_REMINDER = re.compile(r"\b(remind\w*|nudge\w*|tip\w*|notification\w*|alert\w*|ones|them|messages|pings?)\b")
_LEVEL_OFF = re.compile(r"\b(nothing|no reminders|no tips|leave me alone|check in myself|say nothing|(don'?t|do not) want (any )?(reminders|tips|notifications|nudges))\b")
_LEVEL_ESSENTIAL = re.compile(r"\b(only when|slipping|essential|less often|fewer|less)\b")
_LEVEL_STANDARD = re.compile(r"\b(coach me|more tips|along the way|more often)\b")
_LOGGING = re.compile(r"\b(log|logging|check[- ]?ins?|remind\w*|track)\b")
_ALSO_SHOW = re.compile(r"\b(also show|also track|add|include|put .* on|show .* too|bring .* on)\b")
_REMOVE = re.compile(r"\b(take .* off|remove|hide|drop (the )?\w+ (tile|from today|off)|don'?t show|stop showing|off today)\b")
# What no rule may turn into a change (2026-10-22 audit). A question about a change asks, it
# does not choose ("should I switch to habits?"). A change refused is no change ("I don't want
# to switch", "don't stop the reminders"). A change bounded in time is one the app cannot make
# as said ("stop the protein reminders on weekends"), so muting for good would misread it.
_ADVICE = re.compile(r"\b(should i|should we|what if|is it (better|worth|ok|okay|good|bad)|do you think|would it|how do i|how can i)\b")
_NEGATED = re.compile(r"\b(don'?t|do not|doesn'?t|never|not|won'?t|no longer|can'?t|cannot)\b")
_NEGATED_STOP = re.compile(r"\b(don'?t|do not|never|not)( \w+)? (stop|mute|turn off|quiet|silence)\b")
_BOUNDED = re.compile(
    r"\b(on (the )?weekends?|on weekdays|at night|before bed|at bedtime|before i sleep|in the (morning|afternoon|evening)|today|tonight|tomorrow|"
    r"for (now|a while|a bit|(a|one|two|three|\d+|this|the) (day|days|week|weeks|hour|hours|month))|"
    r"this (week|weekend|month)|until|till|after \d|before \d)\b"
)
# A quantity is a log ("add 16 oz of water"), never a tile.
_AMOUNT = re.compile(r"\b\d+(\.\d+)? ?(oz|ounces?|ml|l|liters?|litres?|cups?|glass(es)?|g|grams?|bottles?)\b")
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
# Each friction with the struggle in it: the person saying what gets in their way, never a word
# in passing. Bare words turned "forget it" into a friction, "what portion of my calories is
# protein" into portions and "I ate out at a restaurant" (a meal) into eating out.
_FRICTIONS_RX: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\b(i ([\w']+ )?forget\w*|forgetting|i forgot|forgetful)\b"), "forgetting"),
    (re.compile(
        r"\b(portion\w*|amounts?)\b.*\b(hard|tricky|difficult|confus\w*|tough|guess\w*|struggle|trouble|unsure|not sure|no idea)\b"
        r"|\b(hard|struggle|trouble|unsure|not sure|no idea|guess\w*)\b.*\b(portion\w*|amounts?)\b"
    ), "portions"),
    (re.compile(r"\b(i ([\w']+ )?eat out|eating out|restaurants? (are|is) (hard|tough|tricky|difficult))\b"), "eating_out"),
    (re.compile(r"\b(too long|no time|takes long|takes forever|too much time|too slow)\b"), "time"),
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


_OTHER: dict[str, Any] = {"kind": "other"}


def read(text: str) -> dict[str, Any]:
    """The rules, in the server's order: the first reader with an answer wins. A question about
    a change reaches only the readers that change nothing."""
    t = " ".join(text.lower().replace("\u2019", "'").split())
    readers = (
        (_read_show, _read_surface) if _ADVICE.search(t)
        else (_read_anchor, _read_reminders, _read_level, _read_friction, _read_focus, _read_show, _read_mode, _read_surface)
    )
    for reader in readers:
        intent = reader(t)
        if intent is not None:
            return intent
    if _MEAL.search(t):
        return {"kind": "meal"}
    return dict(_OTHER)


def _read_anchor(t: str) -> dict[str, Any] | None:
    anchor = _first(_ANCHORS_RX, t)
    if anchor and _LOGGING.search(t) and not (_STOP.search(t) or _NEGATED.search(t) or re.search(r"\bno\b", t)):
        return {"kind": "set_anchor", "anchor": anchor}
    return None


def _read_reminders(t: str) -> dict[str, Any] | None:
    """Waking or quieting reminders: one subject's, or the level when none (or all) is named.
    Unsure is the honest no, and it ends the reading: a later reader must not take the words."""
    if not _REMINDER.search(t):
        return None
    starting, stopping = _START.search(t), _STOP.search(t)
    if (starting or stopping) and (_BOUNDED.search(t) or _NEGATED_STOP.search(t) or (starting and stopping)):
        return dict(_OTHER)
    subject = _first(_SUBJECTS_RX, t)
    if starting:
        return {"kind": "unmute", "subject": subject} if subject else {"kind": "set_level", "level": "standard"}
    if stopping:
        if subject and not _ALL.search(t):
            return {"kind": "mute", "subject": subject}
        return {"kind": "set_level", "level": "off"}
    return None


def _read_level(t: str) -> dict[str, Any] | None:
    off = (_LEVEL_OFF.search(t) and _REMINDER.search(t)) or re.search(r"\b(leave me alone|check in myself)\b", t)
    standard = _LEVEL_STANDARD.search(t)
    essential = _LEVEL_ESSENTIAL.search(t) and (_REMINDER.search(t) or "slipping" in t)
    if not (off or standard or essential):
        return None
    if _BOUNDED.search(t) or (_NEGATED.search(t) and not off):
        return dict(_OTHER)
    if off:
        return {"kind": "set_level", "level": "off"}
    return {"kind": "set_level", "level": "standard" if standard else "essential"}


def _read_friction(t: str) -> dict[str, Any] | None:
    friction = _first(_FRICTIONS_RX, t)
    if not friction or _SHOW.search(t):
        return None
    if re.search(r"\b(don'?t|doesn'?t|isn'?t|aren'?t|no longer|not anymore|anymore|stop|never)\b", t):
        return {"kind": "set_frictions", "frictions_remove": [friction]}
    return {"kind": "set_frictions", "frictions_add": [friction]}


def _read_focus(t: str) -> dict[str, Any] | None:
    tile = _FOCUS_WORDS.get(_first(_METRICS_RX, t) or "")
    if not tile or _AMOUNT.search(t):
        return None
    if _REMOVE.search(t):
        if re.search(r"\b(don'?t|do not|never|not) (remove|hide|take|drop)\b", t):
            return dict(_OTHER)
        return {"kind": "set_focus", "focus_remove": [tile]}
    if _NEGATED.search(t):
        return None
    if _ALSO_SHOW.search(t) and not _SHOW.search(t.replace("also show", "")):
        return {"kind": "set_focus", "focus_add": [tile]}
    return None


def _read_show(t: str) -> dict[str, Any] | None:
    if not _SHOW.search(t):
        return None
    # A question about a target, the week, the plan or the person's details is about the
    # surface that holds it, even when it names a metric ("why is my protein 160").
    surface = _first(_SURFACES_RX, t)
    if surface in {"protocol", "week", "plan", "profile", "notifications", "settings"}:
        return {"kind": "show", "show": surface}
    metric = _first(_METRICS_RX, t)
    if metric:
        return {"kind": "show", "show": metric}
    if surface:
        return {"kind": "show", "show": surface}
    return None


def _read_mode(t: str) -> dict[str, Any] | None:
    mode = _first(_MODES_RX, t)
    if not mode or not (_SET.search(t) or _JUST_MODE.search(t) or _WANT_MODE.search(t)):
        return None
    if _NEGATED.search(t):
        return dict(_OTHER)
    return {"kind": "set_mode", "mode": mode}


def _read_surface(t: str) -> dict[str, Any] | None:
    """"My week", "the plan": a surface named with nothing else said about it."""
    surface = _first(_SURFACES_RX, t)
    if surface in {"week", "protocol", "plan", "profile"} and re.search(r"\b(my|the)\b", t) and not _MEAL.search(t):
        return {"kind": "show", "show": surface}
    return None


def get_assist_client() -> AssistClient:
    """The model when a key is configured and the suite is not running; the rules otherwise."""
    if settings.test_mode or not settings.anthropic_api_key:
        return RulesAssistClient()
    return AnthropicAssistClient()
