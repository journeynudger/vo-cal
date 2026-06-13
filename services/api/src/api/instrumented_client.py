"""Instrumented Supabase client wrapper for query timing (adapted from Beacon)."""

from __future__ import annotations

import time
from typing import Any

from .metrics import DB_QUERY_DURATION


class InstrumentedTable:
    """Wraps a Supabase table query builder to time execute() calls.

    All chaining methods (.select(), .eq(), .limit(), etc.) are forwarded
    transparently. Only .execute() is intercepted for timing.
    """

    def __init__(self, builder: Any, table_name: str, operation: str = "select") -> None:
        self._builder = builder
        self._table_name = table_name
        self._operation = operation

    def select(self, *args: Any, **kwargs: Any) -> InstrumentedTable:
        self._builder = self._builder.select(*args, **kwargs)
        self._operation = "select"
        return self

    def insert(self, *args: Any, **kwargs: Any) -> InstrumentedTable:
        self._builder = self._builder.insert(*args, **kwargs)
        self._operation = "insert"
        return self

    def update(self, *args: Any, **kwargs: Any) -> InstrumentedTable:
        self._builder = self._builder.update(*args, **kwargs)
        self._operation = "update"
        return self

    def upsert(self, *args: Any, **kwargs: Any) -> InstrumentedTable:
        self._builder = self._builder.upsert(*args, **kwargs)
        self._operation = "upsert"
        return self

    def delete(self) -> InstrumentedTable:
        self._builder = self._builder.delete()
        self._operation = "delete"
        return self

    async def execute(self) -> Any:
        start = time.perf_counter()
        try:
            return await self._builder.execute()
        finally:
            duration = time.perf_counter() - start
            DB_QUERY_DURATION.labels(
                operation=self._operation,
                table=self._table_name,
            ).observe(duration)

    def __getattr__(self, name: str) -> Any:
        """Forward all other chaining methods (.eq, .limit, .order, .maybe_single, etc.)."""
        attr = getattr(self._builder, name)
        if not callable(attr):
            return attr

        def wrapper(*args: Any, **kwargs: Any) -> InstrumentedTable:
            result = attr(*args, **kwargs)
            # If the result is the builder (chaining), keep our wrapper around it
            self._builder = result
            return self

        return wrapper


class InstrumentedSupabaseClient:
    """Wraps a Supabase AsyncClient to instrument .table() calls.

    All other attributes (.auth, .postgrest, .storage, etc.) are forwarded
    to the underlying client transparently.
    """

    def __init__(self, client: Any) -> None:
        self._client = client

    def table(self, table_name: str) -> InstrumentedTable:
        return InstrumentedTable(self._client.table(table_name), table_name)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._client, name)
