"""Durable-truth access for: admin_reviews, admin_audit_log + read-only joins.

Stores answer "what is durably true?" — no planning, no side effects beyond
the database (AGENTS.md, deep couplings).

Admin reads are NOT user-scoped: one reviewer audits every user's logs, so the
Database seam is called with ``user_id=None`` (service-role bypasses RLS; the
admin tables themselves have RLS-on/no-policies, so only service-role touches
them). Auditability (AGENTS.md #7) is preserved by ``write_audit`` — the router
writes an audit row before every detail/audio read.

The heavy compute (chain assembly, aggregates) lives in module-level **pure
functions** taking plain row lists. The store does I/O; the pure functions are
imported by both the router and ``scripts/review`` and are verifiable offline
with no database (script ``--selftest``, ``test_admin_store``).
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import uuid4

from ..db import SupportsDatabase


def _parse_dt(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


# ---------------------------------------------------------------------------
# Pure helpers — assembly + aggregates over plain row lists (offline-testable)
# ---------------------------------------------------------------------------


def filter_logs(
    meals: list[dict[str, Any]],
    corrections: list[dict[str, Any]],
    parses: list[dict[str, Any]],
    *,
    low_confidence: bool = False,
    has_corrections: bool = False,
    question_asked: bool | None = None,
    user_id: str | None = None,
    start: datetime | None = None,
    end: datetime | None = None,
    confidence_threshold: float = 0.8,
) -> list[dict[str, Any]]:
    """Filter + summarize meal_logs for the review queue.

    Returns lightweight summary dicts (the shape ``LogSummary`` consumes), newest
    first. ``question_asked`` is derived from the parse payload's ``questions``
    list (decision #29: one check per material ingredient).
    """
    corr_count: dict[str, int] = {}
    for c in corrections:
        mid = c.get("meal_log_id")
        if mid is not None:
            corr_count[mid] = corr_count.get(mid, 0) + 1

    questions_by_parse: dict[str, int] = {}
    for p in parses:
        payload = p.get("payload") or {}
        questions = (payload.get("result") or {}).get("questions") or []
        questions_by_parse[p["id"]] = len(questions)

    out: list[dict[str, Any]] = []
    for m in meals:
        if m.get("deleted_at"):
            continue
        if user_id is not None and m.get("user_id") != user_id:
            continue
        logged = _parse_dt(m["logged_at"])
        if start is not None and logged < start:
            continue
        if end is not None and logged >= end:
            continue

        confidence = float(m.get("confidence") or 0.0)
        n_corrections = corr_count.get(m["id"], 0)
        parse_id = m.get("parse_id")
        n_questions = questions_by_parse.get(parse_id, 0) if parse_id else 0
        asked = n_questions > 0

        if low_confidence and confidence >= confidence_threshold:
            continue
        if has_corrections and n_corrections == 0:
            continue
        if question_asked is not None and asked != question_asked:
            continue

        out.append(
            {
                "id": m["id"],
                "user_id": m.get("user_id"),
                "name": m.get("name"),
                "meal_type": m.get("meal_type"),
                "logged_at": m["logged_at"],
                "confidence": confidence,
                "corrections_count": n_corrections,
                "question_asked": asked,
                "item_count": len(m.get("items") or []),
            }
        )

    out.sort(key=lambda r: r["logged_at"], reverse=True)
    return out


def assemble_chain(
    meal: dict[str, Any],
    parse: dict[str, Any] | None,
    corrections: list[dict[str, Any]],
    capture: dict[str, Any] | None,
    metrics: list[dict[str, Any]],
) -> dict[str, Any]:
    """Join one meal_log with its parse payload, corrections, capture, metrics.

    Pure: the router supplies rows fetched through the store and the signed audio
    URL separately (storage is a side effect, not durable truth). The corrections
    are sorted into a stable, field-level diff for the reviewer.
    """
    payload = (parse or {}).get("payload") or {}
    result = payload.get("result") or {}
    parsed_meal = payload.get("parsed_meal") or {}

    diff = sorted(
        (
            {
                "item_index": c.get("item_index"),
                "field": c.get("field"),
                "parsed_value": c.get("parsed_value"),
                "confirmed_value": c.get("confirmed_value"),
            }
            for c in corrections
            if c.get("meal_log_id") == meal["id"]
        ),
        key=lambda d: (d["item_index"] if d["item_index"] is not None else -1, d["field"] or ""),
    )

    return {
        "meal_log_id": meal["id"],
        "user_id": meal.get("user_id"),
        "name": meal.get("name"),
        "meal_type": meal.get("meal_type"),
        "logged_at": meal["logged_at"],
        "confidence": float(meal.get("confidence") or 0.0),
        "confirmed_items": meal.get("items") or [],
        "totals": meal.get("totals") or {},
        "parse_id": meal.get("parse_id"),
        "parse_payload": payload,
        "parse_result": result,
        "parsed_meal": parsed_meal,
        "questions": result.get("questions") or [],
        "corrections": diff,
        "capture_id": (capture or {}).get("id"),
        "audio_path": (capture or {}).get("audio_path"),
        "metrics": [
            {"name": e.get("name"), "value": e.get("value"), "ts": e.get("ts")} for e in metrics
        ],
    }


def correction_rate_by_week(
    meals: list[dict[str, Any]], corrections: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    """Corrected-items / total-items per ISO week (year, week). Oldest week first."""
    corr_by_meal: dict[str, int] = {}
    for c in corrections:
        mid = c.get("meal_log_id")
        if mid is not None:
            corr_by_meal[mid] = corr_by_meal.get(mid, 0) + 1

    buckets: dict[str, dict[str, int]] = {}
    for m in meals:
        if m.get("deleted_at"):
            continue
        iso = _parse_dt(m["logged_at"]).isocalendar()
        key = f"{iso[0]}-W{iso[1]:02d}"
        b = buckets.setdefault(key, {"items": 0, "corrected": 0})
        b["items"] += len(m.get("items") or [])
        b["corrected"] += corr_by_meal.get(m["id"], 0)

    return [
        {
            "week": key,
            "items": b["items"],
            "corrected": b["corrected"],
            "rate": round(b["corrected"] / b["items"], 4) if b["items"] else None,
        }
        for key, b in sorted(buckets.items())
    ]


def confidence_calibration(
    meals: list[dict[str, Any]], corrections: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    """Stated meal confidence vs observed correction rate, in 0.1 buckets.

    The trust check on the trust feature: if 90%-confidence meals get corrected
    30% of the time, the confidence badge is lying. ``corrected`` counts meals
    that received >=1 correction (a meal is "right" or "had to be fixed").
    """
    corrected_meals = {
        c.get("meal_log_id") for c in corrections if c.get("meal_log_id") is not None
    }
    buckets: dict[int, dict[str, int]] = {}
    for m in meals:
        if m.get("deleted_at"):
            continue
        conf = float(m.get("confidence") or 0.0)
        idx = min(int(conf * 10), 9)  # 0.0-0.099 -> 0, ... 0.9-1.0 -> 9
        b = buckets.setdefault(idx, {"meals": 0, "corrected": 0})
        b["meals"] += 1
        if m["id"] in corrected_meals:
            b["corrected"] += 1

    out: list[dict[str, Any]] = []
    for idx in sorted(buckets):
        b = buckets[idx]
        out.append(
            {
                "bucket": f"{idx / 10:.1f}-{(idx + 1) / 10:.1f}",
                "stated_confidence_mid": round(idx / 10 + 0.05, 2),
                "meals": b["meals"],
                "corrected_meals": b["corrected"],
                "observed_correction_rate": round(b["corrected"] / b["meals"], 4)
                if b["meals"]
                else None,
            }
        )
    return out


def question_precision(
    meals: list[dict[str, Any]],
    parses: list[dict[str, Any]],
    corrections: list[dict[str, Any]],
) -> dict[str, Any]:
    """How often an asked question coincided with an actual correction.

    A question was "useful" if the meal that triggered it ended up corrected
    (proxy: the meal received >=1 correction). Precision = useful-asks /
    total-asks. Low precision => the engine is asking noise.
    """
    parse_by_id = {p["id"]: p for p in parses}
    corrected_meals = {
        c.get("meal_log_id") for c in corrections if c.get("meal_log_id") is not None
    }

    asked = 0
    useful = 0
    for m in meals:
        if m.get("deleted_at"):
            continue
        parse_id = m.get("parse_id")
        if not parse_id:
            continue
        payload = (parse_by_id.get(parse_id) or {}).get("payload") or {}
        questions = (payload.get("result") or {}).get("questions") or []
        if not questions:
            continue
        asked += 1
        if m["id"] in corrected_meals:
            useful += 1

    return {
        "meals_with_questions": asked,
        "meals_with_questions_then_corrected": useful,
        "precision": round(useful / asked, 4) if asked else None,
    }


def top_corrected_foods(
    meals: list[dict[str, Any]], corrections: list[dict[str, Any]], *, limit: int = 20
) -> list[dict[str, Any]]:
    """Foods most often corrected — the dictionary-gap list (feeds B1 additions).

    Maps each correction to the confirmed item's name via (meal, item_index).
    A high count means the parser/dictionary keeps getting that food wrong.
    """
    items_by_meal: dict[str, list[dict[str, Any]]] = {
        m["id"]: (m.get("items") or []) for m in meals
    }
    counts: dict[str, dict[str, Any]] = {}
    for c in corrections:
        mid = c.get("meal_log_id")
        idx = c.get("item_index")
        items = items_by_meal.get(mid or "", [])
        name = "?"
        if isinstance(idx, int) and 0 <= idx < len(items):
            name = (items[idx] or {}).get("name") or "?"
        entry = counts.setdefault(name, {"food": name, "corrections": 0, "fields": {}})
        entry["corrections"] += 1
        field = c.get("field") or "?"
        entry["fields"][field] = entry["fields"].get(field, 0) + 1

    ranked = sorted(counts.values(), key=lambda e: e["corrections"], reverse=True)
    return ranked[:limit]


def compute_aggregates(
    meals: list[dict[str, Any]],
    corrections: list[dict[str, Any]],
    parses: list[dict[str, Any]],
) -> dict[str, Any]:
    """All admin aggregates from plain row lists — the offline-testable core."""
    return {
        "correction_rate_by_week": correction_rate_by_week(meals, corrections),
        "confidence_calibration": confidence_calibration(meals, corrections),
        "question_precision": question_precision(meals, parses, corrections),
        "top_corrected_foods": top_corrected_foods(meals, corrections),
    }


# ---------------------------------------------------------------------------
# Store — I/O over the Database seam (admin reads are NOT user-scoped)
# ---------------------------------------------------------------------------


class AdminStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def write_audit(
        self,
        *,
        admin_email: str,
        action: str,
        subject_type: str | None,
        subject_id: str | None,
    ) -> dict[str, Any]:
        """Append an audit row. MUST precede every detail/audio read (#7)."""
        return await self._db.insert(
            "admin_audit_log",
            {
                "id": str(uuid4()),
                "admin_email": admin_email,
                "action": action,
                "subject_type": subject_type,
                "subject_id": subject_id,
            },
        )

    async def insert_review(
        self, *, meal_log_id: str, reviewer: str, verdict: str, notes: str | None
    ) -> dict[str, Any]:
        return await self._db.insert(
            "admin_reviews",
            {
                "id": str(uuid4()),
                "meal_log_id": meal_log_id,
                "reviewer": reviewer,
                "verdict": verdict,
                "notes": notes,
            },
        )

    async def list_logs(
        self,
        *,
        low_confidence: bool = False,
        has_corrections: bool = False,
        question_asked: bool | None = None,
        user_id: str | None = None,
        start: datetime | None = None,
        end: datetime | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> list[dict[str, Any]]:
        """Filtered, paginated review-queue summaries (service-role; no scope).

        Fetches the three relevant tables unscoped (``user_id=None``) and runs
        the pure ``filter_logs`` — the Database seam only does exact-match
        filtering, so range/derived filters live in Python (mirrors
        meals/store.list_between).
        """
        meals = await self._db.select("meal_logs", user_id=None)
        corrections = await self._db.select("corrections", user_id=None)
        parses = await self._db.select("parses", user_id=None)
        rows = filter_logs(
            meals,
            corrections,
            parses,
            low_confidence=low_confidence,
            has_corrections=has_corrections,
            question_asked=question_asked,
            user_id=user_id,
            start=start,
            end=end,
        )
        return rows[offset : offset + limit]

    async def get_log_chain(self, meal_log_id: str) -> dict[str, Any] | None:
        """Assemble the full audit chain for one meal_log (service-role; no scope).

        Returns None when the meal_log does not exist. The caller (router) writes
        an audit row before invoking this, and mints the signed audio URL from
        ``audio_path`` via the Storage seam (a side effect kept out of the store).
        """
        meals = await self._db.select("meal_logs", {"id": meal_log_id}, user_id=None)
        if not meals:
            return None
        meal = meals[0]

        parse = None
        if meal.get("parse_id"):
            parse_rows = await self._db.select("parses", {"id": meal["parse_id"]}, user_id=None)
            parse = parse_rows[0] if parse_rows else None

        corrections = await self._db.select(
            "corrections", {"meal_log_id": meal_log_id}, user_id=None
        )

        capture = None
        if parse and parse.get("capture_id"):
            cap_rows = await self._db.select(
                "captures", {"id": parse["capture_id"]}, user_id=None
            )
            capture = cap_rows[0] if cap_rows else None

        # client_metrics tie to this log via attributes.meal_log_id (or .meal_id).
        all_metrics = await self._db.select("client_metrics", user_id=None)
        metrics = [
            e
            for e in all_metrics
            if (e.get("attributes") or {}).get("meal_log_id") == meal_log_id
            or (e.get("attributes") or {}).get("meal_id") == meal_log_id
        ]

        return assemble_chain(meal, parse, corrections, capture, metrics)

    async def aggregates(self) -> dict[str, Any]:
        """All aggregates over every user's data (service-role; no scope)."""
        meals = await self._db.select("meal_logs", user_id=None)
        corrections = await self._db.select("corrections", user_id=None)
        parses = await self._db.select("parses", user_id=None)
        return compute_aggregates(meals, corrections, parses)
