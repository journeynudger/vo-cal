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


def _has_client_capture(row: dict[str, Any]) -> bool:
    return row.get("client_capture_id") is not None


def _is_live_client_meal(row: dict[str, Any]) -> bool:
    # Mirrors the partial index WHERE client_meal_id IS NOT NULL AND deleted_at IS NULL.
    # A tombstoned row leaves the index, freeing the slot so an outbox replay that
    # crosses a delete re-logs cleanly instead of colliding with the tombstone (RT-12).
    return row.get("client_meal_id") is not None and row.get("deleted_at") is None


def _has_client_water(row: dict[str, Any]) -> bool:
    return row.get("client_water_id") is not None


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
    ) -> list[dict[str, Any]]:
        builder = self._client.table(table).select("*")
        for column, value in (filters or {}).items():
            builder = builder.eq(column, value)
        if user_id is not None and table not in _SHARED_TABLES:
            builder = builder.eq(_owner_column(table), str(user_id))
        response = await builder.execute()
        return response.data or []

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
        response = await builder.execute()
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

    def _enforce_unique(self, table: str, candidate: dict[str, Any]) -> None:
        """Reject inserts that collide on a declared UNIQUE index (mirrors Postgres).

        Only checked on insert: the sole update path is tombstoning (sets
        deleted_at), which removes a row from the partial index — it can only
        relax uniqueness, never create a collision.
        """
        for columns, admits in _UNIQUE_INDEXES.get(table, ()):
            if not admits(candidate):
                continue
            for existing in self._rows(table):
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
    ) -> list[dict[str, Any]]:
        rows = self._scope(table, self._rows(table), user_id)
        rows = [row for row in rows if self._matches(row, filters or {})]
        return copy.deepcopy(rows)

    async def update(
        self,
        table: str,
        filters: dict[str, Any],
        values: dict[str, Any],
        *,
        user_id: uuid.UUID | None = None,
    ) -> list[dict[str, Any]]:
        updated: list[dict[str, Any]] = []
        for row in self._scope(table, self._rows(table), user_id):
            if self._matches(row, filters):
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
