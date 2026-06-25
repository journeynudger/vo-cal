"""B6: /meals endpoint tests (offline). Confirm -> corrections -> day view -> delete.

Confirm is the product's handoff: server recomputes totals, diffs confirmed vs
parsed into append-only corrections, and is idempotent by client_meal_id.
"""

from __future__ import annotations

from datetime import UTC, datetime


def _parse(client, headers, transcript="4oz 93/7 beef"):
    return client.post("/parse", json={"transcript": transcript}, headers=headers).json()


def _confirmed_items(parse_body):
    """Turn parse-result items into confirmed-item payloads (extra fields ignored)."""
    return [
        {
            "name": it["name"],
            "amount": it["amount"],
            "unit": it["unit"],
            "state": it["state"],
            "fat_ratio": it["fat_ratio"],
            "brand": it["brand"],
            "prep_method": it["prep_method"],
            "grams": it["grams"],
            "macros": it["macros"],
            "confidence": it["confidence"],
            "source": it["source"],
        }
        for it in parse_body["items"]
    ]


def test_log_meal_no_edits_zero_corrections(client, auth_headers):
    parsed = _parse(client, auth_headers)
    resp = client.post(
        "/meals",
        json={
            "client_meal_id": "m1",
            "parse_id": parsed["parse_id"],
            "name": "Lunch beef",
            "meal_type": "lunch",
            "items": _confirmed_items(parsed),
        },
        headers=auth_headers,
    )
    assert resp.status_code == 201
    body = resp.json()
    assert body["corrections_count"] == 0
    assert body["totals"]["kcal"] > 0


def test_delete_non_uuid_meal_is_404_not_500(client, auth_headers):
    # A non-UUID path id must be a clean 404, never an uncaught ValueError → 500 (RT-29/47).
    assert client.delete("/meals/not-a-uuid", headers=auth_headers).status_code == 404


def test_meal_rejects_negative_macros(client, auth_headers):
    # Macros are summed into durable meal/day totals; a negative is data poison, never valid.
    parsed = _parse(client, auth_headers)
    items = _confirmed_items(parsed)
    items[0]["macros"] = {"kcal": -5.0, "protein": 0.0, "carbs": 0.0, "fat": 0.0, "fiber": 0.0}
    resp = client.post(
        "/meals",
        json={"client_meal_id": "neg-1", "parse_id": parsed["parse_id"],
              "meal_type": "lunch", "items": items},
        headers=auth_headers,
    )
    assert resp.status_code == 422


def test_meal_rejects_nan_and_inf_macros(client, auth_headers):
    # NaN/Inf survive JSON (stdlib json emits/accepts them) and a NaN serializes back to JSON
    # null, which breaks the non-optional Swift decode of a "Logged" meal. Reject at the door.
    import json

    parsed = _parse(client, auth_headers)
    items = _confirmed_items(parsed)
    items[0]["macros"] = {"kcal": float("inf"), "protein": float("nan"),
                          "carbs": 0.0, "fat": 0.0, "fiber": 0.0}
    body = {"client_meal_id": "nan-1", "parse_id": parsed["parse_id"],
            "meal_type": "lunch", "items": items}
    resp = client.post(
        "/meals",
        content=json.dumps(body),
        headers={**auth_headers, "Content-Type": "application/json"},
    )
    assert resp.status_code == 422


def test_log_meal_is_idempotent(client, auth_headers):
    parsed = _parse(client, auth_headers)
    payload = {
        "client_meal_id": "dup-1",
        "parse_id": parsed["parse_id"],
        "meal_type": "lunch",
        "items": _confirmed_items(parsed),
    }
    first = client.post("/meals", json=payload, headers=auth_headers).json()
    second = client.post("/meals", json=payload, headers=auth_headers).json()
    assert first["id"] == second["id"]


