"""A day the client names parses inside what the day arithmetic can hold (2026-10-22 audit).

``0001-01-01`` and ``9999-12-31`` parsed, and the week's Monday or the next midnight past them
raised an OverflowError answered as a 500 on every surface that takes ``?date=``. A
Buddhist-calendar iPhone writes the year as 2569: that day stays readable (an empty day, the
phone's bug to fix), and the bar, which only ever answers about today, reads it as today.
"""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

INTAKE = {
    "age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0,
    "goal": "cut", "work": "desk", "train": "moderate", "kids": False,
    "med": "none", "stress": "moderate",
}
SURFACES = ["/meals?date={d}", "/meals/today?date={d}&tz=America/Los_Angeles", "/meals/summary?date={d}", "/week/budget?date={d}"]


@pytest.mark.parametrize("day", ["0001-01-01", "9999-12-31", "1899-12-31", "3000-01-01"])
@pytest.mark.parametrize("surface", SURFACES)
def test_a_day_past_the_arithmetic_is_refused_never_a_500(client, auth_headers, surface, day):
    assert client.get(surface.format(d=day), headers=auth_headers).status_code == 422


@pytest.mark.parametrize("surface", SURFACES)
def test_a_buddhist_calendar_year_still_reads(client, auth_headers, surface):
    assert client.get(surface.format(d="2569-10-22"), headers=auth_headers).status_code == 200


def test_week_plan_refuses_a_week_past_the_arithmetic(client, auth_headers):
    body = {"week_start": "9999-12-27", "allocations": {}}
    assert client.put("/week/plan", json=body, headers=auth_headers).status_code == 422


@pytest.mark.parametrize("phone_day", ["2569-10-22", "1999-01-01", "not-a-day", None])
def test_the_bar_answers_about_today_whatever_the_phones_calendar_wrote(client, auth_headers, phone_day):
    client.post("/intake", json={"intake": INTAKE}, headers=auth_headers)
    assert client.post("/protocols/generate", json={"intake": INTAKE}, headers=auth_headers).status_code == 201
    now = datetime.now(UTC)
    logged = client.post(
        "/meals/water",
        json={"client_water_id": "w-bar-day", "amount_oz": 16, "logged_at": now.isoformat()},
        headers=auth_headers,
    )
    assert logged.status_code in (200, 201), logged.text
    body = {"text": "how much water today", "tz": "UTC"}
    if phone_day is not None:
        body["date"] = phone_day
    reply = client.post("/assist", json=body, headers=auth_headers)
    assert reply.status_code == 200, reply.text
    panel = reply.json()["panel"]
    assert (panel["metric"], panel["consumed"]) == ("water", 16.0)


def test_today_on_a_past_day_says_that_day(client, auth_headers):
    from datetime import timedelta

    today = datetime.now(UTC).date()
    for day, word in ((today, "today"), (today - timedelta(days=1), "that day")):
        body = client.get(f"/meals/today?date={day.isoformat()}&tz=UTC", headers=auth_headers).json()
        card = next(p for p in body["panels"] if p["kind"] == "calories_left")
        assert card["support"].endswith(word), card["support"]
