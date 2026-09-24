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
    head_noun_agrees,
    parse_serving,
    rank_candidates,
)
from api.nutrition.resolver import Resolver
from api.nutrition.schemas import MatchKind, ResolutionSource
from api.parser.schemas import ParsedItem, Unit

_FIXTURES = Path(__file__).resolve().parent / "fixtures" / "fatsecret_responses"


def _load(name: str) -> dict:
    return json.loads((_FIXTURES / name).read_text())


def _transport(
    call_log: list[str], *, search: dict, detail: dict, error: dict | None = None
) -> httpx.MockTransport:
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


def _item(
    name: str, amount: float | None = None, unit: Unit | None = None, brand: str | None = None
) -> ParsedItem:
    return ParsedItem(name=name, amount=amount, unit=unit, brand=brand, confidence=0.9)


# -- pure --------------------------------------------------------------------------


def test_build_result_scales_the_recorded_serving_and_reads_its_count() -> None:
    # Recorded 2026-09-24: Athens Spanakopita, one serving "2 pieces" of 56 g, 140 kcal.
    result = build_result(_load("spanakopita_detail.json")["food"])
    assert result is not None
    assert result.per_100g.kcal == round(140 * 100 / 56, 3)
    assert result.per_100g.protein == round(4 * 100 / 56, 3)
    assert result.serving_grams == 56.0
    assert result.serving_description == "2 pieces"
    assert result.unit_conversions == {"piece": 28.0}  # "2 pieces" names the per-piece weight
    assert result.brand == "Athens"
    assert result.food_type == "Brand"


def test_build_result_prefers_a_100g_serving_and_maps_measurements() -> None:
    food = {
        "food_id": "1",
        "food_name": "Spinach Pie",
        "food_type": "Generic",
        "servings": {
            "serving": [
                {
                    "serving_description": "1 piece",
                    "metric_serving_amount": "143.000",
                    "metric_serving_unit": "g",
                    "number_of_units": "1.000",
                    "measurement_description": "piece",
                    "calories": "373",
                    "protein": "11.58",
                    "carbohydrate": "28.03",
                    "fat": "24.88",
                    "fiber": "2.1",
                    "is_default": "1",
                },
                {
                    "serving_description": "100 g",
                    "metric_serving_amount": "100.000",
                    "metric_serving_unit": "g",
                    "number_of_units": "100.000",
                    "measurement_description": "g",
                    "calories": "261",
                    "protein": "8.10",
                    "carbohydrate": "19.60",
                    "fat": "17.40",
                    "fiber": "1.5",
                },
                {
                    "serving_description": "1 cup",
                    "metric_serving_amount": "220.000",
                    "metric_serving_unit": "g",
                    "number_of_units": "1.000",
                    "measurement_description": "cup",
                    "calories": "574",
                    "protein": "17.82",
                    "carbohydrate": "43.12",
                    "fat": "38.28",
                    "fiber": "3.3",
                },
            ]
        },
    }
    result = build_result(food)
    assert result is not None
    assert result.per_100g.kcal == 261.0
    assert result.serving_grams == 143.0
    assert result.unit_conversions == {"piece": 143.0, "cup": 220.0}


def test_a_serving_with_a_negative_nutrient_is_skipped() -> None:
    food = _detail("9", "Odd Row", "120", protein="2.0", carbs="-0.5", fat="1.0")["food"]
    assert parse_serving(food["servings"]["serving"]) is None
    assert build_result(food) is None  # its only serving was impossible


def test_build_result_unweighed_restaurant_serving() -> None:
    # Recorded 2026-09-24: McDonald's Big Mac, "1 serving", no weight, 580 kcal.
    result = build_result(_load("bigmac_detail.json")["food"])
    assert result is not None
    assert result.serving_grams is None
    assert result.per_serving.kcal == 580.0
    assert (
        result.per_100g.kcal == 580.0
    )  # the serving IS the profile; pricing refuses a stated mass
    assert result.description == "McDonald's Big Mac"


