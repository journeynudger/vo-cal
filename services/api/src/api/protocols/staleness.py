"""Protocol age: is the active protocol old enough to invite a rebuild?

The seasonal recalibration prompt (product owner, 2026-08-19: "lives change with the
seasons"), and the lightweight first realization of decision #37. The weekly check-in
already moves the NUMBERS inside a protocol; this asks the other question — whether the
ANSWERS it was computed from (job, training, kids, stress, meds) still describe the
user's life.

The threshold lives here, tested, rather than as a number retyped in a view
(AGENTS.md #6: deterministic code calculates). Clients render what the server says.
"""

from __future__ import annotations

from datetime import UTC, datetime

# A season. Deliberately longer than the weekly check-in loop: acting on this prompt
# means re-answering the intake, which is real work — quarterly is an invitation,
# monthly would be a chore.
RECALIBRATION_AFTER_DAYS = 90


def parse_created_at(value: object) -> datetime | None:
    """Read a row's ``created_at``: a datetime from Postgres, an ISO string from the
    Supabase JSON client and FakeDatabase. Anything else is None — unknown age."""
    if isinstance(value, datetime):
        return _aware(value)
    if isinstance(value, str):
        try:
            return _aware(datetime.fromisoformat(value))
        except ValueError:
            return None
    return None


def protocol_age_days(created_at: datetime | None, *, now: datetime | None = None) -> int | None:
    """Whole days since the protocol was written; None when the time is unknown."""
    if created_at is None:
        return None
    reference = _aware(now) if now is not None else datetime.now(UTC)
    return (reference - _aware(created_at)).days


def needs_recalibration(created_at: datetime | None, *, now: datetime | None = None) -> bool:
    """True once the active protocol is ``RECALIBRATION_AFTER_DAYS`` old or older.

    Unknown creation time -> False. The prompt tells the user something about their
    own data, so it may only fire on a fact; guessing from a missing timestamp would
    put a claim on screen we cannot back.
    """
    age = protocol_age_days(created_at, now=now)
    return age is not None and age >= RECALIBRATION_AFTER_DAYS


def _aware(value: datetime) -> datetime:
    """Naive timestamps are read as UTC. The column is timestamptz, so a naive value
    only reaches us from a backend that dropped the offset — comparing it to an aware
    ``now`` would raise rather than degrade."""
    return value if value.tzinfo else value.replace(tzinfo=UTC)
