"""GET /foods/barcode/{code}: a packaged food from its barcode, offline.

The fixtures are authored in the providers' documented shapes, not recorded: FatSecret's
`food.find_id_for_barcode` has not been called live, and the Open Food Facts product is
written with the nutriment keys a real answer carries. Every HTTP call is an
httpx.MockTransport injected through the route's `get_barcode_transport` dependency.
"""

from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

from api.config import settings
from api.db import FakeDatabase, UniqueViolationError
from api.foods.barcode import (
    BarcodeFood,
    lookup_barcode,
    normalize_barcode,
    parse_openfoodfacts,
)
from api.foods.router import get_barcode_transport
from api.nutrition.fatsecret_client import API_URL, TOKEN_URL, FatSecretClient

_FIXTURES = Path(__file__).resolve().parent / "fixtures"
UPC_A = "850012345671"  # 12 digits, as printed on a US package
GTIN13 = "0850012345671"
OFF_HOST = "world.openfoodfacts.org"


def _load(*parts: str) -> dict:
    return json.loads(_FIXTURES.joinpath(*parts).read_text())


class Providers:
    """A recorded FatSecret and Open Food Facts behind one MockTransport, with a call log."""

    def __init__(
        self,
        *,
        find: dict | None = None,
        detail: str = "spanakopita_detail.json",
        off: httpx.Response | None = None,
        off_error: Exception | None = None,
    ) -> None:
        self.calls: list[str] = []
        self.off_requests: list[httpx.Request] = []
        self.find_bodies: list[str] = []
        self._find = find
        self._detail = detail
        self._off = off
        self._off_error = off_error
        self.transport = httpx.MockTransport(self._handle)

    def _handle(self, request: httpx.Request) -> httpx.Response:
        if str(request.url) == TOKEN_URL:
            self.calls.append("token")
            return httpx.Response(200, json=_load("fatsecret_responses", "token.json"))
        if str(request.url) == API_URL:
            body = request.read().decode()
            if "method=food.find_id_for_barcode" in body:
                self.calls.append("find")
                self.find_bodies.append(body)
                assert self._find is not None, "FatSecret was not expected to be asked"
                return httpx.Response(200, json=self._find)
            if "method=food.get.v4" in body:
                self.calls.append("detail")
                return httpx.Response(200, json=_load("fatsecret_responses", self._detail))
            raise AssertionError(body)
        if request.url.host == OFF_HOST:
            self.calls.append("off")
            self.off_requests.append(request)
            if self._off_error is not None:
                raise self._off_error
            assert self._off is not None, "Open Food Facts was not expected to be asked"
            return self._off
        raise AssertionError(f"unexpected request: {request.url}")


def _off_found() -> httpx.Response:
    return httpx.Response(200, json=_load("openfoodfacts", "oat_bar.json"))


def _off_missing() -> httpx.Response:
    return httpx.Response(404, json=_load("openfoodfacts", "not_found.json"))


@pytest.fixture(autouse=True)
def _fresh_token():
    FatSecretClient._token = None
    FatSecretClient._token_expires_at = 0.0
    yield
    FatSecretClient._token = None
    FatSecretClient._token_expires_at = 0.0


@pytest.fixture
def fatsecret_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "fatsecret_client_id", "id")
    monkeypatch.setattr(settings, "fatsecret_client_secret", "secret")


def _serve(app, providers: Providers) -> None:
    app.dependency_overrides[get_barcode_transport] = lambda: providers.transport


# -- pure --------------------------------------------------------------------------


