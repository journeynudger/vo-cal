"""Meal names built from what was eaten, never from a counter.

Requirement (Lorenzo, 2026-09-24): "Logged today" listed every meal as "Meal 1", "Meal 2",
which says nothing; a meal should be named after its food, and the person should be able
to rename it. The name is deterministic (AGENTS.md #6: the model never authors what the
person reads as a fact) and pure, so the same items always name the same way.

Three sources of a name, recorded in ``meal_logs.name_source``:
  auto        this module, from the items; recomputed when an auto-named meal is edited
  user        typed by the person (rename, or a name sent at confirm); never recomputed
  recognized  copied from a usual the person confirmed ("Is this your metal detox smoothie?")
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from typing import Any

NAME_SOURCE_AUTO = "auto"
NAME_SOURCE_USER = "user"
NAME_SOURCE_RECOGNIZED = "recognized"

# Named items in an auto name before "& N more". Three reads as a meal ("Oatmeal, banana &
# peanut butter"); four starts to read as a list.
_NAMED_ITEMS = 3


def _field(item: Any, name: str, default: Any = None) -> Any:
    if isinstance(item, Mapping):
        return item.get(name, default)
    return getattr(item, name, default)


def _kcal(item: Any) -> float:
    macros = _field(item, "macros") or {}
    value = _field(macros, "kcal", 0.0) if not isinstance(macros, Mapping) else macros.get("kcal", 0.0)
    try:
        return float(value or 0.0)
    except (TypeError, ValueError):
        return 0.0


def _is_grouping(item: Any) -> bool:
    # A composed dish the person described by its contents is stored as a zero-calorie,
    # zero-gram grouping whose components carry the meal (parser/compose.py). The dish is
    # the name people use ("turkey sandwich"), not its parts.
    grams = _field(item, "grams", 0.0) or 0.0
    return float(grams) == 0.0 and _kcal(item) == 0.0 and not _field(item, "manual", False)


def _capitalize(name: str) -> str:
    name = name.strip()
    return name[:1].upper() + name[1:] if name else name


def _join(names: list[str]) -> str:
    if len(names) == 1:
        return names[0]
    if len(names) == 2:
        return f"{names[0]} & {names[1]}"
    return f"{', '.join(names[:-1])} & {names[-1]}"


def auto_name(items: Sequence[Any]) -> str | None:
    """A name from the items, heaviest first: "Oatmeal", "Oatmeal & banana", "Oatmeal,
    banana & peanut butter", "Oatmeal, banana & 2 more". A composed dish names the meal on
    its own ("Turkey sandwich"). None when there is nothing to name."""
    named = [str(_field(i, "name") or "").strip() for i in items]
    kept = [(i, n) for i, n in zip(items, named, strict=True) if n]
    if not kept:
        return None
    groupings = [n for i, n in kept if _is_grouping(i)]
    if groupings:
        ordered = _dedupe(groupings)
    else:
        # Stable sort: heaviest first, ties in spoken order.
        ordered = _dedupe([n for _, n in sorted(kept, key=lambda pair: -_kcal(pair[0]))])
    head = [_capitalize(ordered[0]), *(n.lower() if n == n.title() and " " not in n else n for n in ordered[1:_NAMED_ITEMS])]
    rest = len(ordered) - len(head)
    if rest > 0:
        return f"{', '.join(head)} & {rest} more"
    return _join(head)


def _dedupe(names: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for name in names:
        key = name.lower()
        if key not in seen:
            seen.add(key)
            out.append(name)
    return out


def display_name(row: Mapping[str, Any]) -> str | None:
    """What a stored meal is called: its name, else a name from its items (rows logged
    before names existed, and any row whose name was never set)."""
    name = row.get("name")
    if isinstance(name, str) and name.strip():
        return name
    return auto_name(row.get("items") or [])


def is_user_named(row: Mapping[str, Any]) -> bool:
    """True when the name is the person's own (typed or confirmed), so an edit must keep it.
    A row with a name but no recorded source predates name sources and was named by the
    person at confirm, so it counts as theirs."""
    name = row.get("name")
    if not (isinstance(name, str) and name.strip()):
        return False
    return row.get("name_source") != NAME_SOURCE_AUTO
