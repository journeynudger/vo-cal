"""E0: GET /meals/today aggregation + POST /meals/water (offline).

Today is the home dashboard (decision #28/#41): targets (active protocol or a
documented stub) vs. consumed (macros + produce servings + water + fiber) vs.
remaining, over a tz-aware day window. All numeric assertions pin deterministic
math; nothing is invented by a model (AGENTS.md #6).
"""

from __future__ import annotations

from datetime import UTC, datetime
from uuid import uuid4

from api.nutrition.dictionary import get_dictionary

DICT = get_dictionary()


def _broccoli_item(grams: float, *, amount: float | None = None) -> dict:
    """A confirmed broccoli item (a produce food).

    ``amount`` is the serving multiplier the server re-resolves grams from (RT-02: grams is
    deterministic, not client-supplied); ``grams``/``macros`` here are advisory and ignored.
    """
    entry = DICT.lookup("broccoli").entry
    macros = entry.profile.for_grams(grams)
    return {
        "name": "broccoli",
        "amount": amount,
        "unit": None,
        "state": "unspecified",
        "fat_ratio": None,
        "brand": None,
        "prep_method": None,
        "grams": grams,
        "macros": macros.model_dump(),
        "confidence": 0.95,
        "source": "dictionary",
    }


def _chicken_item(grams: float) -> dict:
    """A confirmed chicken-breast item (not produce) with deterministic macros."""
    entry = DICT.lookup("chicken breast").entry
    macros = entry.profile.for_grams(grams)
    return {
        "name": "chicken breast",
        "amount": None,
        "unit": None,
        "state": "unspecified",
        "fat_ratio": None,
        "brand": None,
        "prep_method": None,
        "grams": grams,
        "macros": macros.model_dump(),
        "confidence": 0.9,
        "source": "dictionary",
    }


def _log_meal(client, headers, items, *, when, meal_type="lunch", cid=None):
    return client.post(
        "/meals",
        json={
            "client_meal_id": cid or str(uuid4()),
            "meal_type": meal_type,
            "items": items,
            "logged_at": when.isoformat(),
        },
        headers=headers,
    )


def _seed_protocol(fake_db, user_id, targets):
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


# -- empty day + stub fallback ----------------------------------------------


def test_empty_day_uses_stub_targets(client, auth_headers):
    date_str = datetime.now(UTC).strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()

    assert body["targets_are_stub"] is True
    assert body["meals"] == []
    assert body["avg_confidence"] == 0.0
    # Nothing consumed → remaining equals the (stub) targets.
    for key in ("kcal", "protein", "carbs", "fat", "fiber", "produce", "water"):
        assert body["consumed"][key] == 0.0
        assert body["remaining"][key] == body["targets"][key]
    # Stub targets are non-zero so the dashboard renders pre-onboarding.
    assert body["targets"]["kcal"] > 0
    assert body["targets"]["water"] > 0


def test_active_protocol_targets_win_over_stub(client, auth_headers, fake_db, test_user_id):
    _seed_protocol(
        fake_db,
        test_user_id,
        {
            "kcal": 1800,
            "protein": 150,
            "carbs": 160,
            "fat": 50,
            "fiber": 25,
            "produce": 6,
            "water": 90,
        },
    )
    date_str = datetime.now(UTC).strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()

    assert body["targets_are_stub"] is False
    assert body["targets"]["kcal"] == 1800
    assert body["targets"]["protein"] == 150
    assert body["targets"]["produce"] == 6
    assert body["targets"]["water"] == 90


def test_partial_protocol_targets_fall_back_per_key(client, auth_headers, fake_db, test_user_id):
    # A protocol missing some keys still wins (not a stub), missing keys fall back.
    _seed_protocol(fake_db, test_user_id, {"kcal": 1700, "protein": 140})
    date_str = datetime.now(UTC).strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()

    assert body["targets_are_stub"] is False
    assert body["targets"]["kcal"] == 1700
    assert body["targets"]["protein"] == 140
    # Missing keys filled from the stub, never zeroed.
    assert body["targets"]["water"] > 0
    assert body["targets"]["produce"] > 0


def test_protein_band_surfaces_from_protocol(client, auth_headers, fake_db, test_user_id):
    # The engine-owned protein band rides along in the protocol's targets jsonb and is surfaced
    # on the Today response so the dashboard can render the centered optimal range.
    _seed_protocol(
        fake_db,
        test_user_id,
        {"protein": 150, "protein_min": 135, "protein_max": 165},
    )
    date_str = datetime.now(UTC).strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()

    assert body["protein_min"] == 135
    assert body["protein_max"] == 165
    assert body["protein_min"] < body["targets"]["protein"] < body["protein_max"]


