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

from api.nudges.catalog import CATALOG
from api.nudges.engine import (
    DAILY_BUDGET,
    ESSENTIAL_DAILY_BUDGET,
    ESSENTIAL_WEEKLY_BUDGET,
    NudgeSignals,
    plan,
)
from api.nudges.invitations import Invitation, InvitationSignals, suggest
from api.tracking.schemas import FocusMetric, TrackingMode, offer_key

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


# -- delivery levels (essential is the calm default for new clients) ---------------


def test_essential_filters_out_coaching_garnish():
    # Signals that trigger several coaching nudges (treat headroom, protein,
    # water, fiber) produce NOTHING at the essential level — none are essential.
    p = plan(
        _signals(meals_today=2, water_oz=10.0, protein_consumed=10.0, fiber_consumed=2.0),
        {},
        _at(13),
        level="essential",
    )
    assert p.immediate == []
    assert p.scheduled == []


def test_essential_still_delivers_gone_quiet():
    p = plan(_signals(meals_today=0, days_since_last_log=3), {}, _at(14), level="essential")
    assert p.immediate
    assert p.immediate[0].id == "gone_quiet"


def test_essential_daily_budget_is_one():
    assert ESSENTIAL_DAILY_BUDGET == 1
    today = _at(12).date().isoformat()
    p = plan(
        _signals(meals_today=0, days_since_last_log=3),
        {"anything": today},
        _at(14),
        level="essential",
    )
    assert p.immediate == []
    assert p.scheduled == []


def test_essential_weekly_cap_holds():
    # Three touches already this rolling week → silence, even for an essential
    # trigger that is otherwise ready to fire.
    now = _at(14)
    ledger = {
        f"n{i}": (now - timedelta(days=i + 1)).date().isoformat()
        for i in range(ESSENTIAL_WEEKLY_BUDGET)
    }
    p = plan(_signals(meals_today=0, days_since_last_log=3), ledger, now, level="essential")
    assert p.immediate == []
    assert p.scheduled == []


def test_essential_weekly_cap_ignores_old_entries():
    # Entries older than the rolling 7-day window don't count against the cap.
    now = _at(14)
    ledger = {
        f"n{i}": (now - timedelta(days=8 + i)).date().isoformat()
        for i in range(ESSENTIAL_WEEKLY_BUDGET)
    }
    p = plan(_signals(meals_today=0, days_since_last_log=3), ledger, now, level="essential")
    assert p.immediate
    assert p.immediate[0].id == "gone_quiet"


def test_off_returns_an_empty_plan():
    p = plan(_signals(meals_today=0, days_since_last_log=3), {}, _at(14), level="off")
    assert p == plan(_signals(), {}, _at(19), level="off")
    assert p.immediate == []
    assert p.scheduled == []


def test_standard_is_the_wire_default_for_shipped_clients(client, auth_headers):
    # A body without ``level`` (TestFlight ≤ build 22) must behave exactly as
    # before this field existed — accepted, standard semantics.
    resp = client.post("/nudges/plan", json={"recently_shown": {}}, headers=auth_headers)
    assert resp.status_code == 200


def test_unknown_level_is_rejected(client, auth_headers):
    resp = client.post(
        "/nudges/plan",
        json={"recently_shown": {}, "level": "loud"},
        headers=auth_headers,
    )
    assert resp.status_code == 422


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
    # The keys NudgeModels.swift decodes (snake_case via VoCalJSON) are always present; the
    # invitation keys added 2026-10-04 are additive and a build-31 client ignores them.
    assert set(body.keys()) == {"immediate", "scheduled"}
    for card in body["immediate"] + [s["card"] for s in body["scheduled"]]:
        assert {"id", "category", "message", "pro_tip", "priority", "cooldown_days"} <= set(card.keys())
        assert set(card.keys()) <= {
            "id", "category", "message", "pro_tip", "priority", "cooldown_days",
            "kind", "offer_mode", "offer_focus", "decline_key",
        }
    for entry in body["scheduled"]:
        assert set(entry.keys()) == {"fire_at", "card"}
        datetime.fromisoformat(entry["fire_at"])  # ISO-8601, tz-aware


