"""Vo-Cal API — application factory (Beacon's main.py, adapted to a factory).

Factory pattern so tests construct isolated apps with an injected FakeDatabase;
the module-level ``app`` (built from settings) is what uvicorn serves.
"""

import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from typing import cast

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware import _MiddlewareFactory

from .account.router import router as account_router
from .admin.router import router as admin_router
from .captures.router import router as captures_router
from .checkin.router import router as checkin_router
from .config import settings
from .db import Database, FakeDatabase, SupportsDatabase
from .errors import register_error_handlers
from .instrumented_client import InstrumentedSupabaseClient
from .intake.router import router as intake_router
from .logging_config import setup_logging
from .meals.router import router as meals_router
from .metrics import metrics_router
from .metrics_ingestion import router as client_metrics_router
from .middleware import ObservabilityMiddleware
from .nutrition.router import router as nutrition_router
from .parser.router import router as parser_router
from .protocols.router import router as protocols_router
from .storage import FakeStorage, SupabaseStorage, SupportsStorage
from .transcribe.router import router as transcribe_router

setup_logging(debug=settings.debug)
logger = logging.getLogger(__name__)


async def _build_database() -> SupportsDatabase:
    """Pick the database implementation from settings.

    With Supabase credentials: real client, instrumented for query timing.
    Without (offline dev, CI): FakeDatabase so the app still boots — clearly
    logged because nothing written to it survives a restart.
    """
    if settings.supabase_url and settings.supabase_service_role_key:
        # Imported lazily: the supabase SDK pulls in network machinery that the
        # offline test path never needs.
        from supabase import acreate_client  # noqa: PLC0415

        client = await acreate_client(settings.supabase_url, settings.supabase_service_role_key)
        return Database(InstrumentedSupabaseClient(client))

    logger.warning("No Supabase credentials configured — using in-memory FakeDatabase")
    return FakeDatabase()


async def _build_storage() -> SupportsStorage:
    """Supabase Storage when credentials exist; in-memory FakeStorage offline."""
    if settings.supabase_url and settings.supabase_service_role_key:
        from supabase import acreate_client  # noqa: PLC0415

        client = await acreate_client(settings.supabase_url, settings.supabase_service_role_key)
        return SupabaseStorage(client)
    return FakeStorage()


def create_app(
    database: SupportsDatabase | None = None,
    storage: SupportsStorage | None = None,
) -> FastAPI:
    """Build the FastAPI app. Pass ``database``/``storage`` to skip Supabase wiring (tests)."""

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncGenerator[None]:
        app.state.db = database if database is not None else await _build_database()
        app.state.storage = storage if storage is not None else await _build_storage()
        yield

    app = FastAPI(
        title="Vo-Cal API",
        debug=settings.debug,
        lifespan=lifespan,
    )

    app.add_middleware(
        cast("_MiddlewareFactory", CORSMiddleware),
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app.add_middleware(cast("_MiddlewareFactory", ObservabilityMiddleware))

    register_error_handlers(app)

    # System routers
    app.include_router(metrics_router)
    app.include_router(client_metrics_router)

    # Domain routers (routes land in Phases B-H)
    app.include_router(intake_router)
    app.include_router(protocols_router)
    app.include_router(captures_router)
    app.include_router(transcribe_router)
    app.include_router(meals_router)
    app.include_router(parser_router)
    app.include_router(nutrition_router)
    app.include_router(checkin_router)
    app.include_router(account_router)
    app.include_router(admin_router)

    @app.get("/health")
    async def health() -> dict:
        """Liveness check. Dependency probes (Supabase ping) land with Phase F."""
        return {"status": "ok"}

    return app


app = create_app()