def test_normalize_barcode_pads_to_a_gtin_and_rejects_what_is_not_one() -> None:
    assert normalize_barcode(UPC_A) == GTIN13  # UPC-A: 12 digits pad to 13
    assert normalize_barcode("96385074") == "0000096385074"  # EAN-8
    assert normalize_barcode(GTIN13) == GTIN13
    assert normalize_barcode("0 850012-345 671") == GTIN13  # spaces and dashes stripped
    assert normalize_barcode("10850012345678") == "10850012345678"  # GTIN-14 keeps its form
    assert normalize_barcode("abc") is None
    assert normalize_barcode("85001234567a") is None  # a letter anywhere
    assert normalize_barcode("1234567") is None  # 7 digits
    assert normalize_barcode("123456789012345") is None  # 15 digits
    assert normalize_barcode("") is None
    assert normalize_barcode("٨٥٠٠١٢٣٤٥٦٧١") is None  # Arabic-Indic digits are not digits here


def test_open_food_facts_scales_per_100g_to_the_stated_serving() -> None:
    food = parse_openfoodfacts(_load("openfoodfacts", "oat_bar.json"), GTIN13)
    assert food is not None
    assert (food.name, food.brand, food.source) == ("Oat & Almond Bar", "Bite Best", "openfoodfacts")
    assert food.serving_description == "1 bar (50 g)"
    assert food.serving_grams == 50.0
    assert food.per_serving.kcal == 210.0
    assert (food.per_serving.protein, food.per_serving.carbs, food.per_serving.fat) == (5.0, 27.0, 9.0)
    assert food.per_serving.fiber == 4.0
    assert food.per_serving.sugar_g == 11.0
    assert food.per_serving.sodium_mg == 80.0  # sodium_100g is grams: 0.16 g per 100 g, half a bar
    assert food.per_100g is not None
    assert food.per_100g.kcal == 420.0
    assert food.per_100g.sodium_mg == 160.0


def _off(nutriments: dict, **product: object) -> dict:
    return {
        "status": 1,
        "product": {"product_name": "Plain Crackers", "nutriments": nutriments, **product},
    }


def test_open_food_facts_without_a_serving_weight_uses_the_labels_serving_values() -> None:
    payload = _off(
        {"energy-kcal_serving": 130, "proteins_serving": 2, "carbohydrates_serving": 22, "fat_serving": 4},
        serving_size="6 crackers",
    )
    food = parse_openfoodfacts(payload, GTIN13)
    assert food is not None
    assert food.per_serving.kcal == 130.0
    assert food.serving_grams is None
    assert food.serving_description == "6 crackers"
    assert food.per_100g is None
    assert food.per_serving.sugar_g is None  # not stated is None, never 0


def test_open_food_facts_with_only_per_100g_is_a_100g_serving() -> None:
    food = parse_openfoodfacts(_off({"energy-kcal_100g": 380, "proteins_100g": 9}), GTIN13)
    assert food is not None
    assert food.serving_description == "100 g"
    assert food.per_serving == food.per_100g
    assert food.per_serving.kcal == 380.0


def test_open_food_facts_reads_kilojoules_when_kcal_is_absent() -> None:
    food = parse_openfoodfacts(_off({"energy_100g": 1674}), GTIN13)
    assert food is not None
    assert food.per_serving.kcal == 400.1  # 1674 kJ / 4.184


@pytest.mark.parametrize(
    "payload",
    [
        {"status": 0, "status_verbose": "product not found"},
        _off({"proteins_100g": 5}),  # no energy anywhere
        _off({}),
        {"status": 1, "product": {"product_name": "   ", "nutriments": {"energy-kcal_100g": 100}}},
        {"status": 1, "product": {"nutriments": {"energy-kcal_100g": 100}}},
        _off({"energy-kcal_100g": 3700}),  # a kJ figure in the kcal field: pure fat is 900
        _off({"energy-kcal_100g": 100, "proteins_100g": -4}),
        _off({"energy-kcal_100g": "n/a"}),
        ["not", "an", "object"],
    ],
)
def test_open_food_facts_unusable_products_are_misses(payload: object) -> None:
    assert parse_openfoodfacts(payload, GTIN13) is None


