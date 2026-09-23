"""Database seam — the single interface stores talk through.

Two implementations of one small contract:

- ``Database``      — wraps a Supabase client (production / live-db tests).
- ``FakeDatabase``  — in-memory dict-of-tables (the entire offline test suite).

Why a seam instead of mocking the Supabase SDK: stores receive a database by
dependency injection, so tests exercise real store logic against deterministic
in-memory state with zero network access. FakeDatabase also mirrors RLS
semantics — owner scoping by user_id — so tenant-isolation bugs surface in the
offline suite, not only against a live database.
"""

from __future__ import annotations

import copy
import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any, Protocol

from postgrest.exceptions import APIError

# Tables whose owner column is not "user_id".
_OWNER_COLUMN_OVERRIDES: dict[str, str] = {"profiles": "id"}

# Shared reference tables: readable by any authenticated user, no owner scoping
# (mirrors the read-for-authenticated RLS policies in the initial migration).
_SHARED_TABLES: frozenset[str] = frozenset({"food_dictionary", "usda_cache"})

# Postgres SQLSTATE for a unique_violation (raised by postgrest as APIError.code).
_PG_UNIQUE_VIOLATION = "23505"

# A range or null test pushed into the query: (column, operator, value). Operators are the
# PostgREST ones the stores need; a timestamp value is passed as its ISO string and compared
# as an instant on both backends (Postgres parses timestamptz; the fake parses the string).
# Requirement (restructure findings, F6 unbounded reads): a day view or a window read must
# not pull a user's whole history into Python to keep a day of it.
Where = list[tuple[str, str, Any]]
_RANGE_OPERATORS = frozenset({"gte", "gt", "lte", "lt", "is_null", "not_null"})


def _has_client_capture(row: dict[str, Any]) -> bool:
    return row.get("client_capture_id") is not None


def _is_live_client_meal(row: dict[str, Any]) -> bool:
    # Mirrors the partial index WHERE client_meal_id IS NOT NULL AND deleted_at IS NULL.
    # A tombstoned row leaves the index, freeing the slot so an outbox replay that
    # crosses a delete re-logs cleanly instead of colliding with the tombstone (RT-12).
    return row.get("client_meal_id") is not None and row.get("deleted_at") is None


def _has_client_water(row: dict[str, Any]) -> bool:
    return row.get("client_water_id") is not None


def _is_active_protocol(row: dict[str, Any]) -> bool:
    # Mirrors idx_one_active_protocol: UNIQUE (user_id) WHERE active. Without this,
    # concurrent generate/revise stored TWO active rows offline (get_active then
    # returns an arbitrary one) while prod Postgres 500s — the exact ships-green
    # divergence this table exists to prevent.
    return bool(row.get("active"))


def _always(_row: dict[str, Any]) -> bool:
    # Non-partial UNIQUE (usda_cache.query_key): every row participates.
    return True


# Declared UNIQUE indexes, mirrored so the offline suite reproduces production
# dedup/idempotency semantics (RT-31). Without this FakeDatabase appended duplicate
# rows while Postgres rejected them, so dedup regressions shipped green offline.
# Each entry pairs the unique columns with a predicate mirroring the index's partial
# WHERE clause — only rows the predicate admits participate. Covers the
# idempotency-critical tables; keep in lockstep with supabase/migrations/*.
_UNIQUE_INDEXES: dict[str, list[tuple[tuple[str, ...], Callable[[dict[str, Any]], bool]]]] = {
    "captures": [(("user_id", "client_capture_id"), _has_client_capture)],
    "meal_logs": [(("user_id", "client_meal_id"), _is_live_client_meal)],
    "water_logs": [(("user_id", "client_water_id"), _has_client_water)],
    "protocols": [(("user_id",), _is_active_protocol)],
    "usda_cache": [(("query_key",), _always)],
}


def _owner_column(table: str) -> str:
    return _OWNER_COLUMN_OVERRIDES.get(table, "user_id")


