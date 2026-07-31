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


def test_parse_response_items_include_is_estimate(client, auth_headers):
    # The iOS ParseResultItem decode requires `is_estimate`; the response MUST carry it.
    # Regression: its absence threw keyNotFound on every live parse → "Couldn't analyze the meal."
    resp = client.post("/parse", json={"transcript": "4oz 93/7 beef"}, headers=auth_headers)
    assert resp.status_code == 200
    item = resp.json()["items"][0]
    assert "is_estimate" in item
    assert item["is_estimate"] is False  # a dictionary hit is a real resolution, not an estimate


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
    # And the cofounder-driven type checks: cheddar / mayo variant on the lower bar.
    assert any(f.endswith(".variant") for f in fields)
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


def _seed_capture(fake_db, *, owner) -> str:
    """Insert a minimal owned capture row and return its server UUID."""
    import uuid

    capture_id = str(uuid.uuid4())
    fake_db.tables.setdefault("captures", []).append(
        {"id": capture_id, "user_id": str(owner), "audio_path": f"{owner}/x.caf", "status": "uploaded"}
    )
    return capture_id


def test_parse_capture_id_must_be_uuid_or_null(client, auth_headers, fake_db, test_user_id):
    # Provenance contract the live client must honor: /parse links to the capture by its SERVER
    # UUID (returned by POST /captures), not the client's `voice_<ts>_<hex>` capture id.
    # ParseRequest.capture_id is UUID | None — a valid OWNED UUID and null are accepted; a client
    # capture id is a 422. This is the exact mismatch that broke the live capture->parse chain
    # before the iOS service threaded the server UUID through (the mock path sends null).
    owned = _seed_capture(fake_db, owner=test_user_id)
    ok = client.post(
        "/parse",
        json={"transcript": "4oz 93/7 beef", "capture_id": owned},
        headers=auth_headers,
    )
    assert ok.status_code == 200, ok.text

    null_ok = client.post(
        "/parse",
        json={"transcript": "4oz 93/7 beef", "capture_id": None},
        headers=auth_headers,
    )
    assert null_ok.status_code == 200, null_ok.text

    bad = client.post(
        "/parse",
        json={"transcript": "4oz 93/7 beef", "capture_id": "voice_1730000000_abcdef"},
        headers=auth_headers,
    )
    assert bad.status_code == 422


def test_parse_rejects_capture_id_the_caller_does_not_own(
    client, auth_headers, fake_db, test_user_2_id
):
    # IDOR: a parse must not LINK to a capture the caller doesn't own. The admin audit chain
    # follows parse.capture_id UNSCOPED to mint a signed audio URL, so linking user B's capture
    # into user A's parse would serve B's audio under A's review. A provided capture_id must
    # reference a capture owned by the caller; otherwise 404 (owner-scoped, no existence oracle).
    import uuid

    foreign = _seed_capture(fake_db, owner=test_user_2_id)
    resp = client.post(
        "/parse",
        json={"transcript": "4oz 93/7 beef", "capture_id": foreign},
        headers=auth_headers,
    )
    assert resp.status_code == 404, resp.text

    # A well-formed UUID that references no capture at all is also rejected (not silently linked).
    nonexistent = client.post(
        "/parse",
        json={"transcript": "4oz 93/7 beef", "capture_id": str(uuid.uuid4())},
        headers=auth_headers,
    )
    assert nonexistent.status_code == 404, nonexistent.text


def test_parse_response_carries_certainty_block(client, auth_headers):
    # The confidence-aware layer (certainty.py): every parse gets a score, calm label,
    # category, and coaching fields. Additive — old clients ignore it.
    resp = client.post("/parse", json={"transcript": "4oz 93/7 beef"}, headers=auth_headers)
    assert resp.status_code == 200
    certainty = resp.json()["certainty"]
    assert certainty is not None
    assert 5 <= certainty["score"] <= 99
    assert certainty["label"] in (
        "rough_estimate", "limited_detail", "good_estimate", "high_confidence"
    )
    assert certainty["category"] == "meat_seafood"
    assert isinstance(certainty["tips"], list)
    assert len(certainty["tips"]) <= 3


def test_refine_raises_certainty_score(client, auth_headers):
    # The "37% -> 61%" moment: answering the engine's checks must visibly raise the score.
    parsed = client.post(
        "/parse",
        json={"transcript": "burger, unknown beef, regular cheddar, mayo"},
        headers=auth_headers,
    ).json()
    before = parsed["certainty"]["score"]
    answers = [
        {"field": q["field"], "value": (q["options"][0] if q.get("options") else 1)}
        for q in parsed["questions"]
    ]
    refined = client.post(
        "/parse/refine",
        json={"parse_id": parsed["parse_id"], "answers": answers},
        headers=auth_headers,
    ).json()
    assert refined["certainty"]["score"] > before


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