def test_open_food_facts_a_zero_calorie_product_is_a_food() -> None:
    food = parse_openfoodfacts(_off({"energy-kcal_100g": 0}, serving_quantity="355", serving_quantity_unit="ml"), GTIN13)
    assert food is not None  # sparkling water: "no kcal" means not stated, 0 is a stated 0
    assert food.per_serving.kcal == 0.0
    assert food.serving_description == "355 ml"


# -- route -------------------------------------------------------------------------


def test_fatsecret_hit_reads_the_label_food_and_the_second_scan_is_cached(
    client, app, auth_headers, fake_db, fatsecret_credentials
) -> None:
    providers = Providers(find=_load("fatsecret_responses", "barcode_find.json"))
    _serve(app, providers)

    first = client.get(f"/foods/barcode/{UPC_A}", headers=auth_headers)

    assert first.status_code == 200, first.text
    assert first.json() == {
        "barcode": GTIN13,
        "name": "Spanakopita",
        "brand": "Athens",
        "per_serving": {
            "kcal": 140.0,
            "protein": 4.0,
            "carbs": 15.0,
            "fat": 7.0,
            "fiber": 1.0,
            "sugar_g": 1.0,
            "sodium_mg": 230.0,
        },
        "serving_grams": 56.0,
        "serving_description": "2 pieces",
        "per_100g": {
            "kcal": 250.0,
            "protein": 7.143,
            "carbs": 26.786,
            "fat": 12.5,
            "fiber": 1.786,
            "sugar_g": 1.786,
            "sodium_mg": 410.714,
        },
        "source": "fatsecret",
    }
    assert providers.calls == ["token", "find", "detail"]
    # The 12-digit UPC-A reaches FatSecret as a 13-digit GTIN.
    assert f"barcode={GTIN13}" in providers.find_bodies[0]
    row = fake_db.tables["usda_cache"][0]
    assert row["query_key"] == f"bc:{GTIN13}"
    assert row["fdc_id"] == 4678723
    assert row["profile"]["provider"] == "fatsecret"
    assert row["profile"]["name"] == "Spanakopita"

    second = client.get(f"/foods/barcode/{UPC_A}", headers=auth_headers)

    assert second.json() == first.json()
    assert providers.calls == ["token", "find", "detail"]  # the cache answered: zero new calls


def test_a_cache_hit_makes_no_http_call_and_serves_the_scanned_form(
    client, app, auth_headers
) -> None:
    providers = Providers(off=_off_found())
    _serve(app, providers)
    assert client.get(f"/foods/barcode/{UPC_A}", headers=auth_headers).status_code == 200
    assert providers.calls == ["off"]

    again = client.get(f"/foods/barcode/{GTIN13}", headers=auth_headers)

    assert again.status_code == 200
    assert again.json()["barcode"] == GTIN13
    assert again.json()["name"] == "Oat & Almond Bar"
    assert providers.calls == ["off"]


def test_fatsecret_miss_falls_back_to_open_food_facts(
    client, app, auth_headers, fake_db, fatsecret_credentials
) -> None:
    providers = Providers(find={"food_id": {"value": "0"}}, off=_off_found())
    _serve(app, providers)

    resp = client.get(f"/foods/barcode/{UPC_A}", headers=auth_headers)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["source"] == "openfoodfacts"
    assert (body["name"], body["brand"]) == ("Oat & Almond Bar", "Bite Best")
    assert body["serving_description"] == "1 bar (50 g)"
    assert body["per_serving"]["kcal"] == 210.0
    assert providers.calls == ["token", "find", "off"]  # no food.get.v4 for an id of 0
    request = providers.off_requests[0]
    assert request.url.path == f"/api/v2/product/{UPC_A}.json"
    assert request.url.params["fields"] == (
        "product_name,brands,nutriments,serving_size,serving_quantity,serving_quantity_unit"
    )
    assert request.headers["user-agent"] == "VoCal/0.1 (https://vo-cal.fly.dev)"
    row = fake_db.tables["usda_cache"][0]
    assert row["query_key"] == f"bc:{GTIN13}"
    assert row["fdc_id"] is None
    assert row["profile"]["provider"] == "openfoodfacts"


