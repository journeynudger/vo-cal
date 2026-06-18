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
from api.nutrition.fdc_client import FdcClient, normalize_query, profile_from_detail

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