def test_rank_candidates_applies_the_relevance_gate_and_type_preference() -> None:
    # The recorded search: five brand rows named "Spanakopita" and the generic "Spanakopitta".
    foods = _load("spanakopita_search.json")["foods"]["food"]
    generic_first = rank_candidates("spanakopita", foods, branded=False)
    assert generic_first[0]["food_type"] == "Generic"  # one letter of tolerance rescued it
    assert generic_first[0]["food_name"] == "Spanakopitta"
    assert "Spinach Pie" not in {
        f["food_name"] for f in generic_first
    }  # names none of the words said
    assert len(generic_first) == len(foods) - 1
    brand_first = rank_candidates("spanakopita", foods, branded=True)
    assert brand_first[0]["food_type"] == "Brand"
    assert rank_candidates("apple", foods, branded=False) == []
    assert (
        rank_candidates("rice", [{"food_name": "Ride", "food_type": "Generic"}], branded=False)
        == []
    )


def test_head_noun_must_agree() -> None:
    assert head_noun_agrees("chicken salad", "Chicken Salad")
    assert head_noun_agrees("cosmic crisp apple", "Cosmic Crisp Apple")
    assert head_noun_agrees("protein bar", "Protein Bar (Chocolate Chip Cookie Dough)")
    assert head_noun_agrees("orange", "Oranges")
    assert head_noun_agrees("spanakopita", "Spanakopitta")
    assert not head_noun_agrees("crisp apple", "Apple Crisp")
    assert not head_noun_agrees("chicken salad", "Salad with Grilled Chicken")
    assert (
        rank_candidates(
            "crisp apple", [{"food_name": "Apple Crisp", "food_type": "Generic"}], branded=False
        )
        == []
    )


def test_rank_candidates_prefers_the_row_that_adds_the_fewest_words() -> None:
    # FatSecret's own order for "egg" on 2026-09-24: Egg, Great Value Egg, Fried Egg, Boiled Egg.
    foods = [
        {"food_id": "2", "food_name": "Fried Egg", "food_type": "Generic"},
        {"food_id": "3", "food_name": "Scrambled Egg (Whole, Cooked)", "food_type": "Generic"},
        {"food_id": "4", "food_name": "Egg", "food_type": "Brand", "brand_name": "Great Value"},
        {"food_id": "1", "food_name": "Egg", "food_type": "Generic"},
    ]
    assert [f["food_id"] for f in rank_candidates("egg", foods, branded=False)] == [
        "1",
        "2",
        "3",
        "4",
    ]
    assert next(f["food_id"] for f in rank_candidates("egg", foods, branded=True)) == "4"


# -- client ------------------------------------------------------------------------


async def test_resolve_via_fixtures_then_cache() -> None:
    db = FakeDatabase()
    calls: list[str] = []
    client = FatSecretClient(
        db,
        client_id="id",
        client_secret="secret",
        transport=_transport(
            calls, search=_load("spanakopita_search.json"), detail=_load("spanakopita_detail.json")
        ),
    )
    first = await client.resolve("spanakopita")
    assert first is not None
    assert first.food_id == 4678723  # the recorded detail is the Athens row
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
    transport = _transport(
        calls, search=_load("spanakopita_search.json"), detail=_load("spanakopita_detail.json")
    )
    await FatSecretClient(db, client_id="id", client_secret="secret", transport=transport).resolve(
        "spanakopita"
    )
    await FatSecretClient(
        FakeDatabase(), client_id="id", client_secret="secret", transport=transport
    ).resolve("spanakopita")
    assert calls.count("token") == 1


async def test_unlisted_ip_error_is_a_miss_not_a_500(caplog) -> None:
    calls: list[str] = []
    client = FatSecretClient(
        FakeDatabase(),
        client_id="id",
        client_secret="secret",
        transport=_transport(calls, search={}, detail={}, error=_load("ip_error.json")),
    )
    assert await client.resolve("spanakopita") is None
    assert any("fatsecret error 21" in r.getMessage() for r in caplog.records)


