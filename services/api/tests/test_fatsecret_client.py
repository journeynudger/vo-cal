"""FatSecret client: recorded-shape fixtures, the relevance gate, serving maths, the cache,
and degradation (error 21 for an unlisted IP is a miss, never a 500).

No live HTTP here; the live path runs behind the ``live_fatsecret`` marker once the caller
IP is allow-listed (scripts/food-source-eval).
"""

from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

from api.db import FakeDatabase
from api.nutrition.fatsecret_client import (
    API_URL,
    TOKEN_URL,
    FatSecretClient,
    build_result,
    rank_candidates,
)
from api.nutrition.resolver import Resolver
from api.nutrition.schemas import MatchKind, ResolutionSource
from api.parser.schemas import ParsedItem, Unit

_FIXTURES = Path(__file__).resolve().parent / "fixtures" / "fatsecret_responses"


def _load(name: str) -> dict:
    return json.loads((_FIXTURES / name).read_text())


def _transport(call_log: list[str], *, search: dict, detail: dict, error: dict | None = None) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        body = request.read().decode()
        if str(request.url) == TOKEN_URL:
            call_log.append("token")
            return httpx.Response(200, json=_load("token.json"))
        assert str(request.url) == API_URL
        if error is not None:
            call_log.append("error")
            return httpx.Response(200, json=error)
        if "method=foods.search" in body:
            call_log.append("search")
            return httpx.Response(200, json=search)
        if "method=food.get.v4" in body:
            call_log.append("detail")
            return httpx.Response(200, json=detail)
        raise AssertionError(body)

    return httpx.MockTransport(handler)


@pytest.fixture(autouse=True)
def _fresh_token():
    FatSecretClient._token = None
    FatSecretClient._token_expires_at = 0.0
    yield
    FatSecretClient._token = None
    FatSecretClient._token_expires_at = 0.0


def _item(name: str, amount: float | None = None, unit: Unit | None = None, brand: str | None = None) -> ParsedItem:
    return ParsedItem(name=name, amount=amount, unit=unit, brand=brand, confidence=0.9)


# -- pure --------------------------------------------------------------------------


def test_build_result_uses_the_100g_serving_and_extracts_conversions() -> None:
    result = build_result(_load("spanakopita_detail.json")["food"])
    assert result is not None
    assert result.per_100g.kcal == 261.0
    assert result.per_100g.protein == 8.1
    assert result.serving_grams == 143.0  # the default serving, one piece
    assert result.serving_description == "1 piece"
    assert result.unit_conversions == {"piece": 143.0, "cup": 220.0}
    assert result.brand is None
    assert result.food_type == "Generic"


def test_build_result_scales_a_weighed_serving_when_no_100g_row() -> None:
    food = _load("spanakopita_detail.json")["food"]
    food["servings"]["serving"] = [food["servings"]["serving"][0]]  # one piece, 143 g
    result = build_result(food)
    assert result is not None
    assert result.per_100g.kcal == round(373 * 100 / 143, 3)


def test_build_result_unweighed_restaurant_serving() -> None:
    result = build_result(_load("bigmac_detail.json")["food"])
    assert result is not None
    assert result.serving_grams is None
    assert result.per_serving.kcal == 590.0
    assert result.per_100g.kcal == 590.0  # the serving IS the profile; the ladder refuses a stated mass
    assert result.description == "McDonald's Big Mac"


def test_rank_candidates_applies_the_relevance_gate_and_type_preference() -> None:
    foods = _load("spanakopita_search.json")["foods"]["food"]
    generic_first = rank_candidates("spanakopita", foods, branded=False)
    assert [f["food_id"] for f in generic_first] == ["4001", "4003"]  # spinach is not spanakopita
    brand_first = rank_candidates("spanakopita", foods, branded=True)
    assert [f["food_id"] for f in brand_first] == ["4003", "4001"]
    assert rank_candidates("apple", foods, branded=False) == []


# -- client ------------------------------------------------------------------------


async def test_resolve_via_fixtures_then_cache() -> None:
    db = FakeDatabase()
    calls: list[str] = []
    client = FatSecretClient(db, client_id="id", client_secret="secret", transport=_transport(calls, search=_load("spanakopita_search.json"), detail=_load("spanakopita_detail.json")))
    first = await client.resolve("spanakopita")
    assert first is not None
    assert first.food_id == 4001
    assert calls == ["token", "search", "detail"]
    second = await client.resolve("spanakopita")
    assert second == first
    assert calls == ["token", "search", "detail"]  # the cache answered
    rows = db.tables["usda_cache"]
    assert rows[0]["query_key"] == "fs:spanakopita"
    assert rows[0]["profile"]["provider"] == "fatsecret"


