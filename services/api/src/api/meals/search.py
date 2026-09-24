"""Search over what the person has logged, for a typed log.

Requirement (Lorenzo, 2026-09-24): typing a meal should offer what he has entered before
as he types. Three sources, one list: usuals (named templates, re-logged by their items),
recent meals (grouped by name), and personal foods (label foods and batch recipes). Pure
ranking here; the router gathers the rows.

Rank: a name that starts with the query, then a word that starts with it, then a
substring; ties by how often it was logged, then by recency. The same name from several
sources collapses to one hit: usual first (it carries items to log at once), then meal,
then personal food.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from ..nutrition.dictionary import normalize_name
from .naming import display_name

MAX_HITS = 8
MIN_QUERY = 1
MAX_QUERY = 60

_KIND_RANK = {"usual": 0, "meal": 1, "personal_food": 2}


@dataclass
class SearchSource:
    kind: str
    id: str
    name: str
    kcal: float | None = None
    last_logged_at: datetime | None = None
    times: int = 1
    items: list[dict[str, Any]] = field(default_factory=list)


def _match_rank(query: str, name: str) -> int | None:
    q = normalize_name(query)
    n = normalize_name(name)
    if not q or not n:
        return None
    if n.startswith(q):
        return 0
    if any(word.startswith(q) for word in n.split()):
        return 1
    if q in n:
        return 2
    return None


def rank(query: str, sources: Sequence[SearchSource], *, limit: int = MAX_HITS) -> list[SearchSource]:
    """The hits for ``query``, best first, one per name."""
    if len(query.strip()) < MIN_QUERY:
        return []
    query = query.strip()[:MAX_QUERY]
    merged: dict[str, SearchSource] = {}
    for source in sources:
        key = normalize_name(source.name)
        if not key:
            continue
        current = merged.get(key)
        if current is None:
            merged[key] = SearchSource(**vars(source))
            continue
        # Same name from another source: keep the better kind, sum the times, keep the
        # latest date and any calorie figure.
        keep = current if _KIND_RANK[current.kind] <= _KIND_RANK[source.kind] else SearchSource(**vars(source))
        keep.times = current.times + source.times
        dates = [d for d in (current.last_logged_at, source.last_logged_at) if d is not None]
        keep.last_logged_at = max(dates) if dates else None
        keep.kcal = keep.kcal if keep.kcal is not None else (current.kcal if current.kcal is not None else source.kcal)
        if not keep.items:
            keep.items = current.items or source.items
        merged[key] = keep

    scored: list[tuple[tuple[int, int, float], SearchSource]] = []
    for source in merged.values():
        match = _match_rank(query, source.name)
        if match is None:
            continue
        recency = source.last_logged_at.timestamp() if source.last_logged_at else 0.0
        scored.append(((match, -source.times, -recency), source))
    scored.sort(key=lambda pair: pair[0])
    return [source for _, source in scored[:limit]]


def sources_from_meals(rows: Sequence[dict[str, Any]]) -> list[SearchSource]:
    """Recent meal rows grouped by display name, newest kept as the id."""
    grouped: dict[str, SearchSource] = {}
    for row in rows:
        name = display_name(row)
        if not name:
            continue
        key = normalize_name(name)
        logged_at = _parse_dt(row.get("logged_at"))
        kcal = _kcal(row.get("totals"))
        current = grouped.get(key)
        if current is None:
            grouped[key] = SearchSource(
                kind="meal", id=str(row.get("id")), name=name, kcal=kcal,
                last_logged_at=logged_at, times=1, items=list(row.get("items") or []),
            )
            continue
        current.times += 1
        if logged_at and (current.last_logged_at is None or logged_at > current.last_logged_at):
            current.last_logged_at = logged_at
            current.id = str(row.get("id"))
            current.kcal = kcal
            current.items = list(row.get("items") or [])
    return list(grouped.values())


def sources_from_usuals(rows: Sequence[dict[str, Any]]) -> list[SearchSource]:
    return [
        SearchSource(
            kind="usual", id=str(row.get("id")), name=str(row.get("name") or ""),
            kcal=_kcal(row.get("totals")), last_logged_at=_parse_dt(row.get("created_at")),
            times=1, items=list(row.get("items") or []),
        )
        for row in rows
        if row.get("name")
    ]


def sources_from_personal_foods(rows: Sequence[dict[str, Any]]) -> list[SearchSource]:
    return [
        SearchSource(
            kind="personal_food", id=str(row.get("id")), name=str(row.get("name") or ""),
            kcal=_kcal(row.get("per_serving")), last_logged_at=_parse_dt(row.get("created_at")),
        )
        for row in rows
        if row.get("name")
    ]


def _kcal(totals: Any) -> float | None:
    if isinstance(totals, dict):
        try:
            return float(totals.get("kcal"))
        except (TypeError, ValueError):
            return None
    return None


def _parse_dt(value: Any) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value))
    except ValueError:
        return None