def test_plan_endpoint_requires_auth(client):
    assert client.post("/nudges/plan", json={"recently_shown": {}}).status_code == 401


def _seed_protocol(db, user_id, kcal: float = 2000.0) -> None:
    from datetime import UTC

    db.tables.setdefault("protocols", []).append(
        {
            "id": str(uuid4()),
            "user_id": str(user_id),
            "version": 1,
            "supersedes": None,
            "active": True,
            "targets": {
                "kcal": kcal, "protein": 150, "carbs": 200, "fat": 60, "fiber": 30,
                "water_oz": 100, "produce_servings": 5, "meals_per_day": 3,
            },
            "whys": {},
            "created_at": datetime.now(UTC).isoformat(),
        }
    )


def test_no_protocol_means_no_target_nudges(client, auth_headers, fake_db):
    # Pre-onboarding: one meal logged, no protocol row. Before 2026-10-04 the plan was built on
    # STUB_TARGETS (2000 kcal), so "treat_headroom" told a person with no plan they had
    # comfortable room left. Habit nudges stay reachable; target nudges need a real target.
    from .conftest import TEST_USER_ID

    # hours_ago=0: a meal two hours back is yesterday when the suite runs just after UTC
    # midnight, and the nudge day is bucketed in the user's (UTC) local day.
    _seed_meal(fake_db, TEST_USER_ID, hours_ago=0, kcal=400.0)
    body = client.post("/nudges/plan", json={"recently_shown": {}}, headers=auth_headers).json()
    fired = [c["id"] for c in body["immediate"]] + [s["card"]["id"] for s in body["scheduled"]]
    assert "treat_headroom" not in fired
    assert "protein_gap" not in fired
    assert all(fid in {"gone_quiet", "no_log_today"} for fid in fired), fired


def test_protocol_targets_drive_target_nudges(client, auth_headers, fake_db):
    # The same day with a real protocol: the headroom nudge is legitimate and fires.
    from .conftest import TEST_USER_ID

    _seed_protocol(fake_db, TEST_USER_ID, kcal=2000.0)
    # 1,200 of 2,000: past the half the headroom nudge needs, with 800 left (decision 63 split
    # the evening between "well under target" below half and "room for a treat" above it).
    _seed_meal(fake_db, TEST_USER_ID, hours_ago=0, kcal=1200.0)
    body = client.post("/nudges/plan", json={"recently_shown": {}}, headers=auth_headers).json()
    assert [c["id"] for c in body["immediate"]] == ["treat_headroom"]


def test_plan_endpoint_empty_ledger_default(client, auth_headers):
    # The client always sends a ledger, but an empty body must not 422 (defaults).
    resp = client.post("/nudges/plan", json={}, headers=auth_headers)
    assert resp.status_code == 200


# -- the mode (decision 63) and the invitations (decision 62) -----------------------------


def test_habits_mode_never_hears_a_calorie_or_protein_nudge():
    p = plan(
        _signals(meals_today=2, kcal_consumed=1100.0, protein_consumed=10.0, fiber_consumed=2.0),
        {}, _at(19), mode=TrackingMode.HABITS,
    )
    ids = [c.id for c in p.immediate] + [e.card.id for e in p.scheduled]
    assert not {"treat_headroom", "protein_gap", "fiber_boost", "under_target", "evening_on_track"} & set(ids)


def test_no_nudge_copy_carries_a_number():
    # A nudge may never name a number the person's mode does not print; the copy carries none.
    for nudge in CATALOG:
        assert not any(ch.isdigit() for ch in nudge.message), nudge.id
        assert not any(ch.isdigit() for ch in nudge.pro_tip), nudge.id


