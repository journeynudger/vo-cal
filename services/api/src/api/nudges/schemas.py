"""Wire contract for POST /nudges/plan — the SHIPPED iOS mirror is authoritative.

apps/ios/VoCal/Services/NudgeModels.swift decodes these shapes via VoCalJSON
(snake_case -> camelCase): NudgeCard{id, category, message, pro_tip, priority,
cooldown_days} plus the additive invitation keys, ScheduledNudge{fire_at, card},
NudgePlan{immediate, scheduled}, request {recently_shown: {nudge_id: "yyyy-MM-dd"}}. The
client has been live since TestFlight build 16: required keys never change, new keys are
optional on the wire and ignored by a client that predates them.
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

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
    # Additive since 2026-10-04 (decision 62): an invitation carries what it offers and the key a
    # "Don't offer this again" declines with (PUT /tracking decline_offer). A build-31 client
    # ignores the keys and shows the card as a nudge with its message; it has no Yes button.
    kind: Literal["nudge", "invitation"] = "nudge"
    offer_mode: str | None = None
    offer_focus: str | None = None
    decline_key: str | None = None


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
    a stale ledger repeats a nudge, never harms.

    ``level`` is the user's delivery preference (engine.py owns the semantics).
    Defaults to ``standard`` because shipped clients (TestFlight ≤ build 22) omit
    it — their behavior must not change under them; new clients send their stored
    preference explicitly (default there is ``essential``)."""

    recently_shown: dict[str, str] = Field(default_factory=dict)
    level: Literal["essential", "standard", "off"] = "standard"
