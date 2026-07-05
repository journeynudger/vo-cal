"""/__dev — the agent skeleton keys. LOCAL DEVELOPMENT ONLY.

Every place a headless agent would have to guess (how to authenticate, how to get a
"spoken" meal into the pipeline with no microphone, whether the environment is actually
wired) gets an endpoint instead.

HARD SECURITY GATE (three layers, all required):
  1. The router is mounted ONLY when ``settings.dev_endpoints`` is true (env
     DEV_ENDPOINTS=true). Unset => every /__dev/* path is a plain 404 (tested).
  2. Boot guard: ``main._refuse_dev_surfaces_against_hosted_db`` refuses to START the app
     when DEV_ENDPOINTS is set against a non-local Supabase — the failure class (dev
     surfaces + real user data) is stopped at startup, loudly, same pattern as the
     X-Test-User seam guard.
  3. Nothing here mints credentials: /log-me-in returns the X-Test-User header VALUE,
     which only means anything when TEST_MODE+DEBUG are also set — themselves refused
     against hosted databases.

Design rule: these endpoints call the REAL route functions (parser.router.parse,
meals.router.log_meal) — never re-implement the pipeline, so what an agent exercises is
what users get.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from uuid import UUID, uuid4

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from ..config import settings
from ..dependencies import Db
from ..meals.router import log_meal
from ..meals.schemas import ConfirmedItem, LogMealRequest, MealLog
from ..parser.router import get_parser_client, get_resolver, parse
from ..parser.schemas import ParseRequest, ParseResult

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/__dev", tags=["dev"])

# Seeded identities (supabase/seed.sql). The manifest is the source of truth so scripts,
# seeds, and this router can't drift apart; fall back to the canonical pair if missing.
_SEED_MANIFEST = Path(__file__).resolve().parents[5] / ".agents" / "seed-users.json"
_FALLBACK_USERS = {
    "dev@vo-cal.test": "11111111-1111-1111-1111-111111111111",
    "fresh@vo-cal.test": "22222222-2222-2222-2222-222222222222",
}


def _seed_users() -> dict[str, str]:
    try:
        data = json.loads(_SEED_MANIFEST.read_text())
        return {u["email"]: u["user_id"] for u in data["users"]}
    except Exception:  # missing manifest in a container — fall back to the canonical pair
        return dict(_FALLBACK_USERS)


@router.get("")
async def index() -> dict:
    """Self-documenting: every dev endpoint and what it's for."""
    return {
        "warning": "LOCAL DEV ONLY — mounted because DEV_ENDPOINTS=true",
        "endpoints": {
            "GET /__dev": "this listing",
            "GET /__dev/preflight": "readiness report: db/providers/seeds, pass/fail + why",
            "GET /__dev/log-me-in/{email}": "auth header for a seeded user (X-Test-User seam)",
            "POST /__dev/log-me-out": "how to clear it (stateless — stop sending the header)",
            "POST /__dev/capture": '{"text": "...", "email"?, "confirm"?} -> REAL parse (+store)',
            "GET /__dev/db/summary": "?email= — recent meals + protocol + counts, no psql needed",
        },
        "seed_users": _seed_users(),
    }


# -- auth ----------------------------------------------------------------------


@router.get("/log-me-in/{email}")
async def log_me_in(email: str) -> dict:
    """The dev 'session': the X-Test-User header value for a seeded user.

    The header is honored only when TEST_MODE=true and DEBUG=true (auth seam), which the
    boot guard confines to local databases. No token is minted; nothing to expire.
    """
    users = _seed_users()
    if email not in users:
        raise HTTPException(
            status.HTTP_404_NOT_FOUND,
            f"unknown seed user {email!r} — seeded: {sorted(users)} (see .agents/seed-users.json)",
        )
    if not (settings.test_mode and settings.debug):
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "the X-Test-User seam is off: start the server with TEST_MODE=true DEBUG=true "
            "(scripts/ensure-dev-server.sh does this)",
        )
    return {
        "email": email,
        "user_id": users[email],
        "use_header": {"X-Test-User": users[email]},
        "example": f'curl -H "X-Test-User: {users[email]}" http://127.0.0.1:8000/meals/today?date=YYYY-MM-DD',
    }


@router.post("/log-me-out")
async def log_me_out() -> dict:
    return {"ok": True, "note": "the dev session is just the X-Test-User header — stop sending it"}


# -- the voice bypass ------------------------------------------------------------


class DevCaptureRequest(BaseModel):
    """A 'spoken meal' as text. Runs the REAL transcript->parse pipeline (and, with
    confirm=true, the REAL meal-store path) exactly as a voice capture's transcript would."""

    text: str = Field(min_length=1, max_length=4000)
    email: str = "dev@vo-cal.test"
    confirm: bool = True  # also store to meal_logs (the full 'logged' rung)
    meal_type: str = "unspecified"


class DevCaptureResponse(BaseModel):
    user_id: str
    parse: ParseResult
    stored_meal: MealLog | None = None


