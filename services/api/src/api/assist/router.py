"""POST /assist: the bar answers (decision 71).

Orchestration only: the client reads the sentence into the form, apply.py does the one thing
and composes the answer. Logs carry the client's name and the kinds, never the sentence
(MUST-NOT #5).
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status

from ..dependencies import CurrentUser, Db
from ..meals.router import parse_day, user_tz, zone_or_none
from ..metrics import ASSIST_INTENTS
from .apply import answer
from .llm import AssistClient, AssistError, get_assist_client, parse_intent
from .schemas import AssistReply, AssistRequest

_logger = logging.getLogger(__name__)

router = APIRouter(prefix="/assist", tags=["assist"])

AssistClientDep = Annotated[AssistClient, Depends(get_assist_client)]


@router.post("", response_model=AssistReply)
async def assist(req: AssistRequest, user_id: CurrentUser, db: Db, client: AssistClientDep) -> AssistReply:
    try:
        raw = await client.extract(req.text, req.thread)
    except AssistError as exc:
        # An honest failure, never a guess that changes a setting: the phone shows its usual
        # failure surface with retry.
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "the reader did not answer") from exc
    intent = parse_intent(raw)
    tz_zone = zone_or_none(req.tz) or await user_tz(db, user_id)
    day = parse_day(req.date) if req.date else datetime.now(tz_zone).date()
    reply = await answer(db, user_id, intent, day=day, tz_zone=tz_zone)
    reply.client = client.name
    ASSIST_INTENTS.labels(kind=intent.kind, client=client.name).inc()
    _logger.info("[assist] client=%s intent=%s reply=%s", client.name, intent.kind, reply.kind)
    return reply
