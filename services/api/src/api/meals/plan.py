"""The meal plan (decision 65, plan P8): the meals a person plans for a day, checked off as
they log them.

Written by the person from their usuals or a typed meal (D5 a); the engine checks the plan
against the protocol and says so in one line; a coach may write one later (``author``). The
store holds versions (what is durably true); the check and the matching are pure functions;
the router orchestrates and prices (meals/router.py, the one confirm path, RT-02).
"""

from __future__ import annotations

import math
from datetime import datetime
from typing import Any, Literal
from uuid import UUID, uuid4

from pydantic import BaseModel, Field

from ..db import (
    VERSION_APPEND_ATTEMPTS,
    SupportsDatabase,
    UniqueViolationError,
    VersionRaceLostError,
)
from ..nutrition.schemas import Macros
from .naming import display_name
from .schemas import ConfirmedItem
from .today import Panel, PlanSlotStatus, Targets

# A day has at most this many planned meals (the intake asks for 2 to 5; the builder sizes the
# plan from the protocol's meals per day, and a person may add a snack or two).
MAX_SLOTS = 8
# The plan "lands" on the protocol when its calories are within this share of the target
# (plan P8: within 10 percent) and its protein reaches the band's floor.
KCAL_TOLERANCE = 0.10
# The longest slot name the plan stores. Names the server composes from items ("A, B, C & 1
# more", each item up to 80 characters) ran to 169 and the builder sent them back on the next
# save, which refused them: a plan that could never be saved again (2026-10-22). The server
# clips what it stores, and takes back longer names so plans saved before this still save.
SLOT_NAME_MAX = 120
_SLOT_NAME_INPUT_MAX = 400


def slot_name(name: str) -> str:
    """``name`` on one line, at most SLOT_NAME_MAX characters, cut at a word."""
    flat = " ".join(name.split())
    if len(flat) <= SLOT_NAME_MAX:
        return flat
    cut = flat[: SLOT_NAME_MAX - 1].rsplit(" ", 1)[0].rstrip(" ,&")
    return f"{cut}\u2026"


class PlanSlotInput(BaseModel):
    """One slot as the client sends it: a usual by id (the server copies its items), or the
    items of a typed meal's parse (the server re-prices them on the confirm path). A name is
    optional; the usual's name, or a name from the items, stands in."""

    name: str | None = Field(default=None, max_length=_SLOT_NAME_INPUT_MAX)
    usual_id: UUID | None = None
    items: list[ConfirmedItem] | None = Field(default=None, min_length=1, max_length=50)


class MealPlanUpdate(BaseModel):
    """PUT /meals/plan: the whole plan, in order. Appends a version."""

    slots: list[PlanSlotInput] = Field(max_length=MAX_SLOTS)
    author: Literal["person", "coach"] = "person"


class PlanSlot(BaseModel):
    index: int
    name: str
    usual_id: UUID | None = None
    items: list[ConfirmedItem]
    totals: Macros


class PlanCheck(BaseModel):
    """The engine's one line about the plan against the protocol (AGENTS.md #6: deterministic
    code, never a model). Numbers beside the line so a client may print them."""

    kcal: float
    protein: float
    target_kcal: float
    protein_floor: float
    kcal_within: bool
    protein_ok: bool
    line: str


class MealPlan(BaseModel):
    version: int
    author: str
    slots: list[PlanSlot]
    # None when there is no protocol to check against (the stub) or no slots.
    check: PlanCheck | None = None
    created_at: datetime | None = None


class MealPlanStore:
    def __init__(self, db: SupportsDatabase) -> None:
        self._db = db

    async def latest_row(self, user_id: UUID) -> dict[str, Any] | None:
        # The newest version by the index, one row. Read whole and maxed in Python, the newest
        # fell past PostgREST's 1000-row cap and every append after it collided (2026-10-22).
        rows = await self._db.select(
            "meal_plans", {}, user_id=user_id, order_by="version", descending=True, limit=1
        )
        return rows[0] if rows else None

    async def append(
        self, *, user_id: UUID, author: str, slots: list[dict[str, Any]]
    ) -> dict[str, Any]:
        """Insert the next version. The plan is the whole plan, so a concurrent save that takes
        the number first only moves this one to the next: re-read and retry, the last save the
        latest. Two attempts left a burst of three saves 500ing against Postgres (2026-10-22);
        VersionRaceLostError (a 409) once every attempt lost."""
        for _ in range(VERSION_APPEND_ATTEMPTS):
            previous = await self.latest_row(user_id)
            version = int(previous["version"]) + 1 if previous else 1
            try:
                return await self._db.insert(
                    "meal_plans",
                    {
                        "id": str(uuid4()),
                        "user_id": str(user_id),
                        "version": version,
                        "author": author,
                        "slots": slots,
                    },
                )
            except UniqueViolationError:
                continue
        raise VersionRaceLostError("meal_plans")


def plan_from_row(row: dict[str, Any]) -> MealPlan:
    """Lenient on jsonb shape: a slot this build cannot read is dropped, never a 500 on the
    read path (a later client may write a field this build does not know)."""
    slots: list[PlanSlot] = []
    for raw in row.get("slots") or []:
        if not isinstance(raw, dict):
            continue
        try:
            slots.append(PlanSlot.model_validate(raw))
        except ValueError:
            continue
    return MealPlan(
        version=int(row.get("version") or 0),
        author=str(row.get("author") or "person"),
        slots=slots,
        created_at=row.get("created_at"),
    )


