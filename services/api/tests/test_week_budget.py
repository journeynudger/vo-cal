"""Weekly budget API (offline — FakeDatabase + X-Test-User seam).

Covers: auth, stub fallback, the default (all-baseline) plan, PUT validation,
plan round-trip + append-only supersession, tenant isolation, and the
carry-from-yesterday effect on today's adjusted target.

The suite runs at arbitrary wall-clock times, but several cases need the LOCAL
week to have a past day (a "yesterday") or at least two remaining days. The
server resolves "today" in the request tz, so each such test picks an IANA
offset zone whose local weekday satisfies what it needs — deterministic at any
run time because UTC−12 .. UTC+14 always spans two consecutive local dates.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

import pytest

# Extreme fixed-offset zones: between them every reachable local date exists.
_CANDIDATE_TZS = ("Etc/GMT+12", "UTC", "Etc/GMT-14")


def _tz_where(predicate) -> tuple[str, ZoneInfo]:
    """First candidate tz whose CURRENT local weekday satisfies ``predicate``."""
    for name in _CANDIDATE_TZS:
        zone = ZoneInfo(name)
        if predicate(datetime.now(zone).date().weekday()):
            return name, zone
    pytest.fail("no candidate tz satisfies the weekday predicate")


def _local_today(zone: ZoneInfo) -> date:
    return datetime.now(zone).date()


def _monday_of(day: date) -> date:
    return day - timedelta(days=day.weekday())


def _seed_protocol(fake_db, user_id, targets) -> None:
    fake_db.tables.setdefault("protocols", []).append(
        {
            "id": str(uuid4()),
            "user_id": str(user_id),
            "version": 1,
            "active": True,
            "targets": targets,
            "whys": {},
        }
    )


def _seed_meal(fake_db, user_id, *, logged_at: datetime, kcal: float) -> None:
    """A minimal live meal_logs row (mirrors test_nudges_api._seed_meal)."""
    fake_db.tables.setdefault("meal_logs", []).append(
        {
            "id": str(uuid4()),
            "user_id": str(user_id),
            "client_meal_id": f"wb-{uuid4()}",
            "name": None,
            "meal_type": "lunch",
            "items": [],
            "totals": {"kcal": kcal, "protein": 30.0, "carbs": 40.0, "fat": 10.0, "fiber": 5.0},
            "confidence": 0.9,
            "logged_at": logged_at.isoformat(),
        }
    )


def _get_budget(client, headers, *, day: date, tz: str) -> dict:
    # params= so httpx percent-encodes the tz — a literal '+' in "Etc/GMT+12"
    # would decode to a space and silently fall back to the profile tz.
    resp = client.get(
        "/week/budget", params={"date": day.isoformat(), "tz": tz}, headers=headers
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _put_plan(client, headers, *, week_start: date, tz: str, allocations: dict[str, int]):
    return client.put(
        "/week/plan",
        json={"week_start": week_start.isoformat(), "tz": tz, "allocations": allocations},
        headers=headers,
    )


# -- auth ---------------------------------------------------------------------


def test_budget_requires_auth(client):
    assert client.get("/week/budget?date=2026-08-10").status_code == 401


def test_plan_requires_auth(client):
    body = {"week_start": "2026-08-10", "allocations": {}}
    assert client.put("/week/plan", json=body).status_code == 401


# -- GET: stub + default plan -------------------------------------------------


def test_budget_without_protocol_uses_stub_2000(client, auth_headers):
    tz, zone = _tz_where(lambda _w: True)
    body = _get_budget(client, auth_headers, day=_local_today(zone), tz=tz)
    assert body["targets_are_stub"] is True
    assert body["baseline_daily_kcal"] == 2000.0
    assert len(body["days"]) == 7
    assert all(d["planned_kcal"] == 2000.0 for d in body["days"])


def test_budget_default_plan_is_baseline_everywhere(client, auth_headers, fake_db, test_user_id):
    _seed_protocol(fake_db, test_user_id, {"kcal": 1800})
    tz, zone = _tz_where(lambda _w: True)
    today = _local_today(zone)
    body = _get_budget(client, auth_headers, day=today, tz=tz)

    assert body["targets_are_stub"] is False
    assert body["baseline_daily_kcal"] == 1800.0
    assert body["weekly_target_kcal"] == 7 * 1800.0
    assert all(d["planned_kcal"] == 1800.0 for d in body["days"])
    # Week shape: Monday-start, 7 consecutive days, weekday 0..6.
    assert body["week_start"] == _monday_of(today).isoformat()
    assert body["week_end"] == (_monday_of(today) + timedelta(days=6)).isoformat()
    assert [d["weekday"] for d in body["days"]] == list(range(7))
    # No logs → no carry, adjusted == planned.
    assert body["carry_kcal"] == 0.0
    assert all(d["adjusted_target_kcal"] == 1800 for d in body["days"])


def test_bad_date_is_422(client, auth_headers):
    assert client.get("/week/budget?date=not-a-date", headers=auth_headers).status_code == 422


# -- PUT: validation ----------------------------------------------------------


def test_plan_rejects_non_monday_week_start(client, auth_headers):
    tz, zone = _tz_where(lambda _w: True)
    not_monday = _monday_of(_local_today(zone)) + timedelta(days=1)
    resp = _put_plan(client, auth_headers, week_start=not_monday, tz=tz, allocations={})
    assert resp.status_code == 422
    assert "Monday" in resp.json()["detail"]


def test_plan_rejects_fully_ended_week(client, auth_headers):
    tz, zone = _tz_where(lambda _w: True)
    last_monday = _monday_of(_local_today(zone)) - timedelta(days=7)
    resp = _put_plan(client, auth_headers, week_start=last_monday, tz=tz, allocations={})
    assert resp.status_code == 422
    assert "ended" in resp.json()["detail"]


def test_plan_rejects_past_day_allocation(client, auth_headers):
    # Needs a local week with a past day: pick a tz where today isn't Monday.
    tz, zone = _tz_where(lambda w: w >= 1)
    today = _local_today(zone)
    yesterday = today - timedelta(days=1)
    resp = _put_plan(
        client, auth_headers,
        week_start=_monday_of(today), tz=tz,
        allocations={yesterday.isoformat(): 2000},
    )
    assert resp.status_code == 422
    assert "past" in resp.json()["detail"]


def test_plan_rejects_value_below_floor(client, auth_headers):
    tz, zone = _tz_where(lambda _w: True)
    today = _local_today(zone)
    resp = _put_plan(
        client, auth_headers,
        week_start=_monday_of(today), tz=tz,
        allocations={today.isoformat(): 500},  # < max(1200, 0.5·2000)
    )
    assert resp.status_code == 422


def test_plan_rejects_value_above_cap(client, auth_headers):
    tz, zone = _tz_where(lambda _w: True)
    today = _local_today(zone)
    resp = _put_plan(
        client, auth_headers,
        week_start=_monday_of(today), tz=tz,
        allocations={today.isoformat(): 5000},  # > 2·2000
    )
    assert resp.status_code == 422


def test_plan_rejects_sum_drift(client, auth_headers):
    # Raising one day without lowering another breaks the weekly total (±10).
    tz, zone = _tz_where(lambda _w: True)
    today = _local_today(zone)
    resp = _put_plan(
        client, auth_headers,
        week_start=_monday_of(today), tz=tz,
        allocations={today.isoformat(): 2500},
    )
    assert resp.status_code == 422
    assert "weekly target" in resp.json()["detail"]


# -- PUT: round-trip + supersession -------------------------------------------


def test_plan_round_trips_through_get(client, auth_headers, fake_db):
    # Needs today AND tomorrow inside the same week (weekday ≤ 5).
    tz, zone = _tz_where(lambda w: w <= 5)
    today = _local_today(zone)
    tomorrow = today + timedelta(days=1)
    allocations = {today.isoformat(): 1800, tomorrow.isoformat(): 2200}

    put = _put_plan(client, auth_headers, week_start=_monday_of(today), tz=tz,
                    allocations=allocations)
    assert put.status_code == 200, put.text
    put_body = put.json()

    got = _get_budget(client, auth_headers, day=today, tz=tz)
    for body in (put_body, got):
        by_date = {d["date"]: d for d in body["days"]}
        assert by_date[today.isoformat()]["planned_kcal"] == 1800.0
        assert by_date[tomorrow.isoformat()]["planned_kcal"] == 2200.0
        # Untouched days keep the baseline; the weekly total is preserved.
        assert body["weekly_target_kcal"] == 7 * 2000.0
        # No logs → no carry: adjusted follows the plan exactly.
        assert by_date[today.isoformat()]["adjusted_target_kcal"] == 1800
        assert by_date[tomorrow.isoformat()]["adjusted_target_kcal"] == 2200
    assert len(fake_db.tables["week_plans"]) == 1
    assert fake_db.tables["week_plans"][0]["version"] == 1
    # The stored row maps all 7 ISO dates (past days frozen server-side).
    assert len(fake_db.tables["week_plans"][0]["allocations"]) == 7


def test_second_plan_supersedes_first(client, auth_headers, fake_db):
    tz, zone = _tz_where(lambda w: w <= 5)
    today = _local_today(zone)
    tomorrow = today + timedelta(days=1)
    monday = _monday_of(today)

    _put_plan(client, auth_headers, week_start=monday, tz=tz,
              allocations={today.isoformat(): 1800, tomorrow.isoformat(): 2200})
    second = _put_plan(client, auth_headers, week_start=monday, tz=tz,
                       allocations={today.isoformat(): 2200, tomorrow.isoformat(): 1800})
    assert second.status_code == 200, second.text

    # Append-only versioning: both rows persist, v2 is the effective plan.
    versions = sorted(r["version"] for r in fake_db.tables["week_plans"])
    assert versions == [1, 2]
    body = _get_budget(client, auth_headers, day=today, tz=tz)
    by_date = {d["date"]: d for d in body["days"]}
    assert by_date[today.isoformat()]["planned_kcal"] == 2200.0
    assert by_date[tomorrow.isoformat()]["planned_kcal"] == 1800.0


# -- RLS / tenant isolation ---------------------------------------------------


def test_plan_is_owner_scoped(client, auth_headers, auth_headers_user_2):
    tz, zone = _tz_where(lambda w: w <= 5)
    today = _local_today(zone)
    tomorrow = today + timedelta(days=1)
    _put_plan(client, auth_headers, week_start=_monday_of(today), tz=tz,
              allocations={today.isoformat(): 1800, tomorrow.isoformat(): 2200})

    # User 2 sees the untouched default plan, never user 1's allocations.
    other = _get_budget(client, auth_headers_user_2, day=today, tz=tz)
    assert all(d["planned_kcal"] == 2000.0 for d in other["days"])


# -- carry: yesterday's logs move today's target ------------------------------


def test_overeating_yesterday_lowers_todays_adjusted_target(
    client, auth_headers, fake_db, test_user_id
):
    # Needs a yesterday INSIDE the current local week (weekday ≥ 1).
    tz, zone = _tz_where(lambda w: w >= 1)
    today = _local_today(zone)
    yesterday = today - timedelta(days=1)
    _seed_protocol(fake_db, test_user_id, {"kcal": 2000})
    # 2500 kcal logged yesterday against a 2000 plan → carry −500.
    _seed_meal(
        fake_db, test_user_id,
        logged_at=datetime.combine(yesterday, datetime.min.time(), tzinfo=zone)
        + timedelta(hours=12),
        kcal=2500.0,
    )

    body = _get_budget(client, auth_headers, day=today, tz=tz)
    assert body["carry_kcal"] == -500.0
    by_date = {d["date"]: d for d in body["days"]}
    today_day = by_date[today.isoformat()]
    assert today_day["state"] == "today"
    assert today_day["adjusted_target_kcal"] < 2000
    # Yesterday is history: consumed shows, but its target never moves.
    y = by_date[yesterday.isoformat()]
    assert y["state"] == "past"
    assert y["logged"] is True
    assert y["consumed_kcal"] == 2500.0
    assert y["adjusted_target_kcal"] == 2000
    # The remaining days absorb exactly the carry (whole-kcal exact).
    remaining = [d for d in body["days"] if d["state"] != "past"]
    assert sum(d["adjusted_target_kcal"] for d in remaining) == 2000 * len(remaining) - 500