@router.post("/capture", response_model=DevCaptureResponse)
async def dev_capture(req: DevCaptureRequest, db: Db) -> DevCaptureResponse:
    """No-microphone meal capture: text -> REAL /parse -> (optionally) REAL /meals confirm.

    Mirrors the app's derived pipeline from the transcript onward (a transcription output
    IS a string, so this is the true seam). [audio]/[transcript] stages are skipped by
    definition; parse/store emit their normal [parse]/[store] log lines, so one grep in
    .logs/server.log follows this capture like any other.
    """
    users = _seed_users()
    if req.email not in users:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"unknown seed user {req.email!r}")
    user_id = UUID(users[req.email])

    logger.info("[transcript] dev-capture text=%r user=%s (mic bypass)", req.text[:80], user_id)
    parse_result = await parse(
        ParseRequest(transcript=req.text),
        user_id,
        db,
        get_parser_client(),
        get_resolver(db),
    )

    stored: MealLog | None = None
    if req.confirm and parse_result.items:
        confirmed = [
            ConfirmedItem(
                name=i.name, amount=i.amount, unit=i.unit, state=i.state,
                fat_ratio=i.fat_ratio, variant=i.variant, brand=i.brand,
                prep_method=i.prep_method, grams=i.grams, macros=i.macros,
                confidence=i.confidence, source=i.source, is_estimate=i.is_estimate,
            )
            for i in parse_result.items
        ]
        stored = await log_meal(
            LogMealRequest(
                client_meal_id=f"dev-capture-{uuid4()}",
                parse_id=parse_result.parse_id,
                name=None,
                meal_type=req.meal_type,  # pydantic coerces to MealType
                items=confirmed,
            ),
            user_id,
            db,
        )
    return DevCaptureResponse(user_id=str(user_id), parse=parse_result, stored_meal=stored)


# -- readiness -------------------------------------------------------------------


@router.get("/preflight")
async def preflight(db: Db) -> dict:
    """One curl instead of guessing: what's wired, what's fake, what's missing."""

    def check(ok: bool, why: str) -> dict:
        return {"ok": ok, "why": why}

    checks: dict[str, dict] = {}

    # Database: real Supabase vs in-memory fake (fake = nothing persists!).
    fake_db = type(db).__name__ == "FakeDatabase"
    checks["database"] = check(
        True,
        "FakeDatabase (in-memory — nothing survives restart; start docker + setup-dev for real db)"
        if fake_db else f"real database via {settings.supabase_url}",
    )
    checks["database"]["fake"] = fake_db

    # Seed users present (only meaningful on a real db).
    users = _seed_users()
    dev_uuid = users.get("dev@vo-cal.test", "")
    if fake_db:
        checks["seed_user"] = check(True, "FakeDatabase — seeds don't apply; /__dev/capture still works")
    else:
        rows = await db.select("profiles", {"id": dev_uuid})
        meals = await db.select("meal_logs", user_id=UUID(dev_uuid)) if rows else []
        checks["seed_user"] = check(
            bool(rows) and len(meals) > 0,
            f"dev@vo-cal.test profile={'present' if rows else 'MISSING'}, meals={len(meals)}"
            + ("" if rows else " — run scripts/setup-dev.sh"),
        )

    # Auth seam.
    checks["auth_seam"] = check(
        settings.test_mode and settings.debug,
        "X-Test-User seam on (TEST_MODE+DEBUG)" if settings.test_mode and settings.debug
        else "seam OFF — /__dev/log-me-in headers won't authenticate; use ensure-dev-server.sh",
    )

    # Parse provider: real LLM vs recorded fake.
    client_kind = type(get_parser_client()).__name__
    checks["parse_provider"] = check(
        True,
        f"{client_kind}"
        + (" (RECORDED FIXTURES — only known transcripts parse; set ANTHROPIC_API_KEY + unset TEST_MODE for live)"
           if client_kind == "FakeParserClient" else f" (live: {settings.parser_provider}/{settings.parser_model})"),
    )
    checks["parse_provider"]["fake"] = client_kind == "FakeParserClient"

    # Transcription provider (only used by the real audio path; /__dev/capture bypasses it).
    has_stt = bool(settings.elevenlabs_api_key)
    checks["transcription_provider"] = check(
        True,
        "ElevenLabs key set (live STT)" if has_stt
        else "no ELEVENLABS_API_KEY — FakeTranscriber (audio uploads get a canned transcript; /__dev/capture unaffected)",
    )
    checks["transcription_provider"]["fake"] = not has_stt

    checks["usda_fdc"] = check(
        True,
        "FDC key set (long-tail foods live)" if settings.usda_fdc_api_key
        else "no USDA_FDC_API_KEY — dictionary-only + estimator fallback",
    )

    all_ok = all(c["ok"] for c in checks.values())
    return {"ok": all_ok, "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "checks": checks}


# -- state introspection ----------------------------------------------------------


@router.get("/db/summary")
async def db_summary(db: Db, email: str = "dev@vo-cal.test") -> dict:
    """Recent state for a seeded user without opening psql (read-only)."""
    users = _seed_users()
    if email not in users:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"unknown seed user {email!r}")
    uid = UUID(users[email])

    meals = await db.select("meal_logs", user_id=uid)
    meals.sort(key=lambda r: r.get("logged_at") or "", reverse=True)
    protocols = await db.select("protocols", {"active": True}, user_id=uid)
    water = await db.select("water_logs", user_id=uid)
    parses = await db.select("parses", user_id=uid)

    return {
        "email": email,
        "user_id": str(uid),
        "counts": {
            "meal_logs": len(meals),
            "water_logs": len(water),
            "parses": len(parses),
            "active_protocol": len(protocols),
        },
        "active_protocol_targets": (protocols[0].get("targets") if protocols else None),
        "recent_meals": [
            {
                "id": m.get("id"),
                "name": m.get("name"),
                "meal_type": m.get("meal_type"),
                "kcal": (m.get("totals") or {}).get("kcal"),
                "confidence": m.get("confidence"),
                "logged_at": m.get("logged_at"),
                "deleted": bool(m.get("deleted_at")),
            }
            for m in meals[:10]
        ],
    }
