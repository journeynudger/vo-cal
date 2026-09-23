"""Learned name corrections: the parser remembers what the person renamed.

Bill's "bulk correct common typos" (Codex/Codecs): a food or brand the transcriber
mis-hears the same way every time ("oil coast" for Oikos). The rename on the result sheet
is the teaching gesture; every later parse applies it deterministically, before
resolution, and records that it did on the parse row. Nothing is stored twice: the
learned map is derived from the append-only ``corrections`` rows (field ``name`` teaches,
``name_forget`` unteaches, the latest row per heard name wins), so Settings > Learned names,
the parse-time pass and the audit trail can never disagree.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any

from ..parser.schemas import ParsedItem

NAME_FIELD = "name"
FORGET_FIELD = "name_forget"


def normalize_name(value: object) -> str:
    """The key a spoken name is learned under: lowercase, whitespace collapsed."""
    return " ".join(str(value or "").strip().lower().split())


@dataclass(frozen=True)
class LearnedName:
    heard: str
    corrected: str
    count: int
    learned_at: str | None
    meal_log_id: str


def derive_learned_names(rows: Iterable[dict[str, Any]]) -> dict[str, LearnedName]:
    """Fold correction rows (any order) into the current learned map.

    Rows apply in ``created_at`` order, ties in the order given: a later rename of the same
    heard name replaces the earlier one, a ``name_forget`` row removes it, and a rename to
    the same name teaches nothing. ``count`` is how many times the same pair was confirmed
    in a row, the number Settings shows.
    """
    learned: dict[str, LearnedName] = {}
    for row in sorted(rows, key=lambda r: str(r.get("created_at") or "")):
        heard = normalize_name(row.get("parsed_value"))
        if not heard:
            continue
        field = row.get("field")
        if field == FORGET_FIELD:
            learned.pop(heard, None)
            continue
        if field != NAME_FIELD:
            continue
        corrected = str(row.get("confirmed_value") or "").strip()
        if not corrected or normalize_name(corrected) == heard:
            continue
        previous = learned.get(heard)
        same_pair = previous is not None and normalize_name(previous.corrected) == normalize_name(corrected)
        learned[heard] = LearnedName(
            heard=heard,
            corrected=corrected,
            count=previous.count + 1 if same_pair and previous else 1,
            learned_at=row.get("created_at"),
            meal_log_id=str(row.get("meal_log_id") or ""),
        )
    return learned


def apply_learned_names(
    items: list[ParsedItem], learned: dict[str, LearnedName]
) -> tuple[list[ParsedItem], list[dict[str, Any]]]:
    """Rename every item whose heard name is learned. Returns the items and, per rename,
    ``{"index", "heard", "corrected"}`` for the parse row (the confirm-time diff reads the
    name as heard from it, so a revert unteaches and a re-rename re-teaches)."""
    renamed: list[ParsedItem] = []
    applied: list[dict[str, Any]] = []
    for index, item in enumerate(items):
        entry = learned.get(normalize_name(item.name))
        if entry is None:
            renamed.append(item)
            continue
        renamed.append(item.model_copy(update={"name": entry.corrected}))
        applied.append({"index": index, "heard": item.name, "corrected": entry.corrected})
    return renamed, applied
