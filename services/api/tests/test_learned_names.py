"""R9: the parser learns renames (complaint 4, "bulk correct common typos").

A rename through /parse/refine used to supersede the parse and the confirm-time diff
compared against the superseded row: no correction row, nothing learned. Now corrections
diff against the ROOT of the chain, the learned map is derived from those rows, applied
before resolution on every later parse and recorded on the parse row, and Settings can
forget one (append-only).
"""

from __future__ import annotations

from api.db import FakeDatabase
from api.meals.learning import apply_learned_names, derive_learned_names, normalize_name
from api.parser.schemas import ParsedItem

USER_A = "11111111-1111-1111-1111-111111111111"
USER_B = "22222222-2222-2222-2222-222222222222"


def _parse(client, headers, transcript="4oz 93/7 beef"):
    return client.post("/parse", json={"transcript": transcript}, headers=headers).json()


def _confirmed_items(body):
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
        for it in body["items"]
    ]


def _rename(client, headers, parse_id, name):
    resp = client.post(
        "/parse/refine",
        json={"parse_id": parse_id, "answers": [{"field": "items[0].name", "value": name}]},
        headers=headers,
    )
    assert resp.status_code == 200
    return resp.json()


def _log(client, headers, body, client_meal_id):
    resp = client.post(
        "/meals",
        json={
            "client_meal_id": client_meal_id,
            "parse_id": body["parse_id"],
            "meal_type": "lunch",
            "items": _confirmed_items(body),
        },
        headers=headers,
    )
    assert resp.status_code == 201
    return resp.json()


def _learned(client, headers):
    resp = client.get("/meals/learned-names", headers=headers)
    assert resp.status_code == 200
    return resp.json()


# -- pure ------------------------------------------------------------------------------


def test_derive_latest_wins_forget_removes_identity_ignored() -> None:
    rows = [
        {"field": "name", "parsed_value": "Oil Coast", "confirmed_value": "Oikos", "created_at": "2026-01-01T00:00:00", "meal_log_id": "m1"},
        {"field": "name", "parsed_value": "oil coast", "confirmed_value": "Oikos", "created_at": "2026-01-02T00:00:00", "meal_log_id": "m2"},
        {"field": "name", "parsed_value": "codex", "confirmed_value": "Codecs", "created_at": "2026-01-03T00:00:00", "meal_log_id": "m3"},
        {"field": "name_forget", "parsed_value": "codex", "confirmed_value": "Codecs", "created_at": "2026-01-04T00:00:00", "meal_log_id": "m3"},
        {"field": "name", "parsed_value": "rice", "confirmed_value": "Rice", "created_at": "2026-01-05T00:00:00", "meal_log_id": "m4"},
        {"field": "amount", "parsed_value": 1, "confirmed_value": 2, "created_at": "2026-01-06T00:00:00", "meal_log_id": "m4"},
    ]
    learned = derive_learned_names(reversed(rows))
    assert set(learned) == {"oil coast"}
    assert learned["oil coast"].corrected == "Oikos"
    assert learned["oil coast"].count == 2
    assert learned["oil coast"].meal_log_id == "m2"


def test_apply_renames_and_records_the_name_as_heard() -> None:
    learned = derive_learned_names([
        {"field": "name", "parsed_value": "oil coast", "confirmed_value": "Oikos", "created_at": "t", "meal_log_id": "m"},
    ])
    items = [
        ParsedItem(name="Oil  Coast", amount=1, unit="cup", confidence=0.9),
        ParsedItem(name="banana", confidence=0.9),
    ]
    renamed, applied = apply_learned_names(items, learned)
    assert [i.name for i in renamed] == ["Oikos", "banana"]
    assert renamed[0].amount == 1
    assert renamed[0].unit is not None
    assert applied == [{"index": 0, "heard": "Oil  Coast", "corrected": "Oikos"}]
    assert normalize_name("  Oil   Coast ") == "oil coast"


async def test_fake_db_select_owned_via_scopes_through_the_parent() -> None:
    db = FakeDatabase()
    mine = await db.insert("meal_logs", {"user_id": USER_A, "client_meal_id": "a"})
    theirs = await db.insert("meal_logs", {"user_id": USER_B, "client_meal_id": "b"})
    await db.insert("corrections", {"meal_log_id": mine["id"], "field": "name", "item_index": 0})
    await db.insert("corrections", {"meal_log_id": theirs["id"], "field": "name", "item_index": 0})
    await db.insert("corrections", {"meal_log_id": mine["id"], "field": "amount", "item_index": 0})
    import uuid

    rows = await db.select_owned_via(
        "corrections", parent_table="meal_logs", parent_key="meal_log_id",
        user_id=uuid.UUID(USER_A), filters={"field": "name"},
    )
    assert [r["meal_log_id"] for r in rows] == [mine["id"]]


# -- API ------------------------------------------------------------------------------


