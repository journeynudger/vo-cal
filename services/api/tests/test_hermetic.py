"""The offline suite is hermetic: no provider key reaches a resolver and no real HTTP request
leaves the process.

Found 2026-09-23: with a .env beside the API, two meal tests spent 14 s and real money on
Anthropic calls, because build_resolver wired the live estimator whenever a key was set and
the test settings only flipped test_mode. A gate that depends on the network is not a gate.
"""

from __future__ import annotations

import httpx
import pytest

from api.config import settings
from api.db import FakeDatabase
from api.nutrition.build import build_resolver

PROVIDER_KEYS = (
    "anthropic_api_key",
    "gemini_api_key",
    "openai_api_key",
    "elevenlabs_api_key",
    "usda_fdc_api_key",
)


def test_no_provider_key_reaches_the_resolver() -> None:
    assert [k for k in PROVIDER_KEYS if getattr(settings, k)] == []
    resolver = build_resolver(FakeDatabase(), estimate_unknowns=True)
    assert getattr(resolver, "_fdc", getattr(resolver, "fdc", None)) is None
    assert getattr(resolver, "_estimator", getattr(resolver, "estimator", None)) is None


async def test_real_http_is_refused() -> None:
    async with httpx.AsyncClient() as client:
        with pytest.raises(RuntimeError, match="offline test suite"):
            await client.get("http://127.0.0.1:9/never")