def test_protein_band_falls_back_to_target_when_absent(
    client, auth_headers, fake_db, test_user_id
):
    # A protocol predating the band (no protein_min/max) must not render a 0–0 range: the band
    # collapses to the protein target (a point), so the bar shows a goal rather than a misleading
    # empty range.
    _seed_protocol(fake_db, test_user_id, {"protein": 140})
    date_str = datetime.now(UTC).strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()

    assert body["protein_min"] == 140
    assert body["protein_max"] == 140


# -- targets vs. consumed vs. remaining math --------------------------------


def test_consumed_and_remaining_math(client, auth_headers, fake_db, test_user_id):
    _seed_protocol(
        fake_db,
        test_user_id,
        {"kcal": 2000, "protein": 120, "carbs": 200, "fat": 60,
         "fiber": 28, "produce": 5, "water": 100},
    )
    now = datetime.now(UTC)
    # One serving of broccoli (its serving_grams) → 1.0 produce serving.
    grams = DICT.lookup("broccoli").entry.serving_grams
    broccoli = _broccoli_item(grams)
    resp = _log_meal(client, auth_headers, [broccoli], when=now, meal_type="dinner")
    assert resp.status_code == 201

    date_str = now.strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()

    expected = broccoli["macros"]
    assert body["consumed"]["kcal"] == expected["kcal"]
    assert body["consumed"]["protein"] == expected["protein"]
    assert body["consumed"]["fiber"] == expected["fiber"]
    assert body["consumed"]["produce"] == 1.0

    assert body["remaining"]["kcal"] == round(2000 - expected["kcal"], 1)
    assert body["remaining"]["protein"] == round(120 - expected["protein"], 1)
    assert body["remaining"]["fiber"] == round(28 - expected["fiber"], 1)
    assert body["remaining"]["produce"] == round(5 - 1.0, 1)


def test_remaining_can_go_negative_over_target(client, auth_headers, fake_db, test_user_id):
    _seed_protocol(fake_db, test_user_id, {"produce": 1})
    now = datetime.now(UTC)
    # 3 servings — expressed as the serving multiplier the server re-resolves from (RT-02).
    grams = DICT.lookup("broccoli").entry.serving_grams * 3
    _log_meal(client, auth_headers, [_broccoli_item(grams, amount=3)], when=now)

    date_str = now.strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()
    assert body["consumed"]["produce"] == 3.0
    assert body["remaining"]["produce"] == -2.0  # over target, not clamped


def test_produce_totals_across_meals_and_only_produce_foods(
    client, auth_headers, fake_db, test_user_id
):
    _seed_protocol(fake_db, test_user_id, {"produce": 5})
    now = datetime.now(UTC)
    bgrams = DICT.lookup("broccoli").entry.serving_grams
    # Two produce servings (broccoli) + chicken (no produce credit).
    _log_meal(client, auth_headers, [_broccoli_item(bgrams)], when=now, cid="m-a")
    _log_meal(
        client, auth_headers,
        [_broccoli_item(bgrams), _chicken_item(150.0)],
        when=now, cid="m-b",
    )
    date_str = now.strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()
    assert body["consumed"]["produce"] == 2.0  # chicken contributes none
    assert len(body["meals"]) == 2


# -- water ------------------------------------------------------------------


def test_water_log_shows_in_today(client, auth_headers):
    now = datetime.now(UTC)
    r1 = client.post(
        "/meals/water",
        json={"client_water_id": "w-16", "amount_oz": 16, "logged_at": now.isoformat()},
        headers=auth_headers,
    )
    assert r1.status_code == 201
    client.post(
        "/meals/water",
        json={"client_water_id": "w-8", "amount_oz": 8, "logged_at": now.isoformat()},
        headers=auth_headers,
    )
    date_str = now.strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()
    assert body["consumed"]["water"] == 24.0


def test_water_rejects_non_positive(client, auth_headers):
    bad = client.post(
        "/meals/water", json={"client_water_id": "neg", "amount_oz": 0}, headers=auth_headers
    )
    assert bad.status_code == 422


def test_water_is_idempotent_on_replay(client, auth_headers):
    # RT-13: meals dedupe on replay via client_meal_id, but water had no idempotency
    # key, so a retried POST (the documented timeout-then-retry the outbox exists for)
    # double-counted a dashboard pillar. A replay with the same client_water_id is a
    # no-op: /today shows the amount once.
    now = datetime.now(UTC)
    entry = {"client_water_id": "w1", "amount_oz": 16, "logged_at": now.isoformat()}
    r1 = client.post("/meals/water", json=entry, headers=auth_headers)
    assert r1.status_code == 201
    r2 = client.post("/meals/water", json=entry, headers=auth_headers)
    assert r2.status_code == 201
    assert r2.json()["id"] == r1.json()["id"]  # same row, not a second one

    date_str = now.strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()
    assert body["consumed"]["water"] == 16.0  # not 32.0


