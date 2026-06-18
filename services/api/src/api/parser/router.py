"""Parse API (P0 items 4-7): transcript -> structured items -> macros ->
confidence -> at most one clarifying question.

Orchestration only. Every hard part lives in a tested engine module:
  parse_transcript (llm)  ->  Resolver (resolver)  ->  item/meal confidence
  (confidence)  ->  ClarifyEngine (clarify).  This router wires them and
persists the immutable ``parses`` artifact; it computes nothing itself
(AGENTS.md #6: deterministic code calculates, the LLM extracts).
"""

from __future__ import annotations

import time
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, status

from ..config import settings
from ..dependencies import CurrentUser, Db
from ..metrics import PARSE_LATENCY, QUESTION_ASKED
from ..nutrition.fdc_client import FdcClient
from ..nutrition.resolver import ResolvedItem, Resolver
from .clarify import ClarifyEngine
from .confidence import item_confidence, meal_confidence
from .llm import AnthropicParserClient, FakeParserClient, ParseError, ParserClient, parse_transcript
from .schemas import (
    ParsedMeal,
    ParseRequest,
    ParseResult,
    ParseResultItem,
    RefineRequest,
)
from .store import ParsesStore


def get_parser_client() -> ParserClient:
    """The live LLM when a key is configured; the recorded-fixture fake offline.

    No key (tests, local dev) => FakeParserClient, which serves recorded tool
    outputs from tests/fixtures/llm_responses. Production sets ANTHROPIC_API_KEY.
    """
    if settings.anthropic_api_key:
        return AnthropicParserClient()
    return FakeParserClient()


def get_resolver(db: Db) -> Resolver:
    """Dictionary-first resolver; FDC long-tail only when a key is configured.

    Without USDA_FDC_API_KEY the resolver is dictionary-only and unknown foods
    degrade to ``unresolved`` (never a 500) — exactly the offline posture.
    """
    fdc = FdcClient(db) if settings.usda_fdc_api_key else None
    return Resolver(fdc=fdc)


ParserClientDep = Annotated[ParserClient, Depends(get_parser_client)]
ResolverDep = Annotated[Resolver, Depends(get_resolver)]

router = APIRouter(prefix="/parse", tags=["parser"])


def _result_item(resolved: ResolvedItem) -> ParseResultItem:
    item = resolved.item
    return ParseResultItem(
        name=item.name,
        amount=item.amount,
        unit=item.unit,
        state=item.state,
        # Prefer the resolved fat ratio (e.g. family-default fill-in) for display.
        fat_ratio=resolved.resolved_fat_ratio or item.fat_ratio,
        brand=item.brand,
        prep_method=item.prep_method,
        grams=resolved.grams,
        macros=resolved.macros,
        confidence=item_confidence(resolved),
        source=resolved.source,
        match_score=resolved.match_score,
    )


def _payload(parsed: ParsedMeal, result: ParseResult) -> dict:
    # Store the parsed meal (so refine can re-resolve without a re-parse) plus the
    # rendered result (for the admin audit trail). Both are immutable once written.
    return {
        "parsed_meal": parsed.model_dump(mode="json"),
        "result": result.model_dump(mode="json", exclude={"parse_id"}),
    }


@router.post("", response_model=ParseResult)
async def parse(
    req: ParseRequest,
    user_id: CurrentUser,
    db: Db,
    client: ParserClientDep,
    resolver: ResolverDep,
) -> ParseResult:
    started = time.perf_counter()
    try:
        meal, model, prompt_version = await parse_transcript(client, req.transcript)
    except ParseError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc)
        ) from exc

    resolved = await resolver.resolve_meal(meal.items)
    decision = await ClarifyEngine(resolver).decide(meal.items, meal.missing_details)

    parse_id = uuid4()
    result = ParseResult(
        parse_id=parse_id,
        meal_type=meal.meal_type,
        items=[_result_item(r) for r in resolved.items],
        totals=resolved.totals,
        meal_confidence=meal_confidence(resolved.items),
        question=decision.question,
        missing_details=meal.missing_details,
        model=model,
        prompt_version=prompt_version,
    )

    await ParsesStore(db).insert(
        parse_id=parse_id,
        user_id=user_id,
        capture_id=req.capture_id,
        transcript_id=req.transcript_id,
        payload=_payload(meal, result),
        model=model,
        prompt_version=prompt_version,
    )

    PARSE_LATENCY.labels(model=model).observe(time.perf_counter() - started)
    if decision.question is not None:
        QUESTION_ASKED.labels(field=decision.question.field).inc()
    return result


@router.post("/refine", response_model=ParseResult)
async def refine(
    req: RefineRequest,
    user_id: CurrentUser,
    db: Db,
    resolver: ResolverDep,
) -> ParseResult:
    store = ParsesStore(db)
    row = await store.get(req.parse_id, user_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="parse not found")

    parsed = ParsedMeal.model_validate(row["payload"]["parsed_meal"])
    items = parsed.items
    clarify = ClarifyEngine(resolver)
    for answer in req.answers:
        items = await clarify.merge_answer(items, answer.field, answer.value)

    # Re-resolve the whole (small) meal: identical result to single-item re-resolve,
    # simpler and still correct per the contract's answer-merge rule.
    resolved = await resolver.resolve_meal(items)
    merged = parsed.model_copy(update={"items": items})

    new_id = uuid4()
    result = ParseResult(
        parse_id=new_id,
        supersedes=req.parse_id,
        meal_type=parsed.meal_type,
        items=[_result_item(r) for r in resolved.items],
        totals=resolved.totals,
        meal_confidence=meal_confidence(resolved.items),
        question=None,
        missing_details=[],
        model=row["model"],
        prompt_version=row["prompt_version"],
    )

    await store.insert(
        parse_id=new_id,
        user_id=user_id,
        capture_id=_as_uuid(row.get("capture_id")),
        transcript_id=_as_uuid(row.get("transcript_id")),
        supersedes=req.parse_id,
        payload=_payload(merged, result),
        model=row["model"],
        prompt_version=row["prompt_version"],
    )
    return result


def _as_uuid(value: str | None) -> UUID | None:
    return UUID(value) if value else None