def check_plan(
    slots: list[PlanSlot], targets: Targets, protein_band: tuple[float, float]
) -> PlanCheck:
    """The plan against the protocol: calories within the tolerance of the target, protein at
    least the band's floor (the target itself when the protocol carries no band)."""
    kcal = round(sum(s.totals.kcal for s in slots), 1)
    protein = round(sum(s.totals.protein for s in slots), 1)
    target = float(targets.kcal)
    floor = float(protein_band[0]) if protein_band[0] > 0 else float(targets.protein)
    kcal_within = target > 0 and abs(kcal - target) <= KCAL_TOLERANCE * target
    protein_ok = protein >= floor
    return PlanCheck(
        kcal=kcal,
        protein=protein,
        target_kcal=target,
        protein_floor=floor,
        kcal_within=kcal_within,
        protein_ok=protein_ok,
        line=_check_line(kcal, protein, target, floor, kcal_within, protein_ok),
    )


def _check_line(
    kcal: float, protein: float, target: float, floor: float, kcal_within: bool, protein_ok: bool
) -> str:
    """One sentence, the facts and no verdict on the person (spec 6.10: without a word of
    judgment). "Covered" for protein, because the band's floor is a floor, not a target."""
    if kcal_within and protein_ok:
        return f"On your protocol: {kcal:,.0f} of {target:,.0f} calories, protein covered."
    parts: list[str] = []
    if not kcal_within:
        gap = target - kcal
        parts.append(f"{abs(gap):,.0f} calories {'under' if gap > 0 else 'over'} your protocol")
    if not protein_ok:
        # Up to the whole gram: a shortfall under half a gram printed "protein 0 g under".
        parts.append(f"protein {math.ceil(floor - protein):,} g under the band")
    sentence = "; ".join(parts)
    return sentence[0].upper() + sentence[1:] + "."


def match_slots(
    slots: list[PlanSlot], rows: list[dict[str, Any]]
) -> tuple[list[PlanSlotStatus], list[str]]:
    """Tick the slots the day's meals fill, and name the rest.

    A logged meal ticks at most one slot, by name: the recognized usual ("Is this your
    smoothie?" > Yes) and the re-logged chip both log under the usual's name, and a typed slot
    is named after what was typed, which is what the parse names the meal too. Each slot is
    ticked at most once, in the order the meals were logged. Meals that fill no slot come back
    as the "also today" names: stated, never judged.
    """
    statuses = [
        PlanSlotStatus(index=slot.index, name=slot.name, kcal=slot.totals.kcal) for slot in slots
    ]
    # A slot answers to its name and to the name a meal logged from it is shown by: a usual
    # called "Breakfast" logs as "Breakfast", and display_name reads that generic word as no
    # name and names the meal from its items, so the slot never ticked (2026-10-22 audit).
    open_by_key: dict[str, list[int]] = {}
    for position, slot in enumerate(slots):
        shown = display_name({"name": slot.name, "items": [i.model_dump(mode="json") for i in slot.items]})
        for key in dict.fromkeys(_name_key(n) for n in (slot.name, shown) if n):
            open_by_key.setdefault(key, []).append(position)
    ticked: set[int] = set()
    extras: list[str] = []
    for row in sorted(rows, key=_logged_at_key):
        name = display_name(row) or "Meal"
        waiting = [p for p in open_by_key.get(_name_key(name), []) if p not in ticked]
        if waiting:
            position = waiting[0]
            ticked.add(position)
            statuses[position].logged = True
            statuses[position].meal_id = str(row.get("id")) if row.get("id") is not None else None
        else:
            extras.append(name)
    return statuses, extras


def plan_panel(plan: MealPlan | None, rows: list[dict[str, Any]]) -> Panel:
    """The ``meal_plan_slots`` card: the planned meals with their ticks and the day's extras.
    With no plan yet, the card says so and lists what was logged, so the page is never blank
    and never claims a plan that does not exist."""
    if plan is None or not plan.slots:
        return Panel(
            kind="meal_plan_slots",
            metric="plan",
            title="Your plan",
            consumed=0.0,
            target=0.0,
            remaining=0.0,
            direction="reach",
            complete=False,
            support="No plan yet",
            slots=[],
            extras=[display_name(row) or "Meal" for row in sorted(rows, key=_logged_at_key)],
        )
    statuses, extras = match_slots(plan.slots, rows)
    logged = sum(1 for status in statuses if status.logged)
    count = len(statuses)
    return Panel(
        kind="meal_plan_slots",
        metric="plan",
        title="Your plan",
        consumed=float(logged),
        target=float(count),
        remaining=float(count - logged),
        direction="reach",
        complete=logged >= count,
        support=f"{logged} of {count} meal{'s' if count != 1 else ''}",
        slots=statuses,
        extras=extras,
    )


def _name_key(name: str) -> str:
    return " ".join(name.lower().split())


def _logged_at_key(row: dict[str, Any]) -> str:
    value = row.get("logged_at")
    return value.isoformat() if isinstance(value, datetime) else str(value or "")
