"""/metrics exposure gate (deferred item from #18: publicly scrapable internals).

Fly's managed scraper reaches the machine over the private network and never passes
the edge proxy, so its requests carry no ``Fly-Client-IP`` header — those stay open.
Anything arriving through the public edge IS stamped with that header by the proxy
and must present the METRICS_TOKEN bearer (unset token = refused outright).
"""

from __future__ import annotations

from collections.abc import Generator

import pytest

from api.config import settings


@pytest.fixture
def metrics_token() -> Generator[str]:
    original = settings.metrics_token
    settings.metrics_token = "test-scrape-token"
    yield settings.metrics_token
    settings.metrics_token = original


def test_private_scrape_stays_open(client):
    # No edge-proxy stamp (Fly private scrape / local dev): no token required.
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert "http_requests_total" in resp.text


def test_public_edge_without_token_is_403(client, metrics_token):
    resp = client.get("/metrics", headers={"Fly-Client-IP": "203.0.113.7"})
    assert resp.status_code == 403


def test_public_edge_with_wrong_token_is_403(client, metrics_token):
    resp = client.get(
        "/metrics",
        headers={"Fly-Client-IP": "203.0.113.7", "Authorization": "Bearer wrong"},
    )
    assert resp.status_code == 403


def test_public_edge_with_token_passes(client, metrics_token):
    resp = client.get(
        "/metrics",
        headers={"Fly-Client-IP": "203.0.113.7", "Authorization": f"Bearer {metrics_token}"},
    )
    assert resp.status_code == 200
    assert "http_requests_total" in resp.text


def test_public_edge_with_no_token_configured_is_403(client):
    # Empty METRICS_TOKEN must fail CLOSED for edge traffic — an unset secret must not
    # mean "world-readable", it means "no public scraping at all".
    assert settings.metrics_token == ""
    resp = client.get("/metrics", headers={"Fly-Client-IP": "203.0.113.7"})
    assert resp.status_code == 403
