"""Pytest fixtures for the Vo-Cal API tests.

The entire offline suite runs against FakeDatabase + the X-Test-User auth seam:
no network, no Supabase, no mocking of the SDK. See src/api/db.py for why.
"""

from __future__ import annotations

from collections.abc import Generator
from uuid import UUID

import httpx
import pytest
from fastapi.testclient import TestClient

from api.config import settings
from api.db import FakeDatabase
from api.dependencies import make_test_token
from api.main import create_app
from api.storage import FakeStorage

# Test user IDs
TEST_USER_ID = UUID("11111111-1111-1111-1111-111111111111")
TEST_USER_2_ID = UUID("22222222-2222-2222-2222-222222222222")


LIVE_MARKERS = ("live_db", "live_llm", "live_fdc")
PROVIDER_KEYS = (
    "anthropic_api_key",
    "gemini_api_key",
    "openai_api_key",
    "elevenlabs_api_key",
    "usda_fdc_api_key",
)


def _is_live(request: pytest.FixtureRequest) -> bool:
    return any(request.node.get_closest_marker(m) is not None for m in LIVE_MARKERS)


@pytest.fixture(autouse=True)
def _test_settings(request: pytest.FixtureRequest) -> Generator[None]:
    """Enable the test auth seam (X-Test-User header) and make the offline suite hermetic.

    Every provider key is blanked so no resolver, estimator, transcriber or parser can be
    wired to a paid API by a .env sitting beside the code. Found 2026-09-23: two meal tests
    spent 14 s and real money on Anthropic calls through the estimator because only
    test_mode was flipped here. Live-marked tests keep their keys (tests/test_hermetic.py).
    """
    keys = ("test_mode", "debug", *PROVIDER_KEYS)
    original = {key: getattr(settings, key) for key in keys}
    settings.test_mode = True
    settings.debug = True
    if not _is_live(request):
        for key in PROVIDER_KEYS:
            setattr(settings, key, "")
    yield
    for key, value in original.items():
        setattr(settings, key, value)


@pytest.fixture(autouse=True)
def _no_network(request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch) -> None:
    """Any real HTTP request fails the test. httpx.MockTransport (the FDC tests) and the
    TestClient's own transport are untouched; only the transports that open sockets are."""
    if _is_live(request):
        return

    def refuse(*_args: object, **_kwargs: object) -> None:
        raise RuntimeError("offline test suite: a real HTTP request was attempted")

    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", refuse)
    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", refuse)


@pytest.fixture
def fake_db() -> FakeDatabase:
    """Fresh in-memory database per test."""
    return FakeDatabase()


@pytest.fixture
def fake_storage() -> FakeStorage:
    """Fresh in-memory blob store per test."""
    return FakeStorage()


@pytest.fixture
def app(fake_db: FakeDatabase, fake_storage: FakeStorage):
    """App instance wired to the per-test FakeDatabase + FakeStorage."""
    return create_app(database=fake_db, storage=fake_storage)


@pytest.fixture
def client(app) -> Generator[TestClient]:
    """Test client (TestClient runs the lifespan, which installs fake_db)."""
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def auth_headers() -> dict[str, str]:
    """Headers authenticating as TEST_USER_ID via the test seam."""
    return {"X-Test-User": make_test_token(TEST_USER_ID)}


@pytest.fixture
def auth_headers_user_2() -> dict[str, str]:
    """Headers authenticating as TEST_USER_2_ID (multi-user tests)."""
    return {"X-Test-User": make_test_token(TEST_USER_2_ID)}


@pytest.fixture
def test_user_id() -> UUID:
    return TEST_USER_ID


@pytest.fixture
def test_user_2_id() -> UUID:
    return TEST_USER_2_ID


# -- shared helpers for the meal-flow tests (one copy; three files used to carry their own) --


def parse_transcript(client: TestClient, headers: dict[str, str], transcript: str = "4oz 93/7 beef") -> dict:
    """POST /parse and return the body."""
    return client.post("/parse", json={"transcript": transcript}, headers=headers).json()


def confirmed_items(parse_body: dict) -> list[dict]:
    """Turn parse-result items into confirmed-item payloads (extra fields ignored)."""
    return [
        {
            "name": it["name"],
            "amount": it["amount"],
            "unit": it["unit"],
            "state": it["state"],
            "fat_ratio": it["fat_ratio"],
            "brand": it["brand"],
            "prep_method": it["prep_method"],
            "grams": it["grams"],
            "macros": it["macros"],
            "confidence": it["confidence"],
            "source": it["source"],
        }
        for it in parse_body["items"]
    ]
