"""R7: the seasonal recalibration rule — protocol age -> "time to rebuild?".

The threshold is one tested constant (protocols/staleness.py), never a number retyped
in a client. Boundary matters: 89 days must stay silent, 90 must speak.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from api.protocols.staleness import (
    RECALIBRATION_AFTER_DAYS,
    needs_recalibration,
    parse_created_at,
    protocol_age_days,
)

NOW = datetime(2026, 8, 19, 12, 0, tzinfo=UTC)


def _days_ago(days: float) -> datetime:
    return NOW - timedelta(days=days)


def test_threshold_is_a_quarter():
    assert RECALIBRATION_AFTER_DAYS == 90


def test_just_under_the_threshold_is_not_stale():
    assert needs_recalibration(_days_ago(89.9), now=NOW) is False


def test_exactly_at_the_threshold_is_stale():
    assert needs_recalibration(_days_ago(90), now=NOW) is True


def test_well_past_the_threshold_is_stale():
    assert needs_recalibration(_days_ago(200), now=NOW) is True


def test_brand_new_protocol_is_not_stale():
    assert needs_recalibration(NOW, now=NOW) is False


def test_unknown_creation_time_is_never_stale():
    # A missing timestamp is unknown age, not old age: the prompt makes a claim about
    # the user's own data, so it may only fire on a fact.
    assert needs_recalibration(None, now=NOW) is False
    assert protocol_age_days(None, now=NOW) is None


def test_future_timestamp_is_not_stale():
    # Clock skew between device and server must not read as an ancient protocol.
    assert needs_recalibration(NOW + timedelta(days=5), now=NOW) is False


def test_age_counts_whole_days():
    assert protocol_age_days(_days_ago(90.9), now=NOW) == 90
    assert protocol_age_days(_days_ago(0.5), now=NOW) == 0


def test_naive_timestamps_are_read_as_utc():
    # timestamptz columns are aware; a naive value only reaches us from a backend that
    # dropped the offset — it must degrade, not raise on the comparison.
    naive = _days_ago(120).replace(tzinfo=None)
    assert needs_recalibration(naive, now=NOW) is True


def test_parse_created_at_accepts_rows_from_either_backend():
    # Postgres hands back a datetime; the Supabase JSON client and FakeDatabase an
    # ISO string (with microseconds).
    aware = _days_ago(100)
    assert parse_created_at(aware) == aware
    assert parse_created_at(aware.isoformat()) == aware
    assert parse_created_at(None) is None
    assert parse_created_at("not a timestamp") is None
    assert parse_created_at(12345) is None