def test_replay_after_delete_is_idempotent(client, auth_headers):
    # RT-12: a tombstoned meal leaves (user_id, client_meal_id) occupied under the
    # original partial index, so an outbox replay that crosses a delete 500s on the
    # live DB (and silently double-rows on Fake). After the fix the replay inserts a
    # fresh live row and the day shows exactly one meal — never a 500, never a dup.
    parsed = _parse(client, auth_headers)
    payload = {
        "client_meal_id": "replay-1",
        "parse_id": parsed["parse_id"],
        "meal_type": "lunch",
        "items": _confirmed_items(parsed),
        "logged_at": datetime.now(UTC).isoformat(),
    }
    first = client.post("/meals", json=payload, headers=auth_headers)
    assert first.status_code == 201
    meal_id = first.json()["id"]

    assert client.delete(f"/meals/{meal_id}", headers=auth_headers).status_code == 204

    second = client.post("/meals", json=payload, headers=auth_headers)
    assert second.status_code == 201  # not a 500 from the occupied tombstone slot

    date_str = datetime.now(UTC).strftime("%Y-%m-%d")
    day = client.get(f"/meals?date={date_str}", headers=auth_headers).json()
    assert len(day["meals"]) == 1  # exactly one live meal, not a duplicate
    assert day["meals"][0]["id"] != meal_id  # the deleted one stays deleted


def test_edits_record_corrections(client, auth_headers):
    parsed = _parse(client, auth_headers)
    items = _confirmed_items(parsed)
    items[0]["amount"] = 6.0
    items[0]["grams"] = 170.0
    resp = client.post(
        "/meals",
        json={
            "client_meal_id": "edited-1",
            "parse_id": parsed["parse_id"],
            "meal_type": "lunch",
            "items": items,
        },
        headers=auth_headers,
    )
    assert resp.status_code == 201
    # amount and grams both changed on item 0 → at least 2 corrections.
    assert resp.json()["corrections_count"] >= 2


def test_save_as_usual_writes_template(client, auth_headers, fake_db):
    parsed = _parse(client, auth_headers)
    client.post(
        "/meals",
        json={
            "client_meal_id": "usual-1",
            "parse_id": parsed["parse_id"],
            "name": "My usual beef",
            "meal_type": "lunch",
            "items": _confirmed_items(parsed),
            "save_as_usual": True,
        },
        headers=auth_headers,
    )
    assert len(fake_db.tables.get("saved_meals", [])) == 1


def test_day_view_and_tombstone(client, auth_headers):
    parsed = _parse(client, auth_headers)
    today = datetime.now(UTC)
    logged = client.post(
        "/meals",
        json={
            "client_meal_id": "day-1",
            "parse_id": parsed["parse_id"],
            "meal_type": "dinner",
            "items": _confirmed_items(parsed),
            "logged_at": today.isoformat(),
        },
        headers=auth_headers,
    ).json()

    date_str = today.strftime("%Y-%m-%d")
    day = client.get(f"/meals?date={date_str}", headers=auth_headers).json()
    assert any(m["id"] == logged["id"] for m in day["meals"])
    assert day["totals"]["kcal"] > 0

    deleted = client.delete(f"/meals/{logged['id']}", headers=auth_headers)
    assert deleted.status_code == 204

    day_after = client.get(f"/meals?date={date_str}", headers=auth_headers).json()
    assert all(m["id"] != logged["id"] for m in day_after["meals"])


def test_meals_scoped_per_user(client, auth_headers, auth_headers_user_2):
    parsed = _parse(client, auth_headers)
    today = datetime.now(UTC)
    client.post(
        "/meals",
        json={
            "client_meal_id": "u1-meal",
            "parse_id": parsed["parse_id"],
            "meal_type": "lunch",
            "items": _confirmed_items(parsed),
            "logged_at": today.isoformat(),
        },
        headers=auth_headers,
    )
    date_str = today.strftime("%Y-%m-%d")
    other = client.get(f"/meals?date={date_str}", headers=auth_headers_user_2).json()
    assert other["meals"] == []
