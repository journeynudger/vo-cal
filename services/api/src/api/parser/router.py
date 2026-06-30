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

from ..captures.store import CapturesStore
from ..config import settings
from ..dependencies import CurrentUser, Db
from ..metrics import PARSE_LATENCY, QUESTION_ASKED
from ..nutrition.build import build_resolver
from ..nutrition.resolver import ResolvedItem, Resolver
from ..transcribe.store import TranscriptsStore
from .clarify import ClarifyEngine
from .confidence import item_confidence, meal_confidence
from .llm import (
    AnthropicParserClient,
    FakeParserClient,
    GeminiParserClient,
    OpenAIParserClient,
    ParseError,
    ParserClient,
    parse_transcript,
)
from .schemas import (
    ParsedMeal,
    ParseRequest,
    ParseResult,
    ParseResultItem,
    RefineRequest,
)
from .store import ParsesStore


def get_parser_client() -> ParserClient:
    """The live LLM for the configured provider; the recorded-fixture fake offline.

    Dispatches on PARSER_PROVIDER (gemini | anthropic | openai) and only when that
    provider's key is set. No key (tests, local dev) => FakeParserClient, which serves
    recorded tool outputs from tests/fixtures/llm_responses with zero network. All three
    providers force the same record_parsed_meal contract, so the engine downstream is
    provider-agnostic (AGENTS.md #6).
    """
    # Under test_mode the suite is always offline (recorded fixtures), regardless of any
    # real keys present in a local .env — live providers are never reached in tests.
    if settings.test_mode:
        return FakeParserClient()
    provider = (settings.parser_provider or "").lower()
    if provider == "gemini" and settings.gemini_api_key:
        return GeminiParserClient()
    if provider == "openai" and settings.openai_api_key:
        return OpenAIParserClient()
    if provider == "anthropic" and settings.anthropic_api_key:
        return AnthropicParserClient()
    return FakeParserClient()


def get_resolver(db: Db) -> Resolver:
    """Parse-preview resolver: dictionary-first, FDC long-tail when a key is configured,
    then a FLAGGED AI estimate for the remaining unknowns so an obvious food (a fruit bowl, a
    sausage link) never shows 0 kcal in the preview (bug-6 product rule: 0 is only for true
    zero-calorie items). The estimate is low-confidence + ``is_estimate`` so the UI invites a
    correction; it never 500s. In tests/offline there's no Anthropic key, so ``make_estimator``
    returns None and unknowns stay unresolved — the suite remains deterministic. The confirm
    path already estimates the same way (nutrition/build.py is the single construction site).
    """
    return build_resolver(db, estimate_unknowns=True)


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
        variant=resolved.resolved_variant or item.variant,
        grams=resolved.grams,
        macros=resolved.macros,
        confidence=item_confidence(resolved),
        source=resolved.source,
        match_score=resolved.match_score,
        is_estimate=resolved.is_estimate,
    )


def _payload(parsed: ParsedMeal, result: ParseResult) -> dict:
    # Store the parsed meal (so refine can re-resolve without a re-parse) plus the
    # rendered result (for the admin audit trail). Both are immutable once written.
    return {
        "parsed_meal": parsed.model_dump(mode="json"),
        "result": result.model_dump(mode="json", exclude={"parse_id"}),
    }


async def _verify_provenance_owned(
    db: Db, user_id: UUID, capture_id: UUID | None, transcript_id: UUID | None
) -> None:
    """A provided capture_id/transcript_id must reference rows the caller owns.

    Requirement: the admin audit chain (admin/store.py::get_log_chain) follows
    ``parse.capture_id`` UNSCOPED to mint a signed audio URL. Linking a capture the
    parse-owner doesn't own would serve another user's audio under this user's review
    (cross-tenant IDOR). Failure mode if absent: any caller can POST a foreign capture_id
    and poison the audit trail. Owner-scoped 404 (not 403) so we don't leak which ids exist.
    """
    if capture_id is not None and await CapturesStore(db).get(capture_id, user_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="capture not found")
    if transcript_id is not None:
        transcript = await TranscriptsStore(db).get(transcript_id)
        parent = _as_uuid(transcript.get("capture_id")) if transcript else None
        if parent is None or await CapturesStore(db).get(parent, user_id) is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="transcript not found"
            )


@router.post("", response_model=ParseResult)
async def parse(
    req: ParseRequest,
    user_id: CurrentUser,
    db: Db,
    client: ParserClientDep,
    resolver: ResolverDep,
) -> ParseResult:
    # Authorize provenance BEFORE the (paid) LLM call — fail fast, and never link foreign rows.
    await _verify_provenance_owned(db, user_id, req.capture_id, req.transcript_id)
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
        questions=decision.questions,
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
    for q in decision.questions:
        QUESTION_ASKED.labels(field=q.field).inc()
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

    # Re-resolve the whole (small) meal, then re-decide so any still-material check
    # surfaces and answered axes drop (decision #29: per-ingredient, multi-round).
    resolved = await resolver.resolve_meal(items)
    decision = await clarify.decide(items, parsed.missing_details)
    merged = parsed.model_copy(update={"items": items})

    new_id = uuid4()
    result = ParseResult(
        parse_id=new_id,
        supersedes=req.parse_id,
        meal_type=parsed.meal_type,
        items=[_result_item(r) for r in resolved.items],
        totals=resolved.totals,
        meal_confidence=meal_confidence(resolved.items),
        questions=decision.questions,
        missing_details=parsed.missing_details,
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
