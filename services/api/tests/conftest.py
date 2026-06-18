"""Pytest fixtures for the Vo-Cal API tests.

The entire offline suite runs against FakeDatabase + the X-Test-User auth seam:
no network, no Supabase, no mocking of the SDK. See src/api/db.py for why.
"""

from __future__ import annotations

from collections.abc import Generator
from uuid import UUID

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


@pytest.fixture(autouse=True)
def _test_settings() -> Generator[None]:
    """Enable the test auth seam (X-Test-User header) for every test."""
    original_test_mode, original_debug = settings.test_mode, settings.debug
    settings.test_mode = True
    settings.debug = True
    yield
    settings.test_mode, settings.debug = original_test_mode, original_debug


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