class UniqueViolationError(Exception):
    """A write would violate a declared UNIQUE index.

    Both backends raise THIS type on a unique-constraint conflict — FakeDatabase
    models the declared indexes (see ``_UNIQUE_INDEXES``) and ``Database`` maps
    Postgres error 23505 onto it — so idempotency handlers catch one error type
    regardless of which backend is wired (RT-08/12/13/31). Why: stores were
    returning a duplicate row on Fake but 500ing on Postgres, so dedup
    regressions shipped green offline.
    """

    def __init__(self, table: str, columns: tuple[str, ...] = ()) -> None:
        self.table = table
        self.columns = columns
        detail = f" {list(columns)}" if columns else ""
        super().__init__(f"unique violation on {table}{detail}")


class SupportsDatabase(Protocol):
    """What stores are allowed to ask of a database.

    ``user_id`` is the RLS-style scope: when provided, reads and writes are
    restricted to rows owned by that user (except shared reference tables).
    """

    async def insert(self, table: str, row: dict[str, Any]) -> dict[str, Any]: ...

    async def select(
        self,
        table: str,
        filters: dict[str, Any] | None = None,
        *,
        user_id: uuid.UUID | None = None,
        where: Where | None = None,
        order_by: str | None = None,
        descending: bool = False,
        limit: int | None = None,
    ) -> list[dict[str, Any]]: ...

    async def update(
        self,
        table: str,
        filters: dict[str, Any],
        values: dict[str, Any],
        *,
        user_id: uuid.UUID | None = None,
    ) -> list[dict[str, Any]]: ...

    async def delete(
        self,
        table: str,
        filters: dict[str, Any],
        *,
        user_id: uuid.UUID | None = None,
    ) -> int: ...

    async def select_owned_via(
        self,
        table: str,
        *,
        parent_table: str,
        parent_key: str,
        user_id: uuid.UUID,
        filters: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]: ...