async def test_no_credentials_degrades_to_none() -> None:
    client = FatSecretClient(FakeDatabase(), client_id="", client_secret="")
    assert await client.resolve("spanakopita") is None


async def test_corrupt_cache_row_is_a_miss() -> None:
    db = FakeDatabase()
    await db.insert(
        "usda_cache",
        {"query_key": "fs:spanakopita", "fdc_id": 1, "profile": {"provider": "fatsecret"}},
    )
    calls: list[str] = []
    client = FatSecretClient(
        db,
        client_id="id",
        client_secret="secret",
        transport=_transport(
            calls, search=_load("spanakopita_search.json"), detail=_load("spanakopita_detail.json")
        ),
    )
    result = await client.resolve("spanakopita")
    assert result is not None
    assert calls == ["token", "search", "detail"]
    assert db.tables["usda_cache"][0]["profile"]["name"].startswith(
        "Spanakopita"
    )  # replaced in place


# -- the ladder --------------------------------------------------------------------


async def test_resolver_prices_a_fatsecret_food_by_piece_cup_and_mass() -> None:
    calls: list[str] = []
    fs = FatSecretClient(
        FakeDatabase(),
        client_id="id",
        client_secret="secret",
        transport=_transport(
            calls, search=_load("spanakopita_search.json"), detail=_load("spanakopita_detail.json")
        ),
    )
    resolver = Resolver(fatsecret=fs)
    piece = await resolver.resolve_item(_item("spanakopita", 2, Unit.PIECE))
    assert piece.source is ResolutionSource.FATSECRET
    assert piece.match_kind is MatchKind.FATSECRET
    assert piece.grams == 56.0  # two pieces of 28 g, from the "2 pieces" serving
    serving = await resolver.resolve_item(_item("spanakopita"))
    assert serving.grams == 56.0  # one serving
    mass = await resolver.resolve_item(_item("spanakopita", 50, Unit.G))
    assert mass.macros.kcal == round(140 * 100 / 56 * 0.5, 1)
    assert piece.is_estimate is False
    assert piece.identity.key == "fatsecret:4678723"


def _search(*rows: tuple[str, str, str]) -> dict:
    return {
        "foods": {
            "food": [
                {
                    "food_id": food_id,
                    "food_name": name,
                    "food_type": "Generic",
                    "food_description": description,
                }
                for food_id, name, description in rows
            ]
        }
    }


def _detail(
    food_id: str,
    name: str,
    kcal: str,
    grams: str = "100.000",
    *,
    protein: str = "1.0",
    carbs: str = "10.0",
    fat: str = "1.0",
) -> dict:
    # Macros must add up to the calories (the plausibility gate is load-bearing).
    return {
        "food": {
            "food_id": food_id,
            "food_name": name,
            "food_type": "Generic",
            "servings": {
                "serving": {
                    "serving_description": "100 g",
                    "metric_serving_amount": grams,
                    "metric_serving_unit": "g",
                    "number_of_units": "100.000",
                    "measurement_description": "g",
                    "calories": kcal,
                    "protein": protein,
                    "carbohydrate": carbs,
                    "fat": fat,
                    "is_default": "1",
                }
            },
        }
    }


async def test_fatsecret_row_precedes_the_curated_suffix_head() -> None:
    # "sugarbee apple" is no curated alias (cosmic crisp and gala are) but has the curated
    # head "apple"; FatSecret names the cultivar itself and now comes first.
    calls: list[str] = []
    fs = FatSecretClient(
        FakeDatabase(),
        client_id="id",
        client_secret="secret",
        transport=_transport(
            calls,
            search=_search(("77", "Sugarbee Apple", "Per 100g - Calories: 57kcal")),
            detail=_detail("77", "Sugarbee Apple", "57"),
        ),
    )
    resolved = await Resolver(fatsecret=fs).resolve_item(_item("sugarbee apple", 1, Unit.PIECE))
    assert resolved.source is ResolutionSource.FATSECRET
    assert resolved.identity is not None
    assert resolved.identity.key == "fatsecret:77"


