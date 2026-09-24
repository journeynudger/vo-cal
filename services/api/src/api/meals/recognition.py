"""A repeated meal is recognized by its name or by its items.

Requirement (Lorenzo, 2026-09-24): he logs the same smoothie often and named it "metal
detox smoothie"; logging it again, even loosely, should ask "Is this your metal detox
smoothie?" and, on yes, use that meal's name and numbers. Candidates are the person's
usuals (``saved_meals``): every name the person gave a meal is one, so "name it once and
it is offered by name from then on" is the whole rule. Auto-named meals are never
candidates, or every repeated breakfast would interrupt with a question it can answer
itself.

Pure: no I/O, no model. Two ways to match, name first:
  name    the usual's spoken key appears in the transcript, or IS one of the parsed items
          ("my metal detox smoothie" parses as one item the ladder cannot price)
  items   the parsed item names and the usual's item names overlap enough (Jaccard >= 0.6
          with at least two shared, or a one-item meal matching a one-item usual)
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

from ..foods.index import spoken_key

ITEM_OVERLAP = 0.6
MIN_SHARED_ITEMS = 2


@dataclass(frozen=True)
class NamedMeal:
    id: str
    name: str
    item_names: tuple[str, ...]


@dataclass(frozen=True)
class Recognition:
    meal: NamedMeal
    reason: str  # "name" | "items"
    score: float


def from_saved_rows(rows: Sequence[dict[str, Any]]) -> list[NamedMeal]:
    out: list[NamedMeal] = []
    for row in rows:
        name = str(row.get("name") or "").strip()
        if not name:
            continue
        items = tuple(str(i.get("name") or "") for i in (row.get("items") or []) if isinstance(i, dict))
        out.append(NamedMeal(id=str(row.get("id")), name=name, item_names=items))
    return out


def _keys(names: Sequence[str]) -> set[str]:
    return {spoken_key(n) for n in names if n and spoken_key(n)}


def _phrase_in(phrase: str, text: str) -> bool:
    if not phrase:
        return False
    return re.search(rf"(?<![a-z0-9]){re.escape(phrase)}(?![a-z0-9])", text) is not None


def recognize(
    transcript: str, item_names: Sequence[str], candidates: Sequence[NamedMeal]
) -> Recognition | None:
    """The best candidate for what was just said, or None. Name matches beat item matches;
    among names the longest wins (a longer name is the more specific claim); among item
    matches the highest overlap wins."""
    if not candidates:
        return None
    spoken = spoken_key(transcript or "")
    item_keys = _keys(item_names)

    by_name: list[tuple[int, NamedMeal]] = []
    for candidate in candidates:
        key = spoken_key(candidate.name)
        if len(key) < 3:
            continue
        if _phrase_in(key, spoken) or key in item_keys:
            by_name.append((len(key), candidate))
    if by_name:
        by_name.sort(key=lambda pair: -pair[0])
        return Recognition(meal=by_name[0][1], reason="name", score=1.0)

    best: Recognition | None = None
    for candidate in candidates:
        theirs = _keys(candidate.item_names)
        if not theirs or not item_keys:
            continue
        shared = item_keys & theirs
        union = item_keys | theirs
        score = len(shared) / len(union)
        single = len(item_keys) == 1 and len(theirs) == 1 and shared
        matched = single or (len(shared) >= MIN_SHARED_ITEMS and score >= ITEM_OVERLAP)
        if matched and (best is None or score > best.score):
            best = Recognition(meal=candidate, reason="items", score=round(score, 3))
    return best
