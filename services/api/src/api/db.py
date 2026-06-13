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
from datetime import UTC, datetime
from typing import Any, Protocol

# Tables whose owner column is not "user_id".
_OWNER_COLUMN_OVERRIDES: dict[str, str] = {"profiles": "id"}

# Shared reference tables: readable by any authenticated user, no owner scoping
# (mirrors the read-for-authenticated RLS policies in the initial migration).
_SHARED_TABLES: frozenset[str] = frozenset({"food_dictionary", "usda_cache"})


def _owner_column(table: str) -> str:
    return _OWNER_COLUMN_OVERRIDES.get(table, "user_id")


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
        response = await self._client.table(table).insert(row).execute()
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
        self._rows(table).append(stored)
        return copy.deepcopy(stored)

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