def test_a_focus_metric_lets_its_nudge_speak_in_calories_mode():
    low_water = _signals(meals_today=2, water_oz=10.0)
    silent = plan(low_water, {}, _at(13), mode=TrackingMode.CALORIES)
    speaking = plan(low_water, {}, _at(13), mode=TrackingMode.CALORIES, focus=[FocusMetric.WATER])
    assert not any(c.id == "hydration_low" for c in silent.immediate + [e.card for e in silent.scheduled])
    assert any(c.id == "hydration_low" for c in speaking.immediate + [e.card for e in speaking.scheduled])


def test_streak_momentum_was_cut():
    assert "streak_momentum" not in {n.id for n in CATALOG}


def test_under_target_and_treat_headroom_never_share_an_evening():
    thin = plan(_signals(meals_today=1, kcal_consumed=600.0), {}, _at(20))
    assert [c.id for c in thin.immediate] == ["under_target"]
    room = plan(_signals(meals_today=1, kcal_consumed=1100.0), {}, _at(20))
    assert [c.id for c in room.immediate] == ["treat_headroom"]


def test_mid_week_slipping_fires_on_a_thin_wednesday():
    wednesday = datetime(2026, 7, 15, 13, 0, tzinfo=TZ)
    p = plan(_signals(meals_today=0, days_logged_this_week=1, days_since_last_log=1, weekday=2), {}, wednesday)
    assert p.immediate[0].id == "mid_week_slipping"
    tuesday = datetime(2026, 7, 14, 13, 0, tzinfo=TZ)
    q = plan(_signals(meals_today=0, days_logged_this_week=1, days_since_last_log=1, weekday=1), {}, tuesday)
    assert all(c.id != "mid_week_slipping" for c in q.immediate)


def test_stress_slipping_outranks_plain_slipping():
    wednesday = datetime(2026, 7, 15, 13, 0, tzinfo=TZ)
    p = plan(
        _signals(meals_today=0, days_logged_this_week=1, days_since_last_log=1, weekday=2, stress_flag=True),
        {}, wednesday,
    )
    assert p.immediate[0].id == "stress_slipping"


def test_produce_behind_speaks_in_habits_mode_in_the_afternoon():
    p = plan(
        _signals(meals_today=2, produce_consumed=1.0, produce_target=6.0),
        {}, _at(16), mode=TrackingMode.HABITS,
    )
    assert any(c.id == "produce_behind" for c in p.immediate + [e.card for e in p.scheduled])


def _inv(**over) -> InvitationSignals:
    base = {
        "mode": TrackingMode.HABITS, "focus_metrics": (), "declined_offers": frozenset(),
        "days_logged_last_21": 14, "days_logged_last_14": 10, "days_logged_days_15_to_21": 4,
    }
    base.update(over)
    return InvitationSignals(**base)


def test_habits_is_invited_up_to_calories_after_fourteen_of_twenty_one_days():
    inv = suggest(_inv())
    assert inv is not None
    assert inv.direction == "up"
    assert inv.offer_mode is TrackingMode.CALORIES
    assert "14 of the last 21 days" in inv.message
    assert suggest(_inv(days_logged_last_21=13)) is None


def test_a_declined_offer_is_never_made_again():
    assert suggest(_inv(declined_offers=frozenset({offer_key(mode=TrackingMode.CALORIES)}))) is None


def test_calories_is_offered_protein_as_a_focus():
    inv = suggest(_inv(mode=TrackingMode.CALORIES, days_logged_last_21=15))
    assert inv is not None
    assert inv.offer_focus is FocusMetric.PROTEIN
    assert inv.offer_key == "focus:protein"
    assert suggest(_inv(mode=TrackingMode.CALORIES, days_logged_last_21=15, focus_metrics=(FocusMetric.PROTEIN,))) is None


