"""T1: POST /assist, the bar answers (decision 71).

Offline (FakeDatabase, the rules client). Proves: auth; each intent lands through the stores
Settings writes (a tracking version, reaction rows) and answers with the row, the Today card or
the line; Undo carries the previous values; a number asked in habits is the line that names the
switch; a metric not on Today says so; a meal nothing was heard in keeps the old copy; the
catalog's anatomy; the message builder for the model path; the wire shape.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any, ClassVar

import pytest
from prometheus_client import REGISTRY

from api.assist import lines
from api.assist.llm import (
    AnthropicAssistClient,
    AssistError,
    RulesAssistClient,
    build_messages,
    get_assist_client,
    parse_intent,
    read,
)
from api.assist.schemas import AssistTurn
from api.nudges.reactions import effects

DAY = {"date": "2026-10-04", "tz": "Europe/Rome"}


def _ask(client, auth_headers, text, **extra):
    body = {"text": text, **DAY, **extra}
    response = client.post("/assist", json=body, headers=auth_headers)
    assert response.status_code == 200, response.text
    return response.json()


def test_assist_requires_auth(client):
    assert client.post("/assist", json={"text": "switch to habits"}).status_code == 401


def test_offline_the_rules_read(client, auth_headers):
    assert isinstance(get_assist_client(), RulesAssistClient)
    assert _ask(client, auth_headers, "switch to habits")["client"] == "rules"


def test_the_maker_sees_counts_by_kind_and_reader_never_the_sentence(client, auth_headers):
    labels = {"kind": "set_level", "client": "rules"}
    before = REGISTRY.get_sample_value("assist_intents_total", labels) or 0.0
    _ask(client, auth_headers, "stop all reminders")
    assert REGISTRY.get_sample_value("assist_intents_total", labels) == before + 1
    # No label carries the person's words: the series names only the form's kind and the reader.
    assert all(key in {"kind", "client"} for key in labels)


def test_switch_mode_changes_and_undo_restores(client, auth_headers):
    reply = _ask(client, auth_headers, "switch to habits")
    assert reply["kind"] == "changed"
    assert reply["line"] == "You're following Build better habits now."
    assert reply["change"] == {"icon": "slider.horizontal.3", "title": "How I track", "value": "Habits"}
    assert reply["undo"]["tracking"]["mode"] == "five"
    assert reply["turn"] == {"role": "app", "text": reply["line"]}
    tracking = client.get("/tracking", headers=auth_headers).json()
    assert tracking["mode"] == "habits"
    assert tracking["version"] == 1
    assert tracking["source"] == "chosen"
    # Undo is the phone's PUT with the previous values: the same record a tap writes.
    undone = client.put("/tracking", json=reply["undo"]["tracking"], headers=auth_headers).json()
    assert undone["mode"] == "five"
    assert undone["version"] == 2


def test_the_same_mode_is_told_without_undo(client, auth_headers):
    reply = _ask(client, auth_headers, "I want to follow the five")
    assert reply["kind"] == "told"
    assert reply["line"] == "You're already following Calories, protein, produce, fiber, water."
    assert reply["change"]["value"] == "The five"
    assert reply["undo"] is None
    assert client.get("/tracking", headers=auth_headers).json()["version"] == 0


def test_also_show_and_take_off(client, auth_headers):
    on = _ask(client, auth_headers, "also show sugar")
    assert on["kind"] == "changed"
    assert on["line"] == "Sugar is on Today now."
    assert on["change"] == {"icon": "plus.circle", "title": "Also show", "value": "Sugar"}
    assert on["undo"]["tracking"]["focus_metrics"] == []
    assert client.get("/tracking", headers=auth_headers).json()["focus_metrics"] == ["sugar"]
    again = _ask(client, auth_headers, "also show sugar")
    assert again["kind"] == "told"
    assert again["line"] == "Sugar is already on Today."
    off = _ask(client, auth_headers, "take sugar off today")
    assert off["kind"] == "changed"
    assert off["line"] == "Sugar is off Today now."
    assert off["change"]["value"] == "Nothing extra"
    assert off["undo"]["tracking"]["focus_metrics"] == ["sugar"]


def test_stop_all_reminders_is_the_level_and_a_follow_up_resolves(client, auth_headers):
    off = _ask(client, auth_headers, "stop all reminders")
    assert off["kind"] == "changed"
    assert off["change"] == {"icon": "bell", "title": "Reminders", "value": "Nothing"}
    assert off["line"] == lines.LEVEL_LINES[lines.NudgeLevel.OFF]
    # Never chosen before: nothing to put back to, so no Undo is offered.
    assert off["undo"] is None
    assert client.get("/tracking", headers=auth_headers).json()["nudge_level"] == "off"
    thread = [{"role": "person", "text": "stop all reminders"}, off["turn"]]
    coach = _ask(client, auth_headers, "actually, coach me along the way", thread=thread)
    assert coach["kind"] == "changed"
    assert coach["change"]["value"] == "Coach me"
    assert coach["undo"]["tracking"]["nudge_level"] == "off"
    slipping = _ask(client, auth_headers, "only when I'm slipping")
    assert slipping["change"]["value"] == "Only when slipping"


def test_mute_a_subject_appends_reactions_and_undo_wakes_them(client, auth_headers, fake_db):
    reply = _ask(client, auth_headers, "stop the protein reminders")
    assert reply["kind"] == "changed"
    assert reply["line"] == "The protein reminders stay quiet until you turn them back on."
    assert reply["change"] == {"icon": "bell.slash", "title": "Muted", "value": "Protein"}
    assert reply["undo"] == {"tracking": None, "reactions": [{"nudge_id": "protein_gap", "kind": "unmute"}]}
    rows = fake_db.tables["nudge_reactions"]
    assert [(r["nudge_id"], r["kind"]) for r in rows] == [("protein_gap", "not_for_me")]
    assert effects(rows, datetime.now(UTC)).muted == frozenset({"protein_gap"})
    back = _ask(client, auth_headers, "bring the protein ones back")
    assert back["kind"] == "changed"
    assert back["line"] == "The protein reminders are back on."
    assert back["change"]["value"] == "Protein back on"
    assert back["undo"]["reactions"] == [{"nudge_id": "protein_gap", "kind": "not_for_me"}]
    assert effects(fake_db.tables["nudge_reactions"], datetime.now(UTC)).muted == frozenset()


def test_the_anchor_line_names_the_slots_the_server_set(client, auth_headers):
    bed = _ask(client, auth_headers, "I'll log before bed")
    assert bed["kind"] == "changed"
    assert bed["line"] == "One check-in at 20:30 now, and nothing before the evening."
    assert bed["change"] == {"icon": "clock", "title": "When you log", "value": "Before bed"}
    assert bed["undo"] is None  # never asked before
    assert client.get("/tracking", headers=auth_headers).json()["log_anchor"] == "before_bed"
    after = _ask(client, auth_headers, "I'll log right after I eat")
    assert after["line"] == "Your check-ins follow right after you eat now: 11:30 and 20:00."
    assert after["undo"]["tracking"]["log_anchor"] == "before_bed"


def test_a_friction_is_noted_with_what_it_moves(client, auth_headers):
    reply = _ask(client, auth_headers, "I forget")
    assert reply["kind"] == "changed"
    assert reply["line"] == "Noted: I forget. A reminder in the evening when a meal is still unlogged."
    assert reply["change"] == {"icon": "hand.raised", "title": "What gets in the way", "value": "I forget"}
    assert client.get("/tracking", headers=auth_headers).json()["frictions"] == ["forgetting"]
    gone = _ask(client, auth_headers, "I don't forget anymore")
    assert gone["line"] == "Noted. I forget is off your list."
    assert gone["change"]["value"] == "Nothing"
    assert gone["undo"]["tracking"]["frictions"] == ["forgetting"]


def test_a_number_asked_for_is_the_card_today_draws(client, auth_headers):
    reply = _ask(client, auth_headers, "how much protein do I have left")
    assert reply["kind"] == "shown"
    assert reply["line"] == "Your protein today."
    assert reply["panel"]["kind"] == "metric_tile"
    assert reply["panel"]["metric"] == "protein"
    assert reply["change"] is None
    assert reply["undo"] is None
    calories = _ask(client, auth_headers, "how many calories so far")
    assert calories["panel"]["kind"] == "calories_left"
    assert calories["panel"]["framing"] in {"to_date", "to_go"}


def test_a_number_in_habits_is_the_line_that_names_the_switch(client, auth_headers):
    client.put("/tracking", json={"mode": "habits"}, headers=auth_headers)
    reply = _ask(client, auth_headers, "how many calories so far")
    assert reply["kind"] == "told"
    assert reply["line"] == lines.NO_NUMBERS
    assert reply["panel"] is None


def test_a_metric_not_on_today_says_so(client, auth_headers):
    client.put("/tracking", json={"mode": "calories"}, headers=auth_headers)
    reply = _ask(client, auth_headers, "how much fiber do I have left")
    assert reply["kind"] == "told"
    assert reply["line"] == "Fiber isn't on your Today. Say 'also show fiber' and it will be."


def test_pointers(client, auth_headers):
    week = _ask(client, auth_headers, "show me my week")
    assert week["kind"] == "pointed"
    assert week["pointer"] == {"surface": "week", "title": "Today"}
    assert week["line"] == "Your week is on Today, under your meals."
    why = _ask(client, auth_headers, "why is my protein target 160")
    assert why["pointer"]["surface"] == "protocol"
    weight = _ask(client, auth_headers, "change my weight")
    assert weight["pointer"]["surface"] == "profile"
    where = _ask(client, auth_headers, "where are the reminders")
    assert where["pointer"]["surface"] == "notifications"


def test_a_meal_keeps_the_old_copy_and_the_rest_is_an_honest_no(client, auth_headers):
    meal = _ask(client, auth_headers, "I had a big bowl of something")
    assert meal["kind"] == "meal"
    assert meal["line"] == lines.MEAL
    other = _ask(client, auth_headers, "make me a sandwich")
    assert other["kind"] == "told"
    assert other["line"] == lines.OTHER
    assert other["undo"] is None
    assert client.get("/tracking", headers=auth_headers).json()["version"] == 0


def test_the_wire_shape_is_additive(client, auth_headers):
    reply = _ask(client, auth_headers, "switch to macros")
    assert set(reply) == {"kind", "line", "change", "panel", "pointer", "undo", "turn", "client"}
    assert client.post("/assist", json={"text": ""}, headers=auth_headers).status_code == 422
    assert client.post("/assist", json={"text": "x" * 501}, headers=auth_headers).status_code == 422
    seven = [{"role": "person", "text": "a"}] * 7
    assert client.post("/assist", json={"text": "hi", "thread": seven}, headers=auth_headers).status_code == 422


def test_every_line_keeps_the_anatomy():
    for line in lines.every_line():
        assert "!" not in line, line
        assert len(line) <= 140, line
        assert not line.lower().startswith("we "), line


def test_the_rules_read_the_spec_table():
    assert read("switch to habits") == {"kind": "set_mode", "mode": "habits"}
    assert read("just calories") == {"kind": "set_mode", "mode": "calories"}
    assert read("I want to track macros") == {"kind": "set_mode", "mode": "macros"}
    assert read("follow a meal plan") == {"kind": "set_mode", "mode": "meal_plan"}
    assert read("also show fiber") == {"kind": "set_focus", "focus_add": ["fiber"]}
    assert read("take sugar off") == {"kind": "set_focus", "focus_remove": ["sugar"]}
    assert read("also show calories") == {"kind": "show", "show": "calories"}  # the card, never a tile
    assert read("stop reminding me") == {"kind": "set_level", "level": "off"}
    assert read("no more water tips") == {"kind": "mute", "subject": "water"}
    assert read("turn the water ones on") == {"kind": "unmute", "subject": "water"}
    assert read("when I sit back down I'll log") == {"kind": "set_anchor", "anchor": "when_seated"}
    assert read("portions are hard") == {"kind": "set_frictions", "frictions_add": ["portions"]}
    assert read("how far am I on water") == {"kind": "show", "show": "water"}
    assert read("what are my targets") == {"kind": "show", "show": "protocol"}
    assert read("what's the weather") == {"kind": "other"}
    assert read("lunch was big") == {"kind": "other"}  # the rules never guess a meal from a noun alone
    assert read("I ate a thing") == {"kind": "meal"}


def test_an_unreadable_form_is_other_never_a_guess():
    assert parse_intent({"kind": "set_mode", "mode": "keto"}).kind == "other"
    assert parse_intent({"kind": "fly"}).kind == "other"
    assert parse_intent({"kind": "set_level", "level": "off"}).level is lines.NudgeLevel.OFF


def test_the_model_path_builds_alternating_turns_ending_on_the_person():
    thread = [
        AssistTurn(role="app", text="dropped: a leading app turn"),
        AssistTurn(role="person", text="stop all reminders"),
        AssistTurn(role="app", text="Vo-Cal will say nothing."),
        AssistTurn(role="app", text="joined with the one before"),
    ]
    messages = build_messages("actually, coach me", thread)
    assert [m["role"] for m in messages] == ["user", "assistant", "user"]
    assert messages[1]["content"] == "Vo-Cal will say nothing.\njoined with the one before"
    assert messages[-1]["content"] == "actually, coach me"
    # Two person turns in a row join into the one user turn, so the API never sees a repeat.
    joined = build_messages("and water", [AssistTurn(role="person", text="protein")])
    assert joined == [{"role": "user", "content": "protein\nand water"}]
    client = AnthropicAssistClient(client=object(), model="claude-haiku-4-5")
    assert client.name == "model"
    assert client.model == "claude-haiku-4-5"


async def test_the_model_reader_returns_the_forced_tools_input():
    # The SDK stands in: the reader asks for the one tool, forced, with the system prompt cached
    # and a form-sized output; the tool's input is the form. No network, no key.
    captured: dict = {}

    class Block:
        type = "tool_use"
        name = "answer_request"
        input: ClassVar[dict[str, Any]] = {"kind": "set_mode", "mode": "habits"}

    class Response:
        content: ClassVar[list[Block]] = [Block()]

    class Messages:
        async def create(self, **kwargs):
            captured.update(kwargs)
            return Response()

    class SDK:
        messages = Messages()

    reader = AnthropicAssistClient(client=SDK(), model="claude-haiku-4-5")
    raw = await reader.extract("switch to habits", [AssistTurn(role="person", text="hi"), AssistTurn(role="app", text="It's on Today.")])
    assert raw == {"kind": "set_mode", "mode": "habits"}
    assert parse_intent(raw).mode is lines.TrackingMode.HABITS
    assert captured["model"] == "claude-haiku-4-5"
    assert captured["max_tokens"] == 300
    assert captured["tool_choice"] == {"type": "tool", "name": "answer_request"}
    assert captured["tools"][0]["name"] == "answer_request"
    assert captured["system"][0]["cache_control"] == {"type": "ephemeral"}
    assert [m["role"] for m in captured["messages"]] == ["user", "assistant", "user"]
    assert captured["messages"][-1]["content"] == "switch to habits"


async def test_a_response_without_the_tool_is_the_readers_failure():
    class Response:
        content: ClassVar[list[Any]] = []

    class Messages:
        async def create(self, **kwargs):
            return Response()

    class SDK:
        messages = Messages()

    reader = AnthropicAssistClient(client=SDK())
    with pytest.raises(AssistError):
        await reader.extract("switch to habits", [])