def test_without_credentials_only_open_food_facts_is_asked(client, app, auth_headers) -> None:
    providers = Providers(off=_off_found())
    _serve(app, providers)

    assert client.get(f"/foods/barcode/{UPC_A}", headers=auth_headers).status_code == 200

    assert providers.calls == ["off"]  # not even a token request


def test_both_providers_missing_is_a_404_and_nothing_is_cached(
    client, app, auth_headers, fake_db, fatsecret_credentials
) -> None:
    providers = Providers(find={"food_id": {"value": "0"}}, off=_off_missing())
    _serve(app, providers)

    resp = client.get(f"/foods/barcode/{UPC_A}", headers=auth_headers)

    assert resp.status_code == 404
    assert resp.json()["detail"] == "no food found for that barcode"
    assert fake_db.tables["usda_cache"] == []


@pytest.mark.parametrize("code", ["abc", "12345", "1234567890123456", "85001234567a"])
def test_a_malformed_code_is_a_422(client, app, auth_headers, code) -> None:
    providers = Providers()  # any provider call would fail the test
    _serve(app, providers)

    resp = client.get(f"/foods/barcode/{code}", headers=auth_headers)

    assert resp.status_code == 422
    assert resp.json()["detail"] == "a barcode is 8 to 14 digits"
    assert providers.calls == []


def test_spaces_and_dashes_in_the_path_are_stripped(client, app, auth_headers) -> None:
    _serve(app, Providers(off=_off_found()))

    resp = client.get("/foods/barcode/8-5001 2345671", headers=auth_headers)

    assert resp.status_code == 200
    assert resp.json()["barcode"] == GTIN13


def test_a_barcode_lookup_needs_a_signed_in_user(client, app) -> None:
    providers = Providers(off=_off_found())
    _serve(app, providers)

    assert client.get(f"/foods/barcode/{UPC_A}").status_code == 401
    assert providers.calls == []


def test_provider_failures_are_a_404_never_a_500(
    client, app, auth_headers, fatsecret_credentials
) -> None:
    unknown = {"error": {"code": 211, "message": "No food item detected for the specified barcode"}}
    _serve(app, Providers(find=unknown, off_error=httpx.ConnectTimeout("slow")))

    resp = client.get(f"/foods/barcode/{UPC_A}", headers=auth_headers)

    assert resp.status_code == 404


def test_open_food_facts_server_error_is_a_miss(client, app, auth_headers) -> None:
    _serve(app, Providers(off=httpx.Response(503, text="maintenance")))

    assert client.get(f"/foods/barcode/{UPC_A}", headers=auth_headers).status_code == 404


def test_a_fatsecret_error_still_falls_back_to_open_food_facts(
    client, app, auth_headers, fatsecret_credentials
) -> None:
    refused = {"error": {"code": 14, "message": "Missing required scope"}}
    providers = Providers(find=refused, off=_off_found())
    _serve(app, providers)

    resp = client.get(f"/foods/barcode/{UPC_A}", headers=auth_headers)

    assert resp.status_code == 200
    assert resp.json()["source"] == "openfoodfacts"
    assert providers.calls == ["token", "find", "off"]


def test_a_logged_lookup_names_neither_the_code_nor_the_product(
    client, app, auth_headers, caplog
) -> None:
    _serve(app, Providers(off=_off_found()))
    caplog.set_level("INFO", logger="api.foods.barcode")

    client.get(f"/foods/barcode/{UPC_A}", headers=auth_headers)

    lines = [r.getMessage() for r in caplog.records if r.name == "api.foods.barcode"]
    assert lines == ["barcode lookup: digits=12 provider=openfoodfacts cache=miss"]


# -- cache -------------------------------------------------------------------------


