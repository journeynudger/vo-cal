"""Scaffold smoke tests: health, observability headers, metrics, client ingestion."""

from datetime import UTC, datetime

from api.db import FakeDatabase


def test_health_returns_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_request_id_header_present(client):
    response = client.get("/health")
    assert "x-request-id" in response.headers
    assert len(response.headers["x-request-id"]) == 12


def test_request_ids_are_unique_per_request(client):
    first = client.get("/health").headers["x-request-id"]
    second = client.get("/health").headers["x-request-id"]
    assert first != second


def test_metrics_exposes_counters(client):
    client.get("/health")  # generate at least one observation
    response = client.get("/metrics")
    assert response.status_code == 200
    body = response.text
    assert "http_requests_total" in body
    assert "http_request_duration_seconds" in body
    # Pre-registered domain metrics are exposed before their emitters exist
    assert "parse_latency_seconds" in body
    assert "question_asked_total" in body
    assert "corrections_total" in body
    assert "log_duration_ms" in body


def test_client_metrics_requires_auth(client):
    response = client.post("/metrics/client", json={"events": []})
    assert response.status_code == 401


def test_client_metrics_roundtrip(client, fake_db: FakeDatabase, auth_headers, test_user_id):
    events = [
        {
            "name": "log_duration_ms",
            "value": 4200.0,
            "attributes": {"meal_type": "lunch"},
            "ts": datetime.now(UTC).isoformat(),
        },
        {
            "name": "outbox_retry",
            "value": 1.0,
            "attributes": {},
            "ts": datetime.now(UTC).isoformat(),
        },
    ]

    response = client.post("/metrics/client", json={"events": events}, headers=auth_headers)

    assert response.status_code == 202
    assert response.json() == {"accepted": 2}

    rows = fake_db.tables.get("client_metrics", [])
    assert len(rows) == 2
    assert all(row["user_id"] == str(test_user_id) for row in rows)
    assert {row["name"] for row in rows} == {"log_duration_ms", "outbox_retry"}
    assert rows[0]["attributes"] == {"meal_type": "lunch"}

    # The dedicated histogram observed the log duration
    metrics_body = client.get("/metrics").text
    assert "log_duration_ms_count 1.0" in metrics_body
    # The catch-all counter picked up the unknown event name
    assert 'client_events_total{name="outbox_retry"} 1.0' in metrics_body
