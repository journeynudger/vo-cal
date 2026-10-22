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
INTAKE = {
    "age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0,
    "goal": "cut", "work": "desk", "train": "moderate", "kids": False,
    "med": "none", "stress": "moderate",
}


def _protocol(client, auth_headers) -> None:
    client.post("/intake", json={"intake": INTAKE}, headers=auth_headers)
    assert client.post("/protocols/generate", json={"intake": INTAKE}, headers=auth_headers).status_code == 201


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
    _protocol(client, auth_headers)
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


@pytest.mark.parametrize(
    ("sentence", "form"),
    [
        # A question about a change asks; it does not choose.
        ("should I switch to habits?", {"kind": "other"}),
        ("what if I switch to calories", {"kind": "other"}),
        ("how do I track macros", {"kind": "other"}),
        ("can you switch me to habits", {"kind": "set_mode", "mode": "habits"}),
        # A change refused is no change.
        ("I don't want to switch to habits", {"kind": "other"}),
        ("don't stop the reminders", {"kind": "other"}),
        ("don't turn off the water reminders", {"kind": "other"}),
        ("I'm not going to log before bed", {"kind": "other"}),
        ("don't coach me", {"kind": "other"}),
        ("please don't remind me", {"kind": "set_level", "level": "off"}),
        ("I don't want reminders", {"kind": "set_level", "level": "off"}),
        # A change bounded in time is one the app cannot make as said.
        ("stop the protein reminders on weekends", {"kind": "other"}),
        ("turn off the protein reminders on weekends", {"kind": "other"}),
        ("stop reminders for today", {"kind": "other"}),
        ("mute the water ones until monday", {"kind": "other"}),
        ("no reminders at night", {"kind": "other"}),
        ("no reminders before bed", {"kind": "other"}),
        # Fewer is the essential level; a subject named in "notifications" is that subject.
        ("fewer reminders please", {"kind": "set_level", "level": "essential"}),
        ("stop the protein notifications", {"kind": "mute", "subject": "protein"}),
        ("mute the water alerts", {"kind": "mute", "subject": "water"}),
        ("stop all notifications", {"kind": "set_level", "level": "off"}),
        ("turn the water reminders back on", {"kind": "unmute", "subject": "water"}),
        ("they were quiet, bring them back on", {"kind": "other"}),
        ("remind me when I wake up", {"kind": "other"}),
        # A friction is a struggle the person names, never a word in passing.
        ("forget it", {"kind": "other"}),
        ("what portion of my calories is protein", {"kind": "other"}),
        ("I keep forgetting to log", {"kind": "set_frictions", "frictions_add": ["forgetting"]}),
        ("I don't forget anymore", {"kind": "set_frictions", "frictions_remove": ["forgetting"]}),
        ("it doesn't take too long anymore", {"kind": "set_frictions", "frictions_remove": ["time"]}),
        ("I eat out a lot", {"kind": "set_frictions", "frictions_add": ["eating_out"]}),
        ("I had a big portion", {"kind": "meal"}),
        ("I ate out at a restaurant", {"kind": "meal"}),
        # A mode is chosen, never a word beside a meal; losing fat is not a tile.
        ("I just ate 500 calories", {"kind": "meal"}),
        ("I want to cut calories", {"kind": "other"}),
        ("I only want calories", {"kind": "set_mode", "mode": "calories"}),
        ("I'd like the five", {"kind": "set_mode", "mode": "five"}),
        ("my coach said to eat more protein", {"kind": "other"}),
        ("I want to drop some fat", {"kind": "other"}),
        ("drop the sugar tile", {"kind": "set_focus", "focus_remove": ["sugar"]}),
        ("add 16 oz of water", {"kind": "other"}),
    ],
)
def test_the_rules_never_read_a_question_a_refusal_or_a_bound_as_a_change(sentence, form):
    # The 2026-10-22 audit: each of these changed a setting the person had not chosen.
    assert read(sentence) == form


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


