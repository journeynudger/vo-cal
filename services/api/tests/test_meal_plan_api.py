"""P8: the meal plan (decision 65). Offline (FakeDatabase).

Proves: the engine's one line about a plan against the protocol (within 10 percent of the
calories, protein at the band's floor), in its four states; a logged meal ticks one slot by
name and the rest are "also today"; PUT appends versions from a usual or from typed items
(re-priced server-side); Today leads with the plan card in meal-plan mode and says "No plan
yet" before one exists; the plan nudge speaks only to an open slot in the evening; the record
export and the account deletion cover the table.
"""

from __future__ import annotations

from datetime import UTC, datetime
from uuid import uuid4
from zoneinfo import ZoneInfo

from api.meals.plan import PlanSlot, check_plan, match_slots, plan_panel
from api.meals.schemas import ConfirmedItem
from api.meals.today import Targets
from api.nudges.engine import NudgeSignals, plan
from api.nutrition.dictionary import get_dictionary
from api.nutrition.schemas import Macros
from api.tracking.schemas import TrackingMode

from .conftest import TEST_USER_ID

DICT = get_dictionary()
TZ = ZoneInfo("America/New_York")


def _item(name: str, kcal: float, protein: float) -> ConfirmedItem:
    return ConfirmedItem(
        name=name,
        grams=100,
        macros=Macros(kcal=kcal, protein=protein, carbs=0, fat=0, fiber=0),
        confidence=0.9,
    )


def _slot(index: int, name: str, kcal: float, protein: float) -> PlanSlot:
    item = _item(name, kcal, protein)
    return PlanSlot(index=index, name=name, items=[item], totals=item.macros)


def _row(name: str | None, hour: int) -> dict:
    return {
        "id": str(uuid4()),
        "name": name,
        "items": [{"name": "chicken breast", "grams": 100}],
        "totals": {"kcal": 165, "protein": 31, "carbs": 0, "fat": 3.6, "fiber": 0},
        "logged_at": datetime(2026, 10, 4, hour, 0, tzinfo=UTC),
    }


def _chicken_item(grams: float) -> dict:
    """A confirmed chicken-breast item of ``grams`` grams. The amount travels as the stated
    quantity (RT-02: the server recomputes grams from it; a bare ``grams`` is advisory)."""
    entry = DICT.lookup("chicken breast").entry
    return {
        "name": "chicken breast",
        "amount": grams,
        "unit": "g",
        "state": "unspecified",
        "fat_ratio": None,
        "brand": None,
        "prep_method": None,
        "grams": grams,
        "macros": entry.profile.for_grams(grams).model_dump(),
        "confidence": 0.9,
        "source": "dictionary",
    }


def _seed_protocol(fake_db, kcal: float = 1805, protein: float = 147, band=(131, 163)) -> None:
    fake_db.tables.setdefault("protocols", []).append(
        {
            "id": str(uuid4()),
            "user_id": str(TEST_USER_ID),
            "version": 1,
            "supersedes": None,
            "active": True,
            "targets": {
                "kcal": kcal,
                "protein": protein,
                "protein_min": band[0],
                "protein_max": band[1],
                "carbs": 167,
                "fat": 54,
                "fiber": 32,
                "water_oz": 100,
                "produce_servings": 6,
                "meals_per_day": 3,
            },
            "whys": {},
        }
    )


def _log_meal(client, headers, name: str, grams: float = 200, save_as_usual: bool = False):
    return client.post(
        "/meals",
        json={
            "client_meal_id": str(uuid4()),
            "name": name,
            "items": [_chicken_item(grams)],
            "logged_at": datetime.now(UTC).isoformat(),
            "save_as_usual": save_as_usual,
        },
        headers=headers,
    )


# -- the check, pure ---------------------------------------------------------------


def test_check_on_protocol_says_so_in_one_line():
    slots = [_slot(1, "Oats", 500, 30), _slot(2, "Chicken bowl", 700, 60), _slot(3, "Salmon", 590, 50)]
    check = check_plan(slots, Targets(kcal=1805, protein=147), (131, 163))
    assert check.kcal_within
    assert check.protein_ok
    assert check.line == "On your protocol: 1,790 of 1,805 calories, protein covered."


def test_check_under_and_protein_short():
    slots = [_slot(1, "Oats", 500, 30), _slot(2, "Chicken bowl", 700, 70)]
    check = check_plan(slots, Targets(kcal=1805, protein=147), (131, 163))
    assert not check.kcal_within
    assert not check.protein_ok
    assert check.line == "605 calories under your protocol; protein 31 g under the band."


def test_check_over_the_protocol():
    slots = [_slot(1, "Oats", 700, 60), _slot(2, "Chicken bowl", 700, 60), _slot(3, "Salmon", 700, 60)]
    check = check_plan(slots, Targets(kcal=1805, protein=147), (131, 163))
    assert check.line == "295 calories over your protocol."