# -- restaurant menu items: the 234-kcal Big Mac regression (field bug 2026-07-19) --
# "I had a Big Mac and a Sprite" logged 234 + 40 kcal — each item's per-100g row
# shipped as the item total (null amount priced as a hardcoded 100 g through FDC).
# The full-pipeline contract now: an informed estimate prices the WHOLE item, and
# when nothing can price it honestly the item is unresolved at 0 kcal with the
# missing-detail flow — never a confident per-100g guess.


def _restaurant_estimator():
    from api.nutrition.estimator import EstimatedFood
    from api.nutrition.schemas import NutrientProfile
    from tests.test_estimator import FakeEstimator

    return FakeEstimator(
        {
            "big mac": EstimatedFood(
                per_100g=NutrientProfile(kcal=270.0, protein=11.6, carbs=20.9, fat=15.8, fiber=1.6),
                serving_grams=215.0,
                kcal_per_serving=580.0,
            ),
            "sprite": EstimatedFood(
                per_100g=NutrientProfile(kcal=40.0, protein=0.0, carbs=10.1, fat=0.0, fiber=0.0),
                serving_grams=355.0,
                unit_conversions={"ml": 1.0},
                kcal_per_serving=142.0,
            ),
        }
    )


def test_big_mac_and_sprite_price_as_whole_items(app, client, auth_headers):
    from api.nutrition.resolver import Resolver
    from api.parser.router import get_resolver

    app.dependency_overrides[get_resolver] = lambda: Resolver(
        fdc=None, estimator=_restaurant_estimator()
    )
    resp = client.post(
        "/parse", json={"transcript": "I had a Big Mac and a Sprite"}, headers=auth_headers
    )
    assert resp.status_code == 200
    body = resp.json()
    by_name = {i["name"]: i for i in body["items"]}
    big_mac, sprite = by_name["Big Mac"], by_name["Sprite"]
    # The whole sandwich (~215 g / ~580 kcal), never 100 g of it (234 kcal).
    assert big_mac["grams"] == 215.0
    assert abs(big_mac["macros"]["kcal"] - 580) < 10
    assert big_mac["is_estimate"] is True
    # The whole drink serving, never 100 ml of it (40 kcal).
    assert sprite["grams"] == 355.0
    assert abs(sprite["macros"]["kcal"] - 142) < 5
    assert abs(body["totals"]["kcal"] - 722) < 15


def test_big_mac_with_nothing_to_price_is_honestly_unresolved(app, client, auth_headers):
    # Estimator down/declining + FDC unable to price a bare mention: the item must
    # surface as unresolved (0 kcal, correctable) — not as a 100 g per-100g guess.
    from api.nutrition.resolver import Resolver
    from api.parser.router import get_resolver

    app.dependency_overrides[get_resolver] = lambda: Resolver(fdc=None, estimator=None)
    resp = client.post(
        "/parse", json={"transcript": "I had a Big Mac and a Sprite"}, headers=auth_headers
    )
    assert resp.status_code == 200
    body = resp.json()
    for item in body["items"]:
        assert item["source"] == "unresolved"
        assert item["macros"]["kcal"] == 0.0
    assert body["totals"]["kcal"] == 0.0


def test_refine_removal_drops_item_and_persists(client, auth_headers):
    # Deletion is a first-class refine op: a client-local delete was resurrected by the
    # NEXT refine (which re-resolved the original parse), and edit indices drifted.
    parsed = client.post(
        "/parse",
        json={"transcript": "burger, unknown beef, regular cheddar, mayo"},
        headers=auth_headers,
    ).json()
    names = [i["name"] for i in parsed["items"]]
    assert len(names) >= 3
    refined = client.post(
        "/parse/refine",
        json={"parse_id": parsed["parse_id"], "answers": [{"field": "items[1].removed", "value": "true"}]},
        headers=auth_headers,
    ).json()
    remaining = [i["name"] for i in refined["items"]]
    assert len(remaining) == len(names) - 1
    assert names[1] not in remaining
    # A SECOND refine on the superseding parse must not resurrect the removed item.
    again = client.post(
        "/parse/refine",
        json={"parse_id": refined["parse_id"], "answers": [{"field": "items[0].state", "value": "cooked"}]},
        headers=auth_headers,
    ).json()
    assert names[1] not in [i["name"] for i in again["items"]]


def test_refine_removing_every_item_is_422(client, auth_headers):
    parsed = client.post(
        "/parse",
        json={"transcript": "burger, unknown beef, regular cheddar, mayo"},
        headers=auth_headers,
    ).json()
    n = len(parsed["items"])
    answers = [{"field": f"items[{i}].removed", "value": "true"} for i in range(n)]
    resp = client.post(
        "/parse/refine",
        json={"parse_id": parsed["parse_id"], "answers": answers},
        headers=auth_headers,
    )
    assert resp.status_code == 422
