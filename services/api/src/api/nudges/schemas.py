"""Wire contract for POST /nudges/plan — the SHIPPED iOS mirror is authoritative.

apps/ios/VoCal/Services/NudgeModels.swift decodes exactly these shapes via VoCalJSON
(snake_case -> camelCase): NudgeCard{id, category, message, pro_tip, priority,
cooldown_days}, ScheduledNudge{fire_at, card}, NudgePlan{immediate, scheduled},
request {recently_shown: {nudge_id: "yyyy-MM-dd"}}. The client is already live in
TestFlight build 16 (failing silently against a 404) — this contract cannot drift.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class NudgeCard(BaseModel):
    """One nudge, exactly as the engine selected it. The copy is the product's
    coaching voice (empathy-first); the client never rewrites it."""

    id: str
    category: str
    message: str
    pro_tip: str
    priority: int
    cooldown_days: int


class ScheduledNudge(BaseModel):
    """A nudge the client delivers later as a LOCAL notification. ``fire_at`` is the
    server-computed user-local fire time (quiet hours already applied server-side)."""

    fire_at: datetime
    card: NudgeCard


class NudgePlan(BaseModel):
    """At most one immediate card (in-app surface) plus the local-notification
    schedule. Deterministic: same context + ledger -> same plan."""

    immediate: list[NudgeCard] = Field(default_factory=list)
    scheduled: list[ScheduledNudge] = Field(default_factory=list)


class NudgePlanRequest(BaseModel):
    """The client-owned shown-ledger (nudge id -> yyyy-MM-dd last shown). Advisory —
    a stale ledger repeats a nudge, never harms."""

    recently_shown: dict[str, str] = Field(default_factory=dict)