def test_check_without_a_band_uses_the_protein_target_as_the_floor():
    slots = [_slot(1, "Oats", 900, 70), _slot(2, "Salmon", 900, 70)]
    check = check_plan(slots, Targets(kcal=1805, protein=150), (0, 0))
    assert check.kcal_within
    assert check.protein_floor == 150
    assert check.line == "Protein 10 g under the band."


# -- the matching, pure ------------------------------------------------------------


def test_each_meal_ticks_at_most_one_slot_by_name_and_the_rest_are_extras():
    slots = [_slot(1, "Oats", 400, 20), _slot(2, "Chicken bowl", 700, 60), _slot(3, "Oats", 400, 20)]
    rows = [_row("oats", 8), _row("Ice cream", 15), _row("Oats", 20), _row("OATS", 21)]
    statuses, extras = match_slots(slots, rows)
    assert [s.logged for s in statuses] == [True, False, True]
    assert statuses[0].meal_id == rows[0]["id"]
    assert statuses[2].meal_id == rows[2]["id"]
    assert extras == ["Ice cream", "OATS"]


def test_plan_panel_counts_and_says_no_plan_yet():
    slots = [_slot(1, "Oats", 400, 20), _slot(2, "Chicken bowl", 700, 60)]
    panel = plan_panel(
        type("Plan", (), {"slots": slots})(),  # anything with .slots
        [_row("Oats", 8)],
    )
    assert panel.kind == "meal_plan_slots"
    assert (panel.consumed, panel.target, panel.remaining) == (1, 2, 1)
    assert panel.support == "1 of 2 meals"
    assert not panel.complete
    empty = plan_panel(None, [_row("Toast", 8)])
    assert empty.support == "No plan yet"
    assert empty.slots == []
    assert empty.extras == ["Toast"]


# -- the endpoints -----------------------------------------------------------------


def test_plan_requires_auth(client):
    assert client.get("/meals/plan").status_code == 401
    assert client.put("/meals/plan", json={"slots": []}).status_code == 401


def test_no_plan_is_404(client, auth_headers):
    assert client.get("/meals/plan", headers=auth_headers).status_code == 404


