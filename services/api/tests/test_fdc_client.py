"""B2: USDA FDC client — recorded fixtures, cache read-through, degradation.

No live HTTP in this suite. ``httpx.MockTransport`` replays recorded FDC
responses; the live path is exercised only under the ``live_fdc`` marker.

Acceptance: "spanakopita" (not in dictionary) resolves via FDC fixtures; the
second call hits the cache (zero further FDC requests).
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import httpx
import pytest

from api.db import FakeDatabase
from api.nutrition.fdc_client import FdcClient, is_relevant, normalize_query, profile_from_detail

_FIXTURES = Path(__file__).resolve().parent / "fixtures" / "fdc_responses"


def _load(name: str) -> dict:
    return json.loads((_FIXTURES / name).read_text())


SEARCH = _load("spanakopita_search.json")
DETAIL = _load("spanakopita_detail.json")


def _recorded_transport(call_log: list[str]) -> httpx.MockTransport:
    """A MockTransport that replays the spanakopita search + detail and logs hits."""

    def handler(request: httpx.Request) -> httpx.Response:
        call_log.append(request.url.path)
        if request.url.path.endswith("/foods/search"):
            return httpx.Response(200, json=SEARCH)
        if "/food/" in request.url.path:
            return httpx.Response(200, json=DETAIL)
        return httpx.Response(404, json={})  # pragma: no cover

    return httpx.MockTransport(handler)


# -- nutrient mapping --------------------------------------------------------


def test_a_percentage_is_a_content_word() -> None:
    assert is_relevant("2% milk", "Milk, reduced fat, fluid, 2% milkfat")
    assert not is_relevant("2% milk", "Milk, nonfat, fluid, skim")
    assert not is_relevant("fairlife 2% milk", "Fairlife Skim Milk")


def test_profile_from_detail_maps_nutrient_ids():
    profile = profile_from_detail(DETAIL)
    assert profile.kcal == 224.0
    assert profile.protein == 6.4
    assert profile.carbs == 17.3
    assert profile.fat == 14.2
    assert profile.fiber == 1.5


def test_profile_from_detail_handles_abridged_shape():
    abridged = {
        "foodNutrients": [
            {"nutrientId": 1008, "value": 100.0},
            {"nutrientId": 1003, "value": 5.0},
        ]
    }
    profile = profile_from_detail(abridged)
    assert profile.kcal == 100.0
    assert profile.protein == 5.0


def test_normalize_query():
    assert normalize_query("  Spinach   Pie ") == "spinach pie"


# -- resolve + cache read-through --------------------------------------------


async def test_resolve_via_recorded_fixtures():
    call_log: list[str] = []
    db = FakeDatabase()
    client = FdcClient(db, api_key="test-key", transport=_recorded_transport(call_log))

    result = await client.resolve("spanakopita")

    assert result is not None
    assert result.fdc_id == 170670  # Survey hit ranked over Branded
    assert result.profile.kcal == 224.0
    # one search + one detail
    assert sum("search" in p for p in call_log) == 1
    assert sum("/food/" in p for p in call_log) == 1


async def test_second_call_hits_cache_no_http():
    call_log: list[str] = []
    db = FakeDatabase()
    client = FdcClient(db, api_key="test-key", transport=_recorded_transport(call_log))

    await client.resolve("spanakopita")
    calls_after_first = len(call_log)
    again = await client.resolve("spanakopita")

    assert again is not None
    assert again.profile.kcal == 224.0
    # no new HTTP calls on the cached path
    assert len(call_log) == calls_after_first
    assert len(db.tables.get("usda_cache", [])) == 1


async def test_preferred_data_type_ranked_over_branded():
    call_log: list[str] = []
    db = FakeDatabase()
    client = FdcClient(db, api_key="test-key", transport=_recorded_transport(call_log))
    result = await client.resolve("spanakopita")
    # Survey (FNDDS) fdcId chosen over the Branded one (1100001)
    assert result.fdc_id == 170670


# -- graceful degradation ----------------------------------------------------


async def test_no_api_key_degrades_to_none():
    db = FakeDatabase()
    client = FdcClient(db, api_key="")  # no key
    assert await client.resolve("spanakopita") is None


async def test_network_error_degrades_to_none():
    def handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("FDC down")

    db = FakeDatabase()
    client = FdcClient(db, api_key="test-key", transport=httpx.MockTransport(handler))
    assert await client.resolve("anything") is None


async def test_empty_search_degrades_to_none():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/foods/search"):
            return httpx.Response(200, json={"foods": []})
        return httpx.Response(200, json=DETAIL)

    db = FakeDatabase()
    client = FdcClient(db, api_key="test-key", transport=httpx.MockTransport(handler))
    assert await client.resolve("nonexistent food xyz") is None


async def test_malformed_detail_payload_degrades_to_none():
    # A detail payload with a non-numeric nutrient amount makes profile_from_detail raise
    # (float("abc")) / NutrientProfile reject. The client guarantees it NEVER raises out to
    # the request handler — a parse must not 500 because USDA returned junk.
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/foods/search"):
            return httpx.Response(200, json=SEARCH)
        return httpx.Response(
            200,
            json={"fdcId": 1, "foodNutrients": [{"nutrientId": 1008, "value": "not-a-number"}]},
        )

    db = FakeDatabase()
    client = FdcClient(db, api_key="test-key", transport=httpx.MockTransport(handler))
    assert await client.resolve("spanakopita") is None
    assert db.tables.get("usda_cache", []) == []  # junk never cached


async def test_corrupt_cache_row_degrades_to_miss():
    # A corrupt usda_cache row (here: per_100g missing a required macro) must be treated as a
    # cache miss, not raised out of resolve(). Same "never raises" guarantee on the cache path.
    db = FakeDatabase()
    db.tables["usda_cache"] = [
        {"query_key": "spanakopita", "fdc_id": 1, "profile": {"per_100g": {"kcal": 224.0}}}
    ]
    client = FdcClient(db, api_key="")  # no key: if the cache row is skipped we degrade to None
    assert await client.resolve("spanakopita") is None


async def test_zero_macro_detail_treated_as_miss():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/foods/search"):
            return httpx.Response(200, json=SEARCH)
        return httpx.Response(200, json={"fdcId": 1, "foodNutrients": []})

    db = FakeDatabase()
    client = FdcClient(db, api_key="test-key", transport=httpx.MockTransport(handler))
    assert await client.resolve("spanakopita") is None
    # nothing cached
    assert db.tables.get("usda_cache", []) == []


# -- live (deselected by default) --------------------------------------------


@pytest.mark.live_fdc
async def test_live_fdc_resolves_spanakopita():
    key = os.environ.get("USDA_FDC_API_KEY", "")
    if not key:
        pytest.skip("live_fdc: USDA_FDC_API_KEY not set")
    db = FakeDatabase()
    client = FdcClient(db, api_key=key)
    result = await client.resolve("spanakopita")
    assert result is not None
    assert result.profile.kcal > 0


# -- relevance gate + reference-only search for brand-less items (2026-09-23) -------------
# "cosmic crisp apple" ranked USDA's "Desserts, apple crisp, prepared-from-recipe" first and
# priced 200 g of an apple at 322 kcal: the chosen row was never compared to the query, and
# a brand-less generic could land on any Branded label row.

APPLE_CRISP_SEARCH = {
    "totalHits": 3,
    "foods": [
        {"fdcId": 2708023, "description": "Crisp, apple", "dataType": "Survey (FNDDS)"},
        {
            "fdcId": 169601,
            "description": "Desserts, apple crisp, prepared-from-recipe",
            "dataType": "SR Legacy",
        },
        {"fdcId": 2191849, "description": "COSMIC CRISP DRIED APPLE SLICES", "dataType": "Branded"},
    ],
}


def _transport(
    search: dict, detail: dict, bodies: list[dict], paths: list[str]
) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        paths.append(request.url.path)
        if request.url.path.endswith("/foods/search"):
            bodies.append(json.loads(request.content))
            return httpx.Response(200, json=search)
        return httpx.Response(200, json=detail)

    return httpx.MockTransport(handler)


def test_relevance_requires_every_content_word():
    from api.nutrition.fdc_client import is_relevant

    assert not is_relevant("cosmic crisp apple", "Desserts, apple crisp, prepared-from-recipe")
    assert is_relevant("spanakopita", "Spanakopita (spinach pie)")
    assert is_relevant("apple", "Apples, raw, with skin")  # plural row
    assert is_relevant("cherry", "Cherries, sweet, raw")  # y -> ies
    assert is_relevant("tomatoes", "Tomatoes, red, ripe, raw")
    assert is_relevant("dave's killer bread bread", "DAVE'S KILLER BREAD, 21 WHOLE GRAINS")
    assert not is_relevant("bison bacon", "Pork, cured, bacon, cooked")
    assert not is_relevant("", "Apples, raw")


async def test_irrelevant_rows_are_a_miss_not_a_wrong_food():
    bodies: list[dict] = []
    paths: list[str] = []
    fdc = FdcClient(
        FakeDatabase(), api_key="k", transport=_transport(APPLE_CRISP_SEARCH, DETAIL, bodies, paths)
    )
    assert await fdc.resolve("cosmic crisp apple") is None
    assert not any("/food/" in p for p in paths)  # no detail fetch for a row that isn't the food


async def test_first_relevant_row_wins_over_irrelevant_top_hit():
    search = {
        "totalHits": 2,
        "foods": [
            {"fdcId": 1, "description": "Desserts, apple crisp", "dataType": "SR Legacy"},
            {
                "fdcId": 170670,
                "description": "Spanakopita (spinach pie)",
                "dataType": "Survey (FNDDS)",
            },
        ],
    }
    fdc = FdcClient(FakeDatabase(), api_key="k", transport=_transport(search, DETAIL, [], []))
    result = await fdc.resolve("spanakopita")
    assert result is not None
    assert result.fdc_id == 170670


async def test_brandless_search_excludes_branded_rows_branded_search_includes_them():
    bodies: list[dict] = []
    fdc = FdcClient(FakeDatabase(), api_key="k", transport=_transport(SEARCH, DETAIL, bodies, []))
    await fdc.resolve("spanakopita")
    assert "Branded" not in bodies[0]["dataType"]
    await fdc.resolve("spanakopita", branded=True)
    assert "Branded" in bodies[1]["dataType"]


async def test_branded_and_generic_lookups_have_separate_cache_rows():
    db = FakeDatabase()
    fdc = FdcClient(db, api_key="k", transport=_transport(SEARCH, DETAIL, [], []))
    await fdc.resolve("spanakopita")
    await fdc.resolve("spanakopita", branded=True)
    keys = {r["query_key"] for r in await db.select("usda_cache", {})}
    assert keys == {"spanakopita", "spanakopita [branded]"}


async def test_stale_irrelevant_cache_row_is_replaced_by_a_relevant_fetch():
    # A row written before the gate existed (the apple-crisp row for "cosmic crisp apple")
    # must not keep pricing every user's food: it is a miss, and the live fetch overwrites it.
    db = FakeDatabase()
    await db.insert(
        "usda_cache",
        {
            "query_key": "spanakopita",
            "fdc_id": 169601,
            "profile": {
                "description": "Desserts, apple crisp, prepared-from-recipe",
                "per_100g": {"kcal": 161, "protein": 2, "carbs": 30, "fat": 4, "fiber": 1},
            },
        },
    )
    paths: list[str] = []
    fdc = FdcClient(db, api_key="k", transport=_transport(SEARCH, DETAIL, [], paths))
    result = await fdc.resolve("spanakopita")
    assert result is not None
    assert result.fdc_id == 170670
    assert any(p.endswith("/foods/search") for p in paths)
    rows = await db.select("usda_cache", {"query_key": "spanakopita"})
    assert len(rows) == 1
    assert rows[0]["fdc_id"] == 170670