async def test_token_is_shared_across_clients() -> None:
    db = FakeDatabase()
    calls: list[str] = []
    transport = _transport(calls, search=_load("spanakopita_search.json"), detail=_load("spanakopita_detail.json"))
    await FatSecretClient(db, client_id="id", client_secret="secret", transport=transport).resolve("spanakopita")
    await FatSecretClient(FakeDatabase(), client_id="id", client_secret="secret", transport=transport).resolve("spanakopita")
    assert calls.count("token") == 1


async def test_unlisted_ip_error_is_a_miss_not_a_500(caplog) -> None:
    calls: list[str] = []
    client = FatSecretClient(FakeDatabase(), client_id="id", client_secret="secret", transport=_transport(calls, search={}, detail={}, error=_load("ip_error.json")))
    assert await client.resolve("spanakopita") is None
    assert any("fatsecret error 21" in r.getMessage() for r in caplog.records)


async def test_no_credentials_degrades_to_none() -> None:
    client = FatSecretClient(FakeDatabase(), client_id="", client_secret="")
    assert await client.resolve("spanakopita") is None


async def test_corrupt_cache_row_is_a_miss() -> None:
    db = FakeDatabase()
    await db.insert("usda_cache", {"query_key": "fs:spanakopita", "fdc_id": 1, "profile": {"provider": "fatsecret"}})
    calls: list[str] = []
    client = FatSecretClient(db, client_id="id", client_secret="secret", transport=_transport(calls, search=_load("spanakopita_search.json"), detail=_load("spanakopita_detail.json")))
    result = await client.resolve("spanakopita")
    assert result is not None
    assert calls == ["token", "search", "detail"]
    assert db.tables["usda_cache"][0]["profile"]["name"].startswith("Spanakopita")  # replaced in place


# -- the ladder --------------------------------------------------------------------


async def test_resolver_prices_a_fatsecret_food_by_piece_cup_and_mass() -> None:
    calls: list[str] = []
    fs = FatSecretClient(FakeDatabase(), client_id="id", client_secret="secret", transport=_transport(calls, search=_load("spanakopita_search.json"), detail=_load("spanakopita_detail.json")))
    resolver = Resolver(fatsecret=fs)
    piece = await resolver.resolve_item(_item("spanakopita", 2, Unit.PIECE))
    assert piece.source is ResolutionSource.FATSECRET
    assert piece.match_kind is MatchKind.FATSECRET
    assert piece.grams == 286.0
    cup = await resolver.resolve_item(_item("spanakopita", 1, Unit.CUP))
    assert cup.grams == 220.0
    mass = await resolver.resolve_item(_item("spanakopita", 50, Unit.G))
    assert mass.macros.kcal == round(261 * 0.5, 1)
    assert piece.is_estimate is False
    assert piece.identity.key == "fatsecret:4001"


async def test_curated_dictionary_still_wins_over_fatsecret() -> None:
    calls: list[str] = []
    fs = FatSecretClient(FakeDatabase(), client_id="id", client_secret="secret", transport=_transport(calls, search=_load("spanakopita_search.json"), detail=_load("spanakopita_detail.json")))
    resolved = await Resolver(fatsecret=fs).resolve_item(_item("ground beef 93/7", 4, Unit.OZ))
    assert resolved.source is ResolutionSource.DICTIONARY
    assert calls == []  # never asked


async def test_unweighed_row_refuses_a_stated_mass_but_prices_a_count() -> None:
    calls: list[str] = []
    fs = FatSecretClient(FakeDatabase(), client_id="id", client_secret="secret", transport=_transport(calls, search=_load("bigmac_search.json"), detail=_load("bigmac_detail.json")))
    resolver = Resolver(fatsecret=fs)
    one = await resolver.resolve_item(_item("big mac", brand="McDonald's"))
    assert one.source is ResolutionSource.FATSECRET
    assert one.macros.kcal == 590.0
    two = await resolver.resolve_item(_item("big mac", 2, None, brand="McDonald's"))
    assert two.macros.kcal == 1180.0
    # A weight needs a weighed row: the identity stays (it is the same food however much
    # was eaten) and pricing refuses, so the item reads unresolved rather than wrong.
    by_mass = await resolver.resolve_item(_item("big mac", 200, Unit.G, brand="McDonald's"))
    assert by_mass.source is ResolutionSource.UNRESOLVED
    assert by_mass.macros.kcal == 0.0