async def test_a_read_past_its_budget_is_the_readers_failure(monkeypatch):
    # The phone gives the bar 15 s: a form that lands after it applies a change the person was
    # told failed. The read is cut at its budget and answered as the honest failure.
    import asyncio

    from api.assist import llm

    monkeypatch.setattr(llm, "READ_BUDGET_S", 0.05)

    class Messages:
        async def create(self, **kwargs):
            await asyncio.sleep(1)

    class SDK:
        messages = Messages()

    with pytest.raises(AssistError, match="budget"):
        await AnthropicAssistClient(client=SDK()).extract("switch to habits", [])


def test_the_built_client_bounds_each_attempt_and_retries_once(monkeypatch):
    from api.assist import llm

    monkeypatch.setattr(llm.settings, "anthropic_api_key", "sk-test-not-a-key")
    client = AnthropicAssistClient()._ensure_client()
    assert client.timeout == llm.ATTEMPT_TIMEOUT_S
    assert client.max_retries == 1
    assert llm.ATTEMPT_TIMEOUT_S < llm.READ_BUDGET_S < 15


# -- the 2026-10-22 audit: the bar changes only what changes, and says only what is true --------


def _reaction_rows(fake_db) -> list[tuple[str, str]]:
    return [(r["nudge_id"], r["kind"]) for r in fake_db.tables.get("nudge_reactions", [])]


def test_waking_reminders_that_are_on_changes_nothing_and_offers_no_undo(client, auth_headers, fake_db):
    # Nothing muted; "turn the water reminders back on" answered "changed" with an Undo that,
    # tapped, muted reminders the person had never muted.
    reply = _ask(client, auth_headers, "turn the water reminders back on")
    assert reply["kind"] == "told"
    assert reply["undo"] is None
    assert _reaction_rows(fake_db) == []


def test_undo_of_a_mute_restores_exactly_what_was_there(client, auth_headers, fake_db):
    # One calorie nudge was muted from the lock screen before; "stop the calorie reminders"
    # mutes the rest, and its Undo wakes only those, never the earlier mute.
    from api.nudges.catalog import CATALOG

    calorie_ids = [n.id for n in CATALOG if n.category == "calories"]
    assert len(calorie_ids) >= 2
    first = calorie_ids[0]
    client.post("/nudges/reactions", json={"nudge_id": first, "kind": "not_for_me"}, headers=auth_headers)

    reply = _ask(client, auth_headers, "stop the calorie reminders")
    assert reply["kind"] == "changed"
    undo_ids = sorted(r["nudge_id"] for r in reply["undo"]["reactions"])
    assert undo_ids == sorted(calorie_ids[1:])
    for request in reply["undo"]["reactions"]:
        client.post("/nudges/reactions", json=request, headers=auth_headers)
    muted = client.post("/nudges/plan", json={"recently_shown": {}}, headers=auth_headers).json()["muted"]
    assert [m["id"] for m in muted] == [first]

    again = _ask(client, auth_headers, "stop the calorie reminders")
    reply_again = _ask(client, auth_headers, "stop the calorie reminders")
    assert again["kind"] == "changed"
    assert reply_again["kind"] == "told"
    assert reply_again["undo"] is None


def test_a_number_asked_before_any_protocol_points_to_the_details(client, auth_headers):
    # Before a protocol the targets are placeholders; Today says so ("starter targets"), the
    # bar drew "Your protein today." against 120 g that was nobody's.
    reply = _ask(client, auth_headers, "how much protein is left")
    assert reply["kind"] == "pointed"
    assert reply["panel"] is None
    assert reply["pointer"]["surface"] == "profile"


def test_with_reminders_off_no_line_promises_one(client, auth_headers):
    _ask(client, auth_headers, "stop all reminders")
    forget = _ask(client, auth_headers, "I keep forgetting to log")
    assert "reminder in the evening" not in forget["line"].lower()
    assert "off" in forget["line"].lower()
    anchor = _ask(client, auth_headers, "I'll log right after I eat")
    assert "11:30" not in anchor["line"]
    assert "off" in anchor["line"].lower()


def test_a_tile_the_mode_already_prints_is_neither_added_nor_taken_off(client, auth_headers):
    on = _ask(client, auth_headers, "also show protein")
    assert on["kind"] == "told"
    assert on["undo"] is None
    off = _ask(client, auth_headers, "take protein off today")
    assert off["kind"] == "told"
    assert "isn't on Today" not in off["line"]
    assert client.get("/tracking", headers=auth_headers).json()["version"] == 0