async def test_a_corrupt_cache_row_is_a_miss_that_is_replaced_in_place() -> None:
    db = FakeDatabase()
    await db.insert("usda_cache", {"query_key": f"bc:{GTIN13}", "fdc_id": None, "profile": {"provider": "x"}})
    providers = Providers(off=_off_found())

    food = await lookup_barcode(db, UPC_A, fatsecret=None, transport=providers.transport)

    assert food is not None
    assert providers.calls == ["off"]
    rows = db.tables["usda_cache"]
    assert len(rows) == 1
    assert rows[0]["profile"]["name"] == "Oat & Almond Bar"
    assert BarcodeFood.model_validate(rows[0]["profile"]).source == "openfoodfacts"

    providers.calls.clear()
    assert await lookup_barcode(db, UPC_A, fatsecret=None, transport=providers.transport) == food
    assert providers.calls == []  # the replaced row now answers


async def test_losing_the_cache_insert_race_still_answers() -> None:
    class RacedDatabase(FakeDatabase):
        async def insert(self, table, row, **kwargs):
            raise UniqueViolationError("another scan filled it first")

    providers = Providers(off=_off_found())
    food = await lookup_barcode(RacedDatabase(), UPC_A, fatsecret=None, transport=providers.transport)

    assert food is not None
    assert food.name == "Oat & Almond Bar"


async def test_an_unweighed_fatsecret_serving_offers_no_per_100g() -> None:
    db = FakeDatabase()
    providers = Providers(find={"food_id": {"value": "9"}}, detail="bigmac_detail.json")
    client = FatSecretClient(
        db, client_id="id", client_secret="secret", transport=providers.transport
    )

    food = await lookup_barcode(db, UPC_A, fatsecret=client, transport=providers.transport)

    assert food is not None
    assert food.source == "fatsecret"
    assert food.serving_grams is None
    assert food.per_serving.kcal == 580.0
    assert food.per_100g is None  # the serving is not a per-100 g figure


# -- saving a scanned food ---------------------------------------------------------

LABEL = {
    "name": "Oat & Almond Bar",
    "per_serving": {"kcal": 210, "protein": 5, "carbs": 27, "fat": 9, "fiber": 4},
    "serving_grams": 50,
}


def test_a_label_saved_from_a_scan_keeps_its_barcode_and_brand(
    client, auth_headers, fake_db
) -> None:
    resp = client.post(
        "/foods/personal",
        json={**LABEL, "barcode": GTIN13, "brand": "Bite Best"},
        headers=auth_headers,
    )

    assert resp.status_code == 201, resp.text
    assert resp.json()["source"] == "label"
    row = fake_db.tables["personal_foods"][0]
    assert row["source"] == "label"
    assert row["provenance"] == {"barcode": GTIN13, "brand": "Bite Best"}


def test_a_typed_label_has_no_provenance_as_before(client, auth_headers, fake_db) -> None:
    resp = client.post("/foods/personal", json=LABEL, headers=auth_headers)

    assert resp.status_code == 201, resp.text
    assert fake_db.tables["personal_foods"][0]["provenance"] is None


def test_the_barcode_and_brand_have_length_caps(client, auth_headers) -> None:
    too_long_code = {**LABEL, "barcode": "1" * 15}
    too_long_brand = {**LABEL, "brand": "b" * 81}

    assert client.post("/foods/personal", json=too_long_code, headers=auth_headers).status_code == 422
    assert client.post("/foods/personal", json=too_long_brand, headers=auth_headers).status_code == 422


async def test_an_unknown_code_is_logged_as_a_routine_miss_not_a_warning(caplog) -> None:
    unknown = {"error": {"code": 211, "message": "No food item detected for the specified barcode"}}
    providers = Providers(find=unknown)
    client = FatSecretClient(
        FakeDatabase(), client_id="id", client_secret="secret", transport=providers.transport
    )

    assert await client.resolve_barcode(GTIN13) is None

    assert providers.calls == ["token", "find"]
    assert not [r for r in caplog.records if r.levelname == "WARNING"]