class Database:
    """Supabase-backed implementation.

    Constructor takes a Supabase (or InstrumentedSupabaseClient-wrapped) async
    client. The explicit ``user_id`` filter is applied even though RLS also
    enforces it server-side — the API often runs with the service-role key
    (which bypasses RLS), so scoping must not depend on the connection's role.
    """

    def __init__(self, client: Any) -> None:
        self._client = client

    async def insert(self, table: str, row: dict[str, Any]) -> dict[str, Any]:
        try:
            response = await self._client.table(table).insert(row).execute()
        except APIError as exc:
            # Map a Postgres unique_violation onto the seam's typed error so
            # idempotency handlers catch one type across both backends (RT-08/12/13).
            if exc.code == _PG_UNIQUE_VIOLATION:
                raise UniqueViolationError(table) from exc
            raise
        return response.data[0]

    async def select(
        self,
        table: str,
        filters: dict[str, Any] | None = None,
        *,
        user_id: uuid.UUID | None = None,
        where: Where | None = None,
        order_by: str | None = None,
        descending: bool = False,
        limit: int | None = None,
    ) -> list[dict[str, Any]]:
        builder = self._client.table(table).select("*")
        for column, value in (filters or {}).items():
            builder = builder.eq(column, value)
        for column, operator, value in where or []:
            if operator not in _RANGE_OPERATORS:
                raise ValueError(f"unsupported where operator: {operator}")
            if operator == "is_null":
                builder = builder.is_(column, "null")
            elif operator == "not_null":
                builder = builder.not_.is_(column, "null")
            else:
                builder = getattr(builder, operator)(column, value)
        if user_id is not None and table not in _SHARED_TABLES:
            builder = builder.eq(_owner_column(table), str(user_id))
        if order_by is not None:
            builder = builder.order(order_by, desc=descending)
        if limit is not None:
            builder = builder.limit(limit)
        response = await builder.execute()
        return response.data or []

    async def select_owned_via(
        self,
        table: str,
        *,
        parent_table: str,
        parent_key: str,
        user_id: uuid.UUID,
        filters: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        """Rows of ``table`` whose ``parent_key`` references a ``parent_table`` row the user owns.

        A table with no owner column of its own (corrections hang off meal_logs) is scoped
        through its parent in ONE query: a PostgREST inner embed filtered on the parent's
        owner column. No other tenant's rows leave the database; isolation is decided by
        the query, never by a Python filter over everyone's rows.
        """
        owner = _owner_column(parent_table)
        builder = self._client.table(table).select(f"*, {parent_table}!inner({owner})")
        builder = builder.eq(f"{parent_table}.{owner}", str(user_id))
        for column, value in (filters or {}).items():
            builder = builder.eq(column, value)
        response = await builder.execute()
        rows = [row for row in (response.data or []) if row.get(parent_key) is not None]
        for row in rows:
            row.pop(parent_table, None)
        return rows

    async def update(
        self,
        table: str,
        filters: dict[str, Any],
        values: dict[str, Any],
        *,
        user_id: uuid.UUID | None = None,
    ) -> list[dict[str, Any]]:
        builder = self._client.table(table).update(values)
        for column, value in filters.items():
            builder = builder.eq(column, value)
        if user_id is not None and table not in _SHARED_TABLES:
            builder = builder.eq(_owner_column(table), str(user_id))
        try:
            response = await builder.execute()
        except APIError as exc:
            # An UPDATE can hit a partial unique index too (the protocols zero-active
            # heal re-activates a row via update and can race a concurrent generate) —
            # map 23505 the same way insert does so callers catch one type (RT-31).
            if exc.code == _PG_UNIQUE_VIOLATION:
                raise UniqueViolationError(table) from exc
            raise
        return response.data or []

    async def delete(
        self,
        table: str,
        filters: dict[str, Any],
        *,
        user_id: uuid.UUID | None = None,
    ) -> int:
        builder = self._client.table(table).delete()
        for column, value in filters.items():
            builder = builder.eq(column, value)
        if user_id is not None and table not in _SHARED_TABLES:
            builder = builder.eq(_owner_column(table), str(user_id))
        response = await builder.execute()
        return len(response.data or [])


class FakeDatabase:
    """In-memory dict-of-tables implementation for the offline test suite.

    Semantics intentionally mirror RLS owner scoping: when ``user_id`` is
    given, only rows whose owner column equals that user are visible/mutable.
    Rows missing the owner column never match — deny by default, like RLS.
    """

    def __init__(self) -> None:
        self.tables: dict[str, list[dict[str, Any]]] = {}

    def _rows(self, table: str) -> list[dict[str, Any]]:
        return self.tables.setdefault(table, [])

    @staticmethod
    def _matches(row: dict[str, Any], filters: dict[str, Any]) -> bool:
        return all(row.get(column) == value for column, value in filters.items())

    def _scope(
        self, table: str, rows: list[dict[str, Any]], user_id: uuid.UUID | None
    ) -> list[dict[str, Any]]:
        if user_id is None or table in _SHARED_TABLES:
            return rows
        owner = _owner_column(table)
        return [row for row in rows if row.get(owner) == str(user_id)]

    async def insert(self, table: str, row: dict[str, Any]) -> dict[str, Any]:
        stored = copy.deepcopy(row)
        stored.setdefault("id", str(uuid.uuid4()))
        stored.setdefault("created_at", datetime.now(UTC).isoformat())
        self._enforce_unique(table, stored)
        self._rows(table).append(stored)
        return copy.deepcopy(stored)

    def _enforce_unique(
        self, table: str, candidate: dict[str, Any], *, exclude: dict[str, Any] | None = None
    ) -> None:
        """Reject writes that collide on a declared UNIQUE index (mirrors Postgres).

        Checked on insert AND on update: updates used to be exempt ("the sole
        update path is tombstoning"), but the protocols zero-active heal now
        re-activates a row via update, which can race a concurrent generate into
        the partial index exactly like an insert. ``exclude`` is the stored row
        being updated, skipped by OBJECT identity (a row never collides with
        itself; matching by "id" broke on test-seeded rows without one).
        """
        for columns, admits in _UNIQUE_INDEXES.get(table, ()):
            if not admits(candidate):
                continue
            for existing in self._rows(table):
                if existing is exclude:
                    continue
                if admits(existing) and all(
                    existing.get(column) == candidate.get(column) for column in columns
                ):
                    raise UniqueViolationError(table, columns)

    async def select(
        self,
        table: str,
        filters: dict[str, Any] | None = None,
        *,
        user_id: uuid.UUID | None = None,
        where: Where | None = None,
        order_by: str | None = None,
        descending: bool = False,
        limit: int | None = None,
    ) -> list[dict[str, Any]]:
        rows = self._scope(table, self._rows(table), user_id)
        rows = [row for row in rows if self._matches(row, filters or {})]
        for column, operator, value in where or []:
            if operator not in _RANGE_OPERATORS:
                raise ValueError(f"unsupported where operator: {operator}")
            rows = [row for row in rows if _where_matches(row.get(column), operator, value)]
        if order_by is not None:
            # Timestamps order as instants, never as strings: "...T09:00-05:00" sorts before
            # "...T10:00+00:00" as text and is the later instant (the meals store's own lesson).
            rows = sorted(rows, key=lambda row: _sort_key(row.get(order_by)), reverse=descending)
        if limit is not None:
            rows = rows[: max(0, limit)]
        return copy.deepcopy(rows)

    async def select_owned_via(
        self,
        table: str,
        *,
        parent_table: str,
        parent_key: str,
        user_id: uuid.UUID,
        filters: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        parents = {
            row.get("id") for row in self._scope(parent_table, self._rows(parent_table), user_id)
        }
        rows = [
            row
            for row in self._rows(table)
            if row.get(parent_key) in parents and self._matches(row, filters or {})
        ]
        return copy.deepcopy(rows)

    async def update(
        self,
        table: str,
        filters: dict[str, Any],
        values: dict[str, Any],
        *,
        user_id: uuid.UUID | None = None,
    ) -> list[dict[str, Any]]:
        matched = [
            row
            for row in self._scope(table, self._rows(table), user_id)
            if self._matches(row, filters)
        ]
        # Check every would-be result against the declared unique indexes BEFORE
        # mutating anything, so a violating update rejects atomically (like Postgres).
        for row in matched:
            candidate = {**row, **values}
            self._enforce_unique(table, candidate, exclude=row)
        updated: list[dict[str, Any]] = []
        for row in matched:
            row.update(copy.deepcopy(values))
            updated.append(copy.deepcopy(row))
        return updated

    async def delete(
        self,
        table: str,
        filters: dict[str, Any],
        *,
        user_id: uuid.UUID | None = None,
    ) -> int:
        rows = self._rows(table)
        doomed = {
            id(row)
            for row in self._scope(table, rows, user_id)
            if self._matches(row, filters)
        }
        kept = [row for row in rows if id(row) not in doomed]
        removed = len(rows) - len(kept)
        self.tables[table] = kept
        return removed


def _as_instant(value: Any) -> datetime | None:
    """A timestamp string as an aware instant, else None (Postgres compares timestamptz the
    same way; a naive string is read as UTC, which is what every row this API writes is)."""
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=UTC)
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value)
        except ValueError:
            return None
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)
    return None


def _where_matches(stored: Any, operator: str, value: Any) -> bool:
    if operator == "is_null":
        return stored is None
    if operator == "not_null":
        return stored is not None
    if stored is None:
        return False  # SQL: a comparison with NULL is never true
    left, right = _as_instant(stored), _as_instant(value)
    if left is None or right is None:
        left, right = stored, value
    if operator == "gte":
        return left >= right
    if operator == "gt":
        return left > right
    if operator == "lte":
        return left <= right
    return left < right


def _sort_key(value: Any) -> tuple[int, Any]:
    # Nulls sort first (Postgres default for ascending is nulls last, but no store orders a
    # nullable column); instants before raw values so a mixed column still sorts.
    if value is None:
        return (0, "")
    instant = _as_instant(value)
    return (1, instant) if instant is not None else (2, str(value))
