"""Decision 73: the drafted meal plan's endpoints. Offline (FakeDatabase, recorded fixtures).

Proves: POST /meals/plan/generate drafts the day the person described from the foods they
named, priced on the confirm path and checked, and never stores it; additions only when
allowed; a name nothing prices is reported, not invented; the draft saves through PUT
/meals/plan like any plan. GET /meals/plan/foods offers what the person logs most. POST
/meals/plan/receipt reads a receipt into names and refuses what is not an image.
"""

from __future__ import annotations

from .conftest import confirmed_items, parse_transcript

JPEG = b"\xff\xd8\xff" + b"\x00" * 64

INTAKE = {
    "age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0,
    "goal": "cut", "work": "desk", "train": "moderate", "kids": False,
    "med": "none", "stress": "moderate",
}

FOODS = [
    "chicken breast", "salmon", "egg", "greek yogurt", "white rice", "oatmeal",
    "broccoli", "green beans", "blueberries", "banana", "olive oil", "dark chocolate",
]


def _protocol(client, headers) -> None:
    client.post("/intake", json={"intake": INTAKE}, headers=headers)
    assert client.post("/protocols/generate", json={"intake": INTAKE}, headers=headers).status_code in (200, 201)


def test_generate_requires_auth(client):
    assert client.post("/meals/plan/generate", json={"meals": 3}).status_code == 401
    assert client.get("/meals/plan/foods").status_code == 401
    assert client.post("/meals/plan/receipt", files={"photo": ("r.jpg", JPEG, "image/jpeg")}).status_code == 401


def test_generate_needs_a_protocol(client, auth_headers):
    resp = client.post("/meals/plan/generate", json={"meals": 3, "foods": FOODS}, headers=auth_headers)
    assert resp.status_code == 422


def test_generate_drafts_a_checked_day_and_stores_nothing(client, auth_headers):
    _protocol(client, auth_headers)
    resp = client.post(
        "/meals/plan/generate",
        json={"meals": 3, "snacks": 1, "dessert": True, "foods": FOODS, "may_add": False},
        headers=auth_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert [s["label"] for s in body["slots"]] == ["Breakfast", "Snack", "Lunch", "Dinner", "Dessert"]
    for slot in body["slots"]:
        assert slot["items"], slot
        assert slot["totals"]["kcal"] > 0
        assert slot["name"]
    assert body["check"] is not None
    assert body["check"]["kcal_within"] is True, body["check"]
    assert body["check"]["protein_ok"] is True, body["check"]
    assert body["added"] == []
    # A draft is a draft: nothing was written.
    assert client.get("/meals/plan", headers=auth_headers).status_code == 404


def test_generate_adds_only_when_allowed(client, auth_headers):
    _protocol(client, auth_headers)
    few = ["white rice", "broccoli"]
    alone = client.post("/meals/plan/generate", json={"meals": 3, "foods": few}, headers=auth_headers).json()
    placed = {i["name"] for s in alone["slots"] for i in s["items"]}
    assert placed <= set(few)
    assert alone["added"] == []
    helped = client.post("/meals/plan/generate", json={"meals": 3, "foods": few, "may_add": True}, headers=auth_headers).json()
    assert helped["added"]
    assert helped["check"]["protein_ok"] is True


def test_generate_refuses_nothing_to_build_from(client, auth_headers):
    _protocol(client, auth_headers)
    resp = client.post("/meals/plan/generate", json={"meals": 3, "foods": [], "may_add": False}, headers=auth_headers)
    assert resp.status_code == 422
    assert client.post("/meals/plan/generate", json={"meals": 7}, headers=auth_headers).status_code == 422


def test_generate_reports_a_name_nothing_prices(client, auth_headers):
    _protocol(client, auth_headers)
    body = client.post(
        "/meals/plan/generate",
        json={"meals": 3, "foods": [*FOODS, "zzqx flarb"], "may_add": False},
        headers=auth_headers,
    ).json()
    assert body["unpriced"] == ["zzqx flarb"]
    assert all(i["name"] != "zzqx flarb" for s in body["slots"] for i in s["items"])


def test_a_draft_saves_like_any_plan(client, auth_headers):
    _protocol(client, auth_headers)
    draft = client.post(
        "/meals/plan/generate", json={"meals": 3, "foods": FOODS}, headers=auth_headers
    ).json()
    saved = client.put(
        "/meals/plan",
        json={"slots": [{"name": s["name"], "items": s["items"]} for s in draft["slots"]]},
        headers=auth_headers,
    )
    assert saved.status_code == 200, saved.text
    plan = saved.json()
    assert [s["name"] for s in plan["slots"]] == [s["name"] for s in draft["slots"]]
    assert plan["check"]["line"] == draft["check"]["line"]


def test_plan_foods_offers_what_the_person_logs_most(client, auth_headers, auth_headers_user_2):
    for n in range(2):
        parsed = parse_transcript(client, auth_headers, "some chicken and some rice")
        client.post("/meals", json={"client_meal_id": f"m-pf-{n}", "parse_id": parsed["parse_id"], "items": confirmed_items(parsed)}, headers=auth_headers)
    foods = client.get("/meals/plan/foods", headers=auth_headers).json()
    assert foods
    assert any("chicken" in f.lower() for f in foods)
    assert client.get("/meals/plan/foods", headers=auth_headers_user_2).json() == []


def test_receipt_reads_names_only(client, auth_headers):
    resp = client.post("/meals/plan/receipt", files={"photo": ("r.jpg", JPEG, "image/jpeg")}, headers=auth_headers)
    assert resp.status_code == 200, resp.text
    foods = resp.json()["foods"]
    assert "Chicken breast" in foods
    assert "   " not in foods
    assert all(f.strip() == f for f in foods)
    assert len({f.lower() for f in foods}) == len(foods)


def test_receipt_refuses_what_is_not_an_image(client, auth_headers):
    not_jpeg = client.post("/meals/plan/receipt", files={"photo": ("r.jpg", b"hello", "image/jpeg")}, headers=auth_headers)
    assert not_jpeg.status_code == 415
    pdf = client.post("/meals/plan/receipt", files={"photo": ("r.pdf", b"%PDF-1.4", "application/pdf")}, headers=auth_headers)
    assert pdf.status_code == 415


def test_foods_that_fill_no_meal_are_a_422_never_an_empty_draft(client, auth_headers):
    # An empty day came back as a 200 and the builder replaced the person's rows with nothing.
    _protocol(client, auth_headers)
    resp = client.post(
        "/meals/plan/generate",
        json={"meals": 3, "snacks": 0, "dessert": False, "foods": ["ketchup", "water"], "may_add": False},
        headers=auth_headers,
    )
    assert resp.status_code == 422, resp.text


def test_a_food_name_longer_than_any_food_is_refused(client, auth_headers):
    _protocol(client, auth_headers)
    body = {"meals": 3, "snacks": 0, "dessert": False, "foods": ["chicken breast", "x" * 201], "may_add": True}
    assert client.post("/meals/plan/generate", json=body, headers=auth_headers).status_code == 422