async def test_chicken_salad_is_not_a_green_salad() -> None:
    # The case a calorie band against the head would have killed: the curated head of
    # "chicken salad" is "salad" (about 20 kcal), FatSecret's row is ten times that.
    calls: list[str] = []
    fs = FatSecretClient(
        FakeDatabase(),
        client_id="id",
        client_secret="secret",
        transport=_transport(
            calls,
            search=_search(("55", "Chicken Salad", "Per 100g - Calories: 200kcal")),
            detail=_detail("55", "Chicken Salad", "200", protein="12.0", carbs="4.0", fat="15.0"),
        ),
    )
    resolved = await Resolver(fatsecret=fs).resolve_item(_item("chicken salad", 1, Unit.CUP))
    assert resolved.source is ResolutionSource.FATSECRET
    assert resolved.identity is not None
    assert resolved.identity.key == "fatsecret:55"
    assert resolved.identity.priced_as is None  # the row is named what was said


async def test_a_dessert_never_stands_in_for_a_fruit() -> None:
    # The apple incident, replayed against FatSecret: the only row for "crisp apple" is the
    # dessert; the head-noun rule refuses it and the curated head prices the apple.
    calls: list[str] = []
    fs = FatSecretClient(
        FakeDatabase(),
        client_id="id",
        client_secret="secret",
        transport=_transport(
            calls,
            search=_search(("88", "Apple Crisp", "Per 100g - Calories: 161kcal")),
            detail=_detail("88", "Apple Crisp", "161"),
        ),
    )
    resolved = await Resolver(fatsecret=fs).resolve_item(_item("crisp apple", 1, Unit.PIECE))
    assert resolved.source is ResolutionSource.DICTIONARY
    assert resolved.identity is not None
    assert resolved.identity.key == "dictionary:apple"
    assert "detail" not in calls  # refused at the search, no second call


async def test_curated_dictionary_still_wins_over_fatsecret() -> None:
    calls: list[str] = []
    fs = FatSecretClient(
        FakeDatabase(),
        client_id="id",
        client_secret="secret",
        transport=_transport(
            calls, search=_load("spanakopita_search.json"), detail=_load("spanakopita_detail.json")
        ),
    )
    resolved = await Resolver(fatsecret=fs).resolve_item(_item("ground beef 93/7", 4, Unit.OZ))
    assert resolved.source is ResolutionSource.DICTIONARY
    assert calls == []  # never asked


async def test_unweighed_row_refuses_a_stated_mass_but_prices_a_count() -> None:
    calls: list[str] = []
    fs = FatSecretClient(
        FakeDatabase(),
        client_id="id",
        client_secret="secret",
        transport=_transport(
            calls, search=_load("bigmac_search.json"), detail=_load("bigmac_detail.json")
        ),
    )
    resolver = Resolver(fatsecret=fs)
    one = await resolver.resolve_item(_item("big mac", brand="McDonald's"))
    assert one.source is ResolutionSource.FATSECRET
    assert one.macros.kcal == 580.0
    two = await resolver.resolve_item(_item("big mac", 2, None, brand="McDonald's"))
    assert two.macros.kcal == 1160.0
    # A weight needs a weighed row: the identity stays (it is the same food however much
    # was eaten) and pricing refuses, so the item reads unresolved rather than wrong.
    by_mass = await resolver.resolve_item(_item("big mac", 200, Unit.G, brand="McDonald's"))
    assert by_mass.source is ResolutionSource.UNRESOLVED
    assert by_mass.macros.kcal == 0.0