def test_put_plan_from_a_usual_and_a_typed_meal(client, auth_headers, fake_db):
    _seed_protocol(fake_db)
    assert _log_meal(client, auth_headers, "Chicken bowl", save_as_usual=True).status_code == 201
    usual = client.get("/meals/usuals", headers=auth_headers).json()[0]
    resp = client.put(
        "/meals/plan",
        json={
            "slots": [
                {"usual_id": usual["id"]},
                {"name": "Eggs on toast", "items": [_chicken_item(150)]},
            ]
        },
        headers=auth_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["version"] == 1
    assert body["author"] == "person"
    assert [s["name"] for s in body["slots"]] == ["Chicken bowl", "Eggs on toast"]
    assert body["slots"][0]["usual_id"] == usual["id"]
    # The typed slot's numbers are the server's re-pricing of 150 g of chicken breast, not the
    # client's (RT-02); the usual's are its stored totals.
    expected = DICT.lookup("chicken breast").entry.profile.for_grams(150)
    assert body["slots"][1]["totals"]["kcal"] == expected.kcal
    assert body["check"] is not None
    assert body["check"]["target_kcal"] == 1805
    assert "calories" in body["check"]["line"]
    # A second PUT appends; GET returns the latest.
    again = client.put("/meals/plan", json={"slots": [{"usual_id": usual["id"]}]}, headers=auth_headers).json()
    assert again["version"] == 2
    assert client.get("/meals/plan", headers=auth_headers).json()["version"] == 2
    assert len(fake_db.tables["meal_plans"]) == 2


def test_put_plan_rejects_an_empty_slot_and_a_foreign_usual(client, auth_headers, auth_headers_user_2):
    assert client.put("/meals/plan", json={"slots": [{"name": "Nothing"}]}, headers=auth_headers).status_code == 422
    assert _log_meal(client, auth_headers_user_2, "Theirs", save_as_usual=True).status_code == 201
    theirs = client.get("/meals/usuals", headers=auth_headers_user_2).json()[0]
    assert client.put("/meals/plan", json={"slots": [{"usual_id": theirs["id"]}]}, headers=auth_headers).status_code == 404


def test_plan_without_a_protocol_has_no_check(client, auth_headers):
    body = client.put(
        "/meals/plan", json={"slots": [{"name": "Eggs", "items": [_chicken_item(100)]}]}, headers=auth_headers
    ).json()
    assert body["check"] is None


def test_today_leads_with_the_plan_card_in_meal_plan_mode(client, auth_headers, fake_db):
    _seed_protocol(fake_db)
    client.put("/tracking", json={"mode": "meal_plan"}, headers=auth_headers)
    client.put(
        "/meals/plan",
        json={
            "slots": [
                {"name": "Chicken bowl", "items": [_chicken_item(200)]},
                {"name": "Salmon plate", "items": [_chicken_item(200)]},
            ]
        },
        headers=auth_headers,
    )
    date_str = datetime.now(UTC).strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()
    assert body["mode"] == "meal_plan"
    assert [p["kind"] for p in body["panels"]] == ["meal_plan_slots", "calories_left"]
    card = body["panels"][0]
    assert card["support"] == "0 of 2 meals"
    assert [s["logged"] for s in card["slots"]] == [False, False]

    assert _log_meal(client, auth_headers, "Chicken bowl").status_code == 201
    assert _log_meal(client, auth_headers, "Ice cream").status_code == 201
    card = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()["panels"][0]
    assert card["support"] == "1 of 2 meals"
    assert [s["logged"] for s in card["slots"]] == [True, False]
    assert card["slots"][0]["meal_id"] is not None
    assert card["extras"] == ["Ice cream"]
    assert card["complete"] is False


def test_today_says_no_plan_yet_before_one_exists(client, auth_headers, fake_db):
    _seed_protocol(fake_db)
    client.put("/tracking", json={"mode": "meal_plan"}, headers=auth_headers)
    date_str = datetime.now(UTC).strftime("%Y-%m-%d")
    card = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()["panels"][0]
    assert card["kind"] == "meal_plan_slots"
    assert card["support"] == "No plan yet"
    assert card["slots"] == []


def test_other_modes_never_carry_the_plan_card(client, auth_headers, fake_db):
    _seed_protocol(fake_db)
    client.put("/meals/plan", json={"slots": [{"name": "Eggs", "items": [_chicken_item(100)]}]}, headers=auth_headers)
    date_str = datetime.now(UTC).strftime("%Y-%m-%d")
    for mode in ("five", "habits", "calories", "macros"):
        client.put("/tracking", json={"mode": mode}, headers=auth_headers)
        kinds = [p["kind"] for p in client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()["panels"]]
        assert "meal_plan_slots" not in kinds, mode


# -- the nudge -------------------------------------------------------------------


def _signals(**overrides) -> NudgeSignals:
    base = {
        # Late enough in the day's calories that the two calorie voices (treat headroom, under
        # target) stay quiet, so the one immediate card can be the plan's.
        "kcal_consumed": 1600.0,
        "kcal_target": 1805.0,
        "protein_consumed": 120.0,
        "protein_target": 163.0,
        "water_oz": 90.0,
        "water_target": 100.0,
        "fiber_consumed": 30.0,
        "fiber_target": 32.0,
        "meals_today": 2,
        "days_logged_this_week": 3,
        "days_since_last_log": 0,
        "plan_slots": 3,
        "plan_logged": 2,
    }
    base.update(overrides)
    return NudgeSignals(**base)


def test_plan_slot_open_speaks_in_the_evening_in_meal_plan_mode_only():
    evening = datetime(2026, 7, 15, 19, 40, tzinfo=TZ)
    ids = [c.id for c in plan(_signals(), {}, evening, mode=TrackingMode.MEAL_PLAN).immediate]
    assert "plan_slot_open" in ids
    assert "plan_slot_open" not in [c.id for c in plan(_signals(), {}, evening, mode=TrackingMode.FIVE).immediate]
    # The plan done, or the day not yet begun, or the afternoon: silent.
    assert "plan_slot_open" not in [
        c.id for c in plan(_signals(plan_logged=3), {}, evening, mode=TrackingMode.MEAL_PLAN).immediate
    ]
    assert "plan_slot_open" not in [
        c.id for c in plan(_signals(meals_today=0), {}, evening, mode=TrackingMode.MEAL_PLAN).immediate
    ]
    afternoon = datetime(2026, 7, 15, 15, 0, tzinfo=TZ)
    assert "plan_slot_open" not in [
        c.id for c in plan(_signals(), {}, afternoon, mode=TrackingMode.MEAL_PLAN).immediate
    ]


def test_plan_endpoint_reads_the_plan_for_its_signals(client, auth_headers, fake_db):
    # Not an assertion on the clock (the endpoint runs at the test's hour); only that the
    # endpoint answers in meal-plan mode with a plan in place, at any hour.
    _seed_protocol(fake_db)
    client.put("/tracking", json={"mode": "meal_plan"}, headers=auth_headers)
    client.put("/meals/plan", json={"slots": [{"name": "Eggs", "items": [_chicken_item(100)]}]}, headers=auth_headers)
    resp = client.post("/nudges/plan", json={"recently_shown": {}, "level": "standard"}, headers=auth_headers)
    assert resp.status_code == 200, resp.text


# -- the record -----------------------------------------------------------------


def test_export_and_deletion_cover_meal_plans(client, auth_headers, fake_db, fake_storage):
    client.put("/meals/plan", json={"slots": [{"name": "Eggs", "items": [_chicken_item(100)]}]}, headers=auth_headers)
    export = client.get("/account/export", headers=auth_headers).json()
    assert len(export["meal_plans"]) == 1
    assert export["meal_plans"][0]["slots"][0]["name"] == "Eggs"
    assert "user_id" not in export["meal_plans"][0]
    assert client.delete("/account", headers=auth_headers).status_code == 204
    assert [r for r in fake_db.tables.get("meal_plans", []) if r["user_id"] == str(TEST_USER_ID)] == []
