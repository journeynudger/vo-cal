"""Smart nudges — deterministic plan engine + the wire contract build 16 already ships.

The product promises under test (Settings copy + NudgeCenter's decode):
  1. NEVER more than two nudges a day — the ledger the client sends is honored.
  2. Cooldowns silence repeats; a corrupt ledger entry never blocks.
  3. Quiet hours: no scheduled fire before 09:00 or at/after 21:00 local.
  4. Deterministic: same signals + ledger + clock -> same plan.
  5. Wire shape matches the SHIPPED Swift decode exactly (snake_case keys:
     pro_tip, cooldown_days, fire_at, recently_shown) — the client is live and
     silently ignores failures, so contract drift would be invisible breakage.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

from api.nudges.engine import DAILY_BUDGET, NudgeSignals, plan

TZ = ZoneInfo("America/New_York")


def _signals(**overrides) -> NudgeSignals:
    base = {
        "kcal_consumed": 1200.0,
        "kcal_target": 1805.0,
        "protein_consumed": 90.0,
        "protein_target": 163.0,
        "water_oz": 60.0,
        "water_target": 100.0,
        "fiber_consumed": 20.0,
        "fiber_target": 32.0,
        "meals_today": 2,
        "days_logged_this_week": 3,
        "days_since_last_log": 0,
    }
    base.update(overrides)
    return NudgeSignals(**base)


def _at(hour: int, minute: int = 0) -> datetime:
    return datetime(2026, 7, 15, hour, minute, tzinfo=TZ)  # a Wednesday


# -- the engine's promises ---------------------------------------------------------


def test_treat_headroom_fires_in_the_evening():
    p = plan(_signals(kcal_consumed=1100.0), {}, _at(19, 15))
    assert any(c.id == "treat_headroom" for c in p.immediate)


def test_daily_budget_never_exceeded():
    # Ledger says two nudges already shown today -> the plan MUST be empty.
    today = _at(12).date().isoformat()
    p = plan(_signals(meals_today=0), {"a": today, "b": today}, _at(12))
    assert p.immediate == []
    assert p.scheduled == []


def test_plan_never_returns_more_than_budget():
    # Starving signals that trigger several nudges still cap at two touches.
    p = plan(
        _signals(meals_today=2, water_oz=10.0, protein_consumed=10.0, fiber_consumed=2.0),
        {},
        _at(13),
    )
    assert len(p.immediate) + len(p.scheduled) <= DAILY_BUDGET


def test_cooldown_silences_a_repeat():
    yesterday = (_at(12) - timedelta(days=1)).date().isoformat()
    with_cd = plan(_signals(kcal_consumed=1100.0), {"treat_headroom": yesterday}, _at(19))
    assert not any(c.id == "treat_headroom" for c in with_cd.immediate)


def test_corrupt_ledger_entry_never_blocks():
    p = plan(_signals(kcal_consumed=1100.0), {"treat_headroom": "not-a-date"}, _at(19))
    assert any(c.id == "treat_headroom" for c in p.immediate)


def test_scheduled_fires_respect_quiet_hours():
    # Whatever the plan schedules must land inside 09:00-21:00 local.
    p = plan(_signals(meals_today=0, water_oz=0.0), {}, _at(9, 30))
    for entry in p.scheduled:
        assert 9 <= entry.fire_at.hour < 21
        assert entry.fire_at > _at(9, 30)


def test_early_morning_no_log_is_scheduled_not_immediate():
    # Poking someone at 8am for "no breakfast logged" is noise; it parks at 11:30.
    p = plan(_signals(meals_today=0), {}, _at(8, 0))
    assert not any(c.id == "no_log_today" for c in p.immediate)
    assert any(s.card.id == "no_log_today" and s.fire_at.hour == 11 for s in p.scheduled)


def test_gone_quiet_wins_immediately_on_reopen():
    p = plan(_signals(meals_today=0, days_since_last_log=3), {}, _at(14))
    assert p.immediate
    assert p.immediate[0].id == "gone_quiet"


def test_quiet_day_parks_tomorrow_morning_touch():
    # Nothing to say today (all triggers muted by cooldown) but no log either ->
    # one gentle touch parks for tomorrow 09:30, inside quiet hours.
    today = _at(22, 0)  # past quiet-hours end; no same-day slot possible
    ledger = {"gone_quiet": today.date().isoformat()}
    p = plan(_signals(meals_today=0, days_since_last_log=2), ledger, today)
    assert p.immediate == []  # budget spent per ledger? no — gone_quiet on cooldown
    assert len(p.scheduled) == 1
    entry = p.scheduled[0]
    assert entry.card.id == "no_log_today"
    assert entry.fire_at.date() == (today + timedelta(days=1)).date()
    assert (entry.fire_at.hour, entry.fire_at.minute) == (9, 30)


def test_deterministic_same_inputs_same_plan():
    a = plan(_signals(), {}, _at(19))
    b = plan(_signals(), {}, _at(19))
    assert a == b


def test_priority_orders_the_immediate_card():
    # gone_quiet (80) outranks treat_headroom (60) when both trigger.
    p = plan(_signals(meals_today=1, days_since_last_log=2, kcal_consumed=1000.0), {}, _at(19))
    assert p.immediate[0].id == "gone_quiet"


# -- the wire contract build 16 decodes --------------------------------------------


def _seed_meal(db, user_id, hours_ago: float, kcal: float = 400.0) -> None:
    from datetime import UTC

    logged = datetime.now(UTC) - timedelta(hours=hours_ago)
    db.tables.setdefault("meal_logs", []).append(
        {
            "id": str(uuid4()),
            "user_id": str(user_id),
            "client_meal_id": f"n-{uuid4()}",
            "name": None,
            "meal_type": "lunch",
            "items": [],
            "totals": {"kcal": kcal, "protein": 30.0, "carbs": 40.0, "fat": 10.0, "fiber": 5.0},
            "confidence": 0.9,
            "logged_at": logged.isoformat(),
        }
    )


def test_plan_endpoint_matches_shipped_swift_contract(client, auth_headers, fake_db):
    from .conftest import TEST_USER_ID

    _seed_meal(fake_db, TEST_USER_ID, hours_ago=2)
    resp = client.post(
        "/nudges/plan", json={"recently_shown": {}}, headers=auth_headers
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    # Exact keys NudgeModels.swift decodes (snake_case via VoCalJSON).
    assert set(body.keys()) == {"immediate", "scheduled"}
    for card in body["immediate"] + [s["card"] for s in body["scheduled"]]:
        assert set(card.keys()) == {
            "id", "category", "message", "pro_tip", "priority", "cooldown_days",
        }
    for entry in body["scheduled"]:
        assert set(entry.keys()) == {"fire_at", "card"}
        datetime.fromisoformat(entry["fire_at"])  # ISO-8601, tz-aware


def test_plan_endpoint_requires_auth(client):
    assert client.post("/nudges/plan", json={"recently_shown": {}}).status_code == 401


def test_plan_endpoint_empty_ledger_default(client, auth_headers):
    # The client always sends a ledger, but an empty body must not 422 (defaults).
    resp = client.post("/nudges/plan", json={}, headers=auth_headers)
    assert resp.status_code == 200
