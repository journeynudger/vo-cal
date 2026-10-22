"""The person's record, as a file they can take with them (decision 64; the Rams review, Q5).

Everything the person owns, owner-scoped, in one JSON document: profile, intake answers,
protocols, how they track, meals (live, with their items), water, usuals, their own foods,
check-ins, week plans, the transcripts of what they said, the parses read from them and the
corrections they made (append-only, decision 5: the audit trail is part of the record). Captures
(the audio and photos) stay where they are: a signed-URL bulk download is its own task; the
transcript is the part of a capture a person reads. ``user_id`` is stripped from every row, and
the profile's ``id`` (which is the same identifier): the file is theirs, the id is ours. Every
table is read page by page (db.every_row): one select stops at PostgREST's 1000-row cap. A CSV
of the meals exists for the spreadsheet-minded; one table, one shape.
"""

from __future__ import annotations

import csv
import io
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from ..db import SupportsDatabase, every_row

EXPORT_FORMAT = 1

# (table, key in the export, extra filters). Tables the person owns directly.
_OWNED: tuple[tuple[str, str], ...] = (
    ("intake_responses", "intake"),
    ("protocols", "protocols"),
    ("tracking_preferences", "tracking"),
    ("meal_plans", "meal_plans"),
    ("nudge_reactions", "nudge_reactions"),
    ("water_logs", "water"),
    ("saved_meals", "usuals"),
    ("personal_foods", "foods"),
    ("checkins", "checkins"),
    ("week_plans", "week_plans"),
    ("parses", "parses"),
)

_MEAL_CSV_COLUMNS = ("logged_at", "name", "meal_type", "kcal", "protein", "carbs", "fat", "fiber")


async def build_export(db: SupportsDatabase, user_id: UUID) -> dict[str, Any]:
    """The whole record as one JSON-serializable dict."""
    out: dict[str, Any] = {
        "format": EXPORT_FORMAT,
        "exported_at": datetime.now(UTC).isoformat(),
    }
    profiles = await db.select("profiles", user_id=user_id)
    out["profile"] = {k: v for k, v in _strip(profiles[0]).items() if k != "id"} if profiles else {}
    for table, key in _OWNED:
        rows = await _owned(db, table, user_id)
        out[key] = [_strip(r) for r in sorted(rows, key=_created)]
    meals = await _owned(db, "meal_logs", user_id)
    out["meals"] = [_strip(r) for r in sorted(meals, key=_logged) if not r.get("deleted_at")]
    out["deleted_meals"] = [_strip(r) for r in sorted(meals, key=_logged) if r.get("deleted_at")]
    captures = await _owned(db, "captures", user_id)
    transcripts = await _owned_via(db, "transcripts", "captures", "capture_id", user_id)
    out["transcripts"] = [_strip(r) for r in sorted(transcripts, key=_created)]
    corrections = await _owned_via(db, "corrections", "meal_logs", "meal_log_id", user_id)
    out["corrections"] = [_strip(r) for r in sorted(corrections, key=_created)]
    out["captures"] = [
        {k: v for k, v in _strip(r).items() if k in {"id", "client_capture_id", "created_at", "duration_ms", "content_type", "status"}}
        for r in sorted(captures, key=_created)
    ]
    return out


def meals_csv(export: dict[str, Any]) -> str:
    """The meals table as CSV: one row per meal, the totals as columns."""
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(_MEAL_CSV_COLUMNS)
    for meal in export.get("meals", []):
        totals = meal.get("totals") or {}
        writer.writerow(
            [
                meal.get("logged_at", ""),
                meal.get("name") or "",
                meal.get("meal_type") or "",
                totals.get("kcal", ""),
                totals.get("protein", ""),
                totals.get("carbs", ""),
                totals.get("fat", ""),
                totals.get("fiber", ""),
            ]
        )
    return buf.getvalue()


async def _owned(db: SupportsDatabase, table: str, user_id: UUID) -> list[dict[str, Any]]:
    return await every_row(
        lambda offset, page: db.select(table, {}, user_id=user_id, order_by="id", limit=page, offset=offset)
    )


async def _owned_via(
    db: SupportsDatabase, table: str, parent_table: str, parent_key: str, user_id: UUID
) -> list[dict[str, Any]]:
    return await every_row(
        lambda offset, page: db.select_owned_via(
            table, parent_table=parent_table, parent_key=parent_key, user_id=user_id,
            order_by="id", limit=page, offset=offset,
        )
    )


def _strip(row: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in row.items() if k != "user_id"}


def _created(row: dict[str, Any]) -> str:
    return str(row.get("created_at") or "")


def _logged(row: dict[str, Any]) -> str:
    return str(row.get("logged_at") or row.get("created_at") or "")