def test_undo_puts_back_a_dont_offer_again(client, auth_headers):
    client.put("/tracking", json={"mode": "calories"}, headers=auth_headers)
    client.put("/tracking", json={"decline_offer": "focus:protein"}, headers=auth_headers)
    reply = _ask(client, auth_headers, "also show protein")
    assert reply["kind"] == "changed"
    assert client.get("/tracking", headers=auth_headers).json()["declined_offers"] == []
    client.put("/tracking", json=reply["undo"]["tracking"], headers=auth_headers)
    after = client.get("/tracking", headers=auth_headers).json()
    assert after["focus_metrics"] == []
    assert after["declined_offers"] == ["focus:protein"]


async def test_a_repeated_value_in_the_form_is_stored_once(fake_db):
    from api.assist.apply import answer
    from api.assist.schemas import Intent
    from api.tracking.store import TrackingStore

    from .conftest import TEST_USER_ID

    zone = __import__("zoneinfo").ZoneInfo("UTC")
    day = datetime.now(UTC).date()
    reply = await answer(fake_db, TEST_USER_ID, Intent(kind="set_focus", focus_add=["sugar", "sugar"]), day=day, tz_zone=zone)
    assert reply.change.value == "Sugar"
    assert [m.value for m in (await TrackingStore(fake_db).latest(TEST_USER_ID)).focus_metrics] == ["sugar"]


def test_meal_plan_mode_can_add_a_tile_and_the_bar_tells_the_truth(client, auth_headers):
    # The plan card and calories are what meal-plan mode draws; water, protein, produce and
    # fiber were listed as its own tiles, so "Also show" never offered them and the bar said
    # "Water is on Today now." while no water tile appeared.
    client.put("/tracking", json={"mode": "meal_plan"}, headers=auth_headers)
    assert "water" in client.get("/tracking", headers=auth_headers).json()["offerable_focus"]
    reply = _ask(client, auth_headers, "also show water")
    assert reply["kind"] == "changed"
    today = client.get(f"/meals/today?date={DAY['date']}&tz={DAY['tz']}", headers=auth_headers).json()
    assert "water" in [p.get("metric") for p in today["panels"]]


def test_a_tile_chosen_under_calories_does_not_follow_the_person_into_habits(client, auth_headers):
    # Decision 72: protein grams carried into habits printed on the page the person had just
    # asked to show no numbers. Undo of the switch carries the tile back.
    _protocol(client, auth_headers)
    client.put("/tracking", json={"mode": "calories", "focus_metrics": ["protein"]}, headers=auth_headers)
    reply = _ask(client, auth_headers, "switch to habits")
    assert client.get("/tracking", headers=auth_headers).json()["focus_metrics"] == []
    today = client.get(f"/meals/today?date={DAY['date']}&tz={DAY['tz']}", headers=auth_headers).json()
    assert "protein" not in [p.get("metric") for p in today["panels"]]
    client.put("/tracking", json=reply["undo"]["tracking"], headers=auth_headers)
    back = client.get("/tracking", headers=auth_headers).json()
    assert (back["mode"], back["focus_metrics"]) == ("calories", ["protein"])


def test_in_habits_the_bar_answers_with_what_the_page_draws(client, auth_headers):
    # Spec 6.4: a tile added in habits is the one number the page prints; water is a habit tile.
    _protocol(client, auth_headers)
    client.put("/tracking", json={"mode": "habits"}, headers=auth_headers)
    client.put("/tracking", json={"focus_metrics": ["sugar"]}, headers=auth_headers)
    assert client.get("/tracking", headers=auth_headers).json()["focus_metrics"] == ["sugar"]
    water = _ask(client, auth_headers, "how much water today")
    assert (water["kind"], water["panel"]["metric"]) == ("shown", "water")
    calories = _ask(client, auth_headers, "how many calories so far")
    assert (calories["kind"], calories["line"]) == ("told", lines.NO_NUMBERS)
