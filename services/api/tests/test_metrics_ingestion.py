"""Telemetry ingestion hardening: PII allowlist (C1) + bounded Prometheus labels (C4).

client_metrics.attributes is client-supplied and persisted verbatim into durable
telemetry + the admin chain, and the event name was used directly as a Prometheus
label. Both are client-controlled: the first leaks PII (MUST NOT #5), the second
explodes label cardinality. The server owns both vocabularies.
"""

from __future__ import annotations

from datetime import UTC, datetime
from uuid import uuid4


def _ingest(client, headers, events):
    return client.post("/metrics/client", json={"events": events}, headers=headers)


def _event(name: str, *, value: float = 1.0, attributes: dict | None = None) -> dict:
    return {
        "name": name,
        "value": value,
        "attributes": attributes or {},
        "ts": datetime.now(UTC).isoformat(),
    }


def test_pii_attributes_are_dropped_before_storage(client, auth_headers, fake_db):
    # C1: a client must not persist PII (phone, weight) into durable telemetry + the
    # admin chain (MUST NOT #5). Only allowlisted keys survive; meal_log_id is kept
    # (the admin metrics-correlation reads attributes.meal_log_id).
    meal_id = str(uuid4())
    resp = _ingest(
        client,
        auth_headers,
        [_event("corrections_count", attributes={
            "phone": "5551234567", "weight_kg": "82", "meal_log_id": meal_id,
        })],
    )
    assert resp.status_code == 202
    rows = fake_db.tables["client_metrics"]
    assert len(rows) == 1
    assert rows[0]["attributes"] == {"meal_log_id": meal_id}  # phone + weight dropped


def test_non_uuid_value_for_allowed_key_is_dropped(client, auth_headers, fake_db):
    # An allowlisted key still can't smuggle PII as its value — the meal id keys are UUIDs.
    _ingest(client, auth_headers, [_event("corrections_count", attributes={
        "meal_id": "my-weight-is-200lbs",
    })])
    assert fake_db.tables["client_metrics"][0]["attributes"] == {}


def test_known_attribute_survives(client, auth_headers, fake_db):
    meal_id = str(uuid4())
    _ingest(client, auth_headers, [_event("log_duration_ms", value=1234.0, attributes={
        "meal_log_id": meal_id,
    })])
    assert fake_db.tables["client_metrics"][0]["attributes"] == {"meal_log_id": meal_id}


def test_event_label_collapses_unknown_names_to_other():
    # C4: the Prometheus label is drawn from a server-owned allowlist; a client-supplied
    # name can never add a time series (cardinality-explosion DoS).
    from api.metrics_ingestion import _ALLOWED_EVENT_NAMES, _OTHER_EVENT_LABEL, _event_label

    assert "question_asked" in _ALLOWED_EVENT_NAMES
    assert _event_label("question_asked") == "question_asked"
    assert _event_label("attacker-" + "x" * 60) == _OTHER_EVENT_LABEL