# -- tz day boundary --------------------------------------------------------


def test_tz_day_boundary(client, auth_headers, fake_db, test_user_id):
    # Profile in America/New_York. A meal logged at 02:00 UTC belongs to the
    # *previous* local day (21:00 ET), not the UTC day.
    fake_db.tables.setdefault("profiles", []).append(
        {"id": str(test_user_id), "tz": "America/New_York"}
    )
    # 2026-03-10 02:00 UTC == 2026-03-09 22:00 ET (EDT, UTC-4 after DST start 3/8).
    at = datetime(2026, 3, 10, 2, 0, tzinfo=UTC)
    grams = DICT.lookup("broccoli").entry.serving_grams
    _log_meal(client, auth_headers, [_broccoli_item(grams)], when=at)

    # The local day it belongs to (3/9) sees it.
    prev = client.get("/meals/today?date=2026-03-09", headers=auth_headers).json()
    assert prev["consumed"]["produce"] == 1.0
    assert len(prev["meals"]) == 1

    # The UTC-calendar day (3/10) does NOT (its local window opens at 04:00 UTC).
    same = client.get("/meals/today?date=2026-03-10", headers=auth_headers).json()
    assert same["consumed"]["produce"] == 0.0
    assert same["meals"] == []


def test_water_respects_tz_boundary(client, auth_headers, fake_db, test_user_id):
    fake_db.tables.setdefault("profiles", []).append(
        {"id": str(test_user_id), "tz": "America/New_York"}
    )
    at = datetime(2026, 3, 10, 2, 0, tzinfo=UTC)  # 3/9 22:00 ET
    client.post(
        "/meals/water",
        json={"client_water_id": "w-tz", "amount_oz": 20, "logged_at": at.isoformat()},
        headers=auth_headers,
    )
    prev = client.get("/meals/today?date=2026-03-09", headers=auth_headers).json()
    assert prev["consumed"]["water"] == 20.0
    same = client.get("/meals/today?date=2026-03-10", headers=auth_headers).json()
    assert same["consumed"]["water"] == 0.0


def test_bad_date_is_422(client, auth_headers):
    assert client.get("/meals/today?date=not-a-date", headers=auth_headers).status_code == 422


# -- avg confidence ---------------------------------------------------------


def test_avg_confidence_is_kcal_weighted(client, auth_headers, fake_db, test_user_id):
    _seed_protocol(fake_db, test_user_id, {})
    now = datetime.now(UTC)
    # Server recomputes meal confidence on confirm; chicken's item confidence is
    # 0.9, so a single-item meal's (kcal-weighted) confidence is 0.9.
    _log_meal(client, auth_headers, [_chicken_item(150.0)], when=now, cid="c-1")
    date_str = now.strftime("%Y-%m-%d")
    body = client.get(f"/meals/today?date={date_str}", headers=auth_headers).json()
    assert body["avg_confidence"] == 0.9


# -- RLS / tenant isolation -------------------------------------------------


def test_today_is_owner_scoped(client, auth_headers, auth_headers_user_2, fake_db, test_user_id):
    _seed_protocol(fake_db, test_user_id, {"kcal": 1900, "produce": 7})
    now = datetime.now(UTC)
    grams = DICT.lookup("broccoli").entry.serving_grams
    _log_meal(client, auth_headers, [_broccoli_item(grams)], when=now)
    client.post(
        "/meals/water",
        json={"client_water_id": "w-scope", "amount_oz": 30, "logged_at": now.isoformat()},
        headers=auth_headers,
    )
    date_str = now.strftime("%Y-%m-%d")

    # User 2 sees no meals, no water, no produce — and NOT user 1's protocol.
    other = client.get(f"/meals/today?date={date_str}", headers=auth_headers_user_2).json()
    assert other["meals"] == []
    assert other["consumed"]["produce"] == 0.0
    assert other["consumed"]["water"] == 0.0
    assert other["targets_are_stub"] is True  # user 2 has no protocol
    assert other["targets"]["kcal"] != 1900


def test_water_is_owner_scoped(client, auth_headers, auth_headers_user_2):
    now = datetime.now(UTC)
    client.post(
        "/meals/water",
        json={"client_water_id": "w-owner", "amount_oz": 40, "logged_at": now.isoformat()},
        headers=auth_headers,
    )
    date_str = now.strftime("%Y-%m-%d")
    other = client.get(f"/meals/today?date={date_str}", headers=auth_headers_user_2).json()
    assert other["consumed"]["water"] == 0.0