def test_thin_fortnight_is_invited_down_only_when_they_used_to_log():
    down = suggest(_inv(mode=TrackingMode.FIVE, days_logged_last_21=4, days_logged_last_14=1, days_logged_days_15_to_21=3))
    assert down is not None
    assert down.direction == "down"
    assert down.offer_mode is TrackingMode.CALORIES
    assert "Just your calories." in down.message
    brand_new = suggest(_inv(mode=TrackingMode.FIVE, days_logged_last_21=1, days_logged_last_14=1, days_logged_days_15_to_21=0))
    assert brand_new is None


def test_an_invitation_only_speaks_on_a_quiet_day():
    inv = Invitation(offer_key="calories", direction="up", offer_mode=TrackingMode.CALORIES,
                     message="You've logged 14 of the last 21 days. Want to see your calories too?", pro_tip="")
    quiet = plan(_signals(meals_today=2), {}, _at(13), mode=TrackingMode.HABITS, invitation=inv)
    assert [c.id for c in quiet.immediate] == ["invite:calories"]
    card = quiet.immediate[0]
    assert card.kind == "invitation"
    assert card.offer_mode == "calories"
    assert card.decline_key == "calories"
    assert card.cooldown_days == 14
    # A day with a nudge already shown, or one that fires now, carries no invitation.
    today = _at(13).date().isoformat()
    assert plan(_signals(meals_today=2), {"gone_quiet": today}, _at(13), mode=TrackingMode.HABITS, invitation=inv).immediate == []
    busy = plan(_signals(meals_today=0, days_since_last_log=3), {}, _at(13), mode=TrackingMode.HABITS, invitation=inv)
    assert [c.id for c in busy.immediate] == ["gone_quiet"]


def test_an_invitation_respects_its_fortnight_cooldown():
    inv = Invitation(offer_key="calories", direction="up", offer_mode=TrackingMode.CALORIES, message="m", pro_tip="")
    recent = (_at(13) - timedelta(days=5)).date().isoformat()
    old = (_at(13) - timedelta(days=15)).date().isoformat()
    assert plan(_signals(meals_today=2), {"invite:calories": recent}, _at(13), mode=TrackingMode.HABITS, invitation=inv).immediate == []
    assert plan(_signals(meals_today=2), {"invite:calories": old}, _at(13), mode=TrackingMode.HABITS, invitation=inv).immediate


def test_plan_endpoint_invites_a_habits_person_who_logged_fourteen_days(client, auth_headers, fake_db):
    from .conftest import TEST_USER_ID

    client.put("/tracking", json={"mode": "habits"}, headers=auth_headers)
    for days_ago in range(1, 15):
        _seed_meal(fake_db, TEST_USER_ID, hours_ago=days_ago * 24, kcal=400.0)
    _seed_meal(fake_db, TEST_USER_ID, hours_ago=0, kcal=400.0)
    body = client.post("/nudges/plan", json={"recently_shown": {}}, headers=auth_headers).json()
    ids = [c["id"] for c in body["immediate"]]
    assert ids == ["invite:calories"], body
    card = body["immediate"][0]
    assert card["kind"] == "invitation"
    assert card["offer_mode"] == "calories"
    assert card["decline_key"] == "calories"


def test_plan_endpoint_reads_the_check_in_as_the_stress_signal(client, auth_headers, fake_db):
    # A rough check-in this week plus a thin Monday to Wednesday reads as stress slipping; the
    # test only asserts the flag reaches the engine when the calendar allows the rule to fire.
    from .conftest import TEST_USER_ID

    client.post("/checkin/checkins", json={"weight_kg": 80.0, "hunger": 5, "energy": 1}, headers=auth_headers)
    _seed_meal(fake_db, TEST_USER_ID, hours_ago=24 * 10, kcal=400.0)
    body = client.post("/nudges/plan", json={"recently_shown": {}}, headers=auth_headers).json()
    ids = [c["id"] for c in body["immediate"]]
    from datetime import UTC
    if datetime.now(UTC).weekday() <= 2:
        assert ids[0] in {"stress_slipping", "gone_quiet"}
    else:
        assert "stress_slipping" not in ids
