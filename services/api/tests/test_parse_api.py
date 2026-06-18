"""B6: /parse and /parse/refine endpoint tests (offline — FakeParserClient).

Exercises the full orchestration: transcript -> parse -> resolve -> confidence
-> clarify -> persisted immutable parses row. The canonical four drive the
ask/no-ask behavior; refine appends a superseding row.
"""

from __future__ import annotations


def test_parse_requires_auth(client):
    resp = client.post("/parse", json={"transcript": "4oz 93/7 beef"})
    assert resp.status_code == 401


def test_parse_fully_specified_no_question(client, auth_headers):
    resp = client.post("/parse", json={"transcript": "4oz 93/7 beef"}, headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["question"] is None
    assert len(body["items"]) >= 1
    assert body["totals"]["kcal"] > 0
    assert body["meal_confidence"] > 0.8
    assert body["parse_id"]
    assert body["items"][0]["source"] == "dictionary"


def test_parse_unknown_beef_fires_one_question(client, auth_headers):
    resp = client.post(
        "/parse",
        json={"transcript": "burger, unknown beef, regular cheddar, mayo"},
        headers=auth_headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["question"] is not None
    assert "fat_ratio" in body["question"]["field"]


def test_refine_resolves_question_and_supersedes(client, auth_headers):
    parsed = client.post(
        "/parse",
        json={"transcript": "burger, unknown beef, regular cheddar, mayo"},
        headers=auth_headers,
    ).json()
    parse_id = parsed["parse_id"]
    question = parsed["question"]
    assert question is not None

    refined = client.post(
        "/parse/refine",
        json={"parse_id": parse_id, "answers": [{"field": question["field"], "value": "93/7"}]},
        headers=auth_headers,
    )
    assert refined.status_code == 200
    body = refined.json()
    assert body["question"] is None
    assert body["supersedes"] == parse_id
    assert body["parse_id"] != parse_id


def test_refine_other_user_cannot_touch_parse(client, auth_headers, auth_headers_user_2):
    parsed = client.post(
        "/parse",
        json={"transcript": "burger, unknown beef, regular cheddar, mayo"},
        headers=auth_headers,
    ).json()
    resp = client.post(
        "/parse/refine",
        json={
            "parse_id": parsed["parse_id"],
            "answers": [{"field": "items[1].fat_ratio", "value": "93/7"}],
        },
        headers=auth_headers_user_2,
    )
    assert resp.status_code == 404