def test_rename_through_refine_is_a_correction_against_the_root(client, auth_headers):
    parsed = _parse(client, auth_headers)
    assert parsed["items"][0]["name"] == "ground beef"
    refined = _rename(client, auth_headers, parsed["parse_id"], "ground turkey")
    logged = _log(client, auth_headers, refined, "learn-1")
    # The rename is the one correction: measured against the root parse, not the refined one.
    assert logged["corrections_count"] == 1
    learned = _learned(client, auth_headers)
    assert learned == [
        {"heard": "ground beef", "corrected": "ground turkey", "count": 1, "learned_at": learned[0]["learned_at"]}
    ]
    assert learned[0]["learned_at"] is not None


def test_learned_name_applies_on_the_next_parse_and_is_recorded(client, auth_headers, fake_db):
    parsed = _parse(client, auth_headers)
    _log(client, auth_headers, _rename(client, auth_headers, parsed["parse_id"], "ground turkey"), "learn-2")
    again = _parse(client, auth_headers)
    assert again["items"][0]["name"] == "ground turkey"
    row = next(r for r in fake_db.tables["parses"] if r["id"] == again["parse_id"])
    assert row["payload"]["learned_names"] == [{"index": 0, "heard": "ground beef", "corrected": "ground turkey"}]
    assert row["payload"]["root_parse_id"] == again["parse_id"]
    assert row["payload"]["origin_indices"] == [0]
    # Logging the applied name unchanged teaches nothing new and is not a correction.
    logged = _log(client, auth_headers, again, "learn-3")
    assert logged["corrections_count"] == 0
    assert _learned(client, auth_headers)[0]["count"] == 1


def test_reverting_an_applied_rename_forgets_it(client, auth_headers):
    parsed = _parse(client, auth_headers)
    _log(client, auth_headers, _rename(client, auth_headers, parsed["parse_id"], "ground turkey"), "learn-4")
    again = _parse(client, auth_headers)
    assert again["items"][0]["name"] == "ground turkey"
    items = _confirmed_items(again)
    items[0]["name"] = "ground beef"
    resp = client.post(
        "/meals",
        json={"client_meal_id": "learn-5", "parse_id": again["parse_id"], "meal_type": "lunch", "items": items},
        headers=auth_headers,
    )
    assert resp.status_code == 201
    assert _learned(client, auth_headers) == []
    assert _parse(client, auth_headers)["items"][0]["name"] == "ground beef"


def test_forget_endpoint_unteaches_without_deleting(client, auth_headers, fake_db):
    parsed = _parse(client, auth_headers)
    _log(client, auth_headers, _rename(client, auth_headers, parsed["parse_id"], "ground turkey"), "learn-6")
    assert client.post("/meals/learned-names/forget", json={"heard": "nothing"}, headers=auth_headers).status_code == 404
    resp = client.post("/meals/learned-names/forget", json={"heard": "Ground Beef"}, headers=auth_headers)
    assert resp.status_code == 204
    assert _learned(client, auth_headers) == []
    fields = [r["field"] for r in fake_db.tables["corrections"]]
    assert fields.count("name") == 1
    assert fields.count("name_forget") == 1
    assert _parse(client, auth_headers)["items"][0]["name"] == "ground beef"
    # The forget row is bookkeeping, not an edit the person made to that meal.
    meal_id = fake_db.tables["corrections"][0]["meal_log_id"]
    assert client.get(f"/meals/{meal_id}", headers=auth_headers).json()["corrections_count"] == 1


def test_learned_names_are_owner_scoped(client, auth_headers, auth_headers_user_2):
    parsed = _parse(client, auth_headers)
    _log(client, auth_headers, _rename(client, auth_headers, parsed["parse_id"], "ground turkey"), "learn-7")
    assert _learned(client, auth_headers_user_2) == []
    assert _parse(client, auth_headers_user_2)["items"][0]["name"] == "ground beef"


def test_removal_then_rename_keeps_root_indices_straight(client, auth_headers, fake_db):
    parsed = _parse(client, auth_headers, transcript="burger, unknown beef, regular cheddar, mayo")
    assert len(parsed["items"]) >= 3
    removed = client.post(
        "/parse/refine",
        json={"parse_id": parsed["parse_id"], "answers": [{"field": "items[0].removed", "value": "true"}]},
        headers=auth_headers,
    ).json()
    renamed = _rename(client, auth_headers, removed["parse_id"], "wagyu beef")
    logged = _log(client, auth_headers, renamed, "learn-8")
    # Item 1 of the root became item 0 after the removal; its rename diffs against ITS root
    # item, so the rows are the refine-time removal (root item 0, item_removed) and the
    # rename (root item 1): the whole teaching, whichever step it happened in.
    assert logged["corrections_count"] == 2
    fields = sorted(r["field"] for r in fake_db.tables["corrections"])
    assert fields == ["item_removed", "name"]
    learned = _learned(client, auth_headers)
    assert [(e["heard"], e["corrected"]) for e in learned] == [(parsed["items"][1]["name"].lower(), "wagyu beef")]
