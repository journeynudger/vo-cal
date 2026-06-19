"""B6 + decision #29: /parse and /parse/refine (offline — FakeParserClient).

Per-material-ingredient checks: every ingredient whose unknown clears the
>75 kcal / >10 g threshold gets its own question (ordered, capped). A fully
specified meal asks nothing; answering supersedes with an immutable new row.
"""

from __future__ import annotations


def test_parse_requires_auth(client):
    resp = client.post("/parse", json={"transcript": "4oz 93/7 beef"})
    assert resp.status_code == 401


def test_parse_fully_specified_no_questions(client, auth_headers):
    resp = client.post("/parse", json={"transcript": "4oz 93/7 beef"}, headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["questions"] == []  # nothing material is unknown
    assert len(body["items"]) >= 1
    assert body["totals"]["kcal"] > 0
    assert body["meal_confidence"] > 0.8
    assert body["parse_id"]
    assert body["items"][0]["source"] == "dictionary"


def test_burger_fires_per_ingredient_checks(client, auth_headers):
    resp = client.post(
        "/parse",
        json={"transcript": "burger, unknown beef, regular cheddar, mayo"},
        headers=auth_headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    fields = [q["field"] for q in body["questions"]]
    # Multiple material checks fire (not the old one-per-meal cap).
    assert len(fields) >= 2
    # The unambiguously-material one — unknown beef fat ratio — is always present.
    assert any("fat_ratio" in f for f in fields)
    # Ordered highest-impact first; capped.
    assert len(fields) <= 4
    # The fat-ratio check carries quick-answer chips for the UI.
    fr = next(q for q in body["questions"] if "fat_ratio" in q["field"])
    assert fr["options"] is not None
    assert "93/7" in fr["options"]


def test_variant_check_fires_when_material(client, auth_headers):
    # A big pour of an unspecified-variant food (mayo, regular vs light) clears the
    # threshold — proves the engine-synthesized variant axis (decision #29) works.
    # (At one slice/tbsp a type swing is sub-threshold and correctly NOT asked.)
    resp = client.post(
        "/parse", json={"transcript": "three tablespoons of mayo"}, headers=auth_headers
    )
    assert resp.status_code == 200
    body = resp.json()
    variant_qs = [q for q in body["questions"] if q["field"].endswith(".variant")]
    assert variant_qs, body["questions"]
    assert variant_qs[0]["options"]  # regular / light / olive_oil chips


def test_refine_answers_checks_and_supersedes(client, auth_headers):
    parsed = client.post(
        "/parse",
        json={"transcript": "burger, unknown beef, regular cheddar, mayo"},
        headers=auth_headers,
    ).json()
    parse_id = parsed["parse_id"]
    answers = [
        {"field": q["field"], "value": (q["options"][0] if q.get("options") else 1)}
        for q in parsed["questions"]
    ]
    refined = client.post(
        "/parse/refine",
        json={"parse_id": parse_id, "answers": answers},
        headers=auth_headers,
    )
    assert refined.status_code == 200
    body = refined.json()
    # Every answered check is resolved → fewer (here zero) remaining.
    assert len(body["questions"]) < len(parsed["questions"])
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
