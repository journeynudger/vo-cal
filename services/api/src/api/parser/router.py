"""Parse API (P0 items 4-7): transcript -> structured items -> macros ->
confidence -> at most one clarifying question.

Orchestration only. Every hard part lives in a tested engine module:
  parse_transcript (llm)  ->  Resolver (resolver)  ->  item/meal confidence
  (confidence)  ->  ClarifyEngine (clarify).  This router wires them and
persists the immutable ``parses`` artifact; it computes nothing itself
(AGENTS.md #6: deterministic code calculates, the LLM extracts).
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, status

from ..captures.store import CapturesStore
from ..config import settings
from ..dependencies import CurrentUser, Db
from ..foods.index import load_personal_index, personal_food_id
from ..meals.learning import apply_learned_names, derive_learned_names
from ..meals.recognition import from_saved_rows, recognize
from ..meals.store import MealsStore
from ..metrics import PARSE_LATENCY, QUESTION_ASKED
from ..nutrition.build import build_resolver
from ..nutrition.resolver import (
    ResolvedItem,
    ResolvedMeal,
    Resolver,
    grouping,
    persistable_identity,
    stored_identities,
)
from ..nutrition.schemas import Macros
from ..transcribe.store import TranscriptsStore
from .certainty import build_certainty, item_from_resolved
from .clarify import ClarifyEngine
from .clarify import removal_index as _removal_index
from .compose import Composition
from .compose import analyze as analyze_composition
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
    FoodSourceRef,
    ParsedMeal,
    ParseRequest,
    ParseResult,
    ParseResultItem,
    RecognizedMeal,
    RefineRequest,
)
from .store import ParsesStore

_logger = logging.getLogger(__name__)


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
        sources=(
            [FoodSourceRef(url=src.url, title=src.title) for src in resolved.sources]
            if resolved.sources
            else None
        ),
        identity=persistable_identity(resolved.identity),
        priced_as=resolved.identity.priced_as,
        personal_food_id=personal_food_id(resolved.identity),
    )


def _prime_from_parse_row(resolver: Resolver, parsed: ParsedMeal, result_items: list) -> None:
    """Seed the resolver with the identities the stored parse already resolved, under BOTH
    key shapes a refine can present: the parsed items as stored (variant/fat ratio as the
    LLM left them) and the result items (variant/fat ratio as resolved, which is what an
    edit sheet echoes back). Amount/unit/state answers then re-price the same food; a
    name/brand/variant/fat-ratio answer misses the memo and re-identifies."""
    rows = [r for r in result_items if isinstance(r, dict)]
    for item, identity in stored_identities(rows):
        resolver.prime(item, identity)
    for parsed_item, row in zip(parsed.items, rows, strict=False):
        pairs = stored_identities([row])
        if pairs:
            resolver.prime(parsed_item, pairs[0][1])


def _payload(
    parsed: ParsedMeal, result: ParseResult, transcript: str = "", chain: dict | None = None
) -> dict:
    # Store the parsed meal (so refine can re-resolve without a re-parse) plus the
    # rendered result (for the admin audit trail). Both are immutable once written.
    # The transcript rides along so refine's certainty re-score can see hedging and
    # negations ("black coffee", "no cheese") without re-fetching the transcripts row.
    # `chain` is the supersedes bookkeeping the confirm-time diff reads (meals/router
    # _record_corrections): root_parse_id, origin_indices (each item's index in the root
    # parse) and learned_names (renames applied at parse time, with the name as heard).
    return {
        "parsed_meal": parsed.model_dump(mode="json"),
        "result": result.model_dump(mode="json", exclude={"parse_id"}),
        "transcript": transcript,
        **(chain or {}),
    }


async def resolve_with_composition(
    resolver: Resolver, items: list, transcript: str = ""
) -> tuple[ResolvedMeal, Composition]:
    """Resolve a meal with composed-meal grammar applied (compose.py).

    Containers whose contents the user described become zero-calorie groupings —
    never a generic estimate stacked on the ingredient sum (the double-count bug).
    Used by /parse AND /parse/refine; the meals confirm path applies the same
    verdict in its re-resolution so the suppression cannot be undone at store time.
    The transcript enables the side-phrase guard ("rice and beans ON THE SIDE").
    """
    composition = analyze_composition([(i.name, i.amount) for i in items], transcript)

    async def _resolve_one(idx: int, item) -> ResolvedItem:
        if idx in composition.suppressed_indices:
            # A container whose contents carry the meal, or a component absorbed into a named
            # dish (partial enumeration: the dish's price already includes it).
            return grouping(item)
        if idx == composition.absorbed_into_index and composition.absorbed_names:
            # Absorption prices the container as the FULL described dish: a bare
            # "chicken burrito" estimated 198 g/400 kcal while its stated rice+beans
            # sat at zero (eval 2026-07-30). The enriched name flows to the estimator
            # (its own cache key) and to the result card — the user sees exactly what
            # was priced. compose._head() keeps container detection working on this
            # name at confirm-time re-analysis.
            joined = ", ".join(composition.absorbed_names)
            item = item.model_copy(update={"name": f"{item.name} with {joined}"})
        return await resolver.resolve_item(item)

    # Concurrent, like resolve_meal: estimator lookups are seconds each on a cold
    # cache — wall-clock is the slowest item, not the sum.
    resolved = list(
        await asyncio.gather(*(_resolve_one(idx, item) for idx, item in enumerate(items)))
    )
    totals = Macros.zero()
    for r in resolved:
        totals = totals + r.macros
    return ResolvedMeal(items=resolved, totals=totals), composition


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

    # Learned names (meals/learning.py): what this person renamed before is applied here,
    # before resolution, deterministically, and recorded on the parse row so the confirm-time
    # diff can still see the name as heard. Owner-scoped read; an empty map is the default.
    learned = derive_learned_names(await MealsStore(db).name_corrections(user_id))
    items, learned_applied = apply_learned_names(meal.items, learned)
    meal = meal.model_copy(update={"items": items})
    # The person's own foods, ahead of every database (foods/index.py).
    resolver.register_personal(await load_personal_index(db, user_id))

    resolved, composition = await resolve_with_composition(resolver, meal.items, req.transcript)
    decision = await ClarifyEngine(resolver).decide(meal.items, meal.missing_details)

    parse_id = uuid4()
    meal_conf = meal_confidence(resolved.items)
    # A usual this sounds like ("my metal detox smoothie", or the same items again): one
    # owner-scoped read of the usuals, a pure match, an additive field. Offline the fake
    # database has whatever the test saved; a person with no usuals costs one empty read.
    usuals = await MealsStore(db).list_saved_meals(user_id)
    recognition = recognize(req.transcript, [i.name for i in meal.items], from_saved_rows(usuals))
    recognized_meal = None
    if recognition is not None:
        row = next((r for r in usuals if str(r.get("id")) == recognition.meal.id), None)
        if row is not None:
            recognized_meal = RecognizedMeal(
                id=row["id"],
                name=str(row["name"]),
                items=list(row.get("items") or []),
                totals=Macros.model_validate(row.get("totals") or {}),
                reason=recognition.reason,
            )
    result = ParseResult(
        parse_id=parse_id,
        meal_type=meal.meal_type,
        items=[_result_item(r) for r in resolved.items],
        totals=resolved.totals,
        meal_confidence=meal_conf,
        questions=decision.questions,
        missing_details=meal.missing_details,
        recognized_meal=recognized_meal,
        model=model,
        prompt_version=prompt_version,
        certainty=build_certainty(
            [item_from_resolved(r) for r in resolved.items],
            meal_conf,
            req.transcript,
            suppressed=composition.suppressed_names,
            absorbed_by=composition.absorbed_by,
        ),
    )

    await ParsesStore(db).insert(
        parse_id=parse_id,
        user_id=user_id,
        capture_id=req.capture_id,
        transcript_id=req.transcript_id,
        payload=_payload(
            meal,
            result,
            transcript=req.transcript,
            chain={
                "root_parse_id": str(parse_id),
                "origin_indices": list(range(len(meal.items))),
                "learned_names": learned_applied,
            },
        ),
        model=model,
        prompt_version=prompt_version,
    )

    # [parse]: immutable parse artifact committed. Counts/score only — item names and the
    # transcript are user content and stay out of server logs (MUST-NOT #5). Suppressed
    # container COUNT is the composed-meal audit trail (spec §19 debug requirement).
    _logger.info(
        "[parse] parse=%s capture=%s items=%d questions=%d certainty=%s suppressed_containers=%d",
        parse_id, req.capture_id, len(result.items), len(decision.questions),
        result.certainty.score if result.certainty else "-",
        len(composition.suppressed_names),
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
    # A rename on the sheet may name one of the person's own foods.
    resolver.register_personal(await load_personal_index(db, user_id))
    # The stored parse already resolved WHICH food each item is; an amount/unit/state answer
    # must re-price that same identity, never re-identify it (2026-09-23: editing the apple
    # to 200 g re-ran the ladder and swapped it for USDA's apple-crisp dessert).
    _prime_from_parse_row(resolver, parsed, (row["payload"].get("result") or {}).get("items") or [])
    clarify = ClarifyEngine(resolver)
    # Removals are first-class refine operations ("items[N].removed" = "true"): a
    # client-local delete was silently undone by the NEXT refine, which re-resolved the
    # original parse and resurrected the item (field bug 2026-07). Field answers in the
    # same request address PRE-removal indices (the items list the client is looking
    # at), so removals collect first and apply once, after every field merge.
    removals: set[int] = set()
    for answer in req.answers:
        removal_idx = _removal_index(answer.field, answer.value)
        if removal_idx is not None:
            removals.add(removal_idx)
            continue
        items = await clarify.merge_answer(items, answer.field, answer.value)
    # Chain bookkeeping for the confirm-time diff: every surviving item keeps its index in
    # the ROOT parse, through any number of refines and removals.
    previous_origin = row["payload"].get("origin_indices") or list(range(len(parsed.items)))
    origin_indices = [
        previous_origin[idx] for idx in range(len(items)) if idx not in removals and idx < len(previous_origin)
    ]
    if removals:
        items = [item for idx, item in enumerate(items) if idx not in removals]
        if not items:
            # An empty meal has nothing to re-resolve or supersede honestly — the client
            # cancels the log locally instead (and its CTA refuses an empty confirm).
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="cannot remove every item; cancel the log instead",
            )

    # Re-resolve the whole (small) meal — composed-meal grammar included, so a container
    # stays a zero-cal grouping through refine — then re-decide so any still-material
    # check surfaces and answered axes drop (decision #29: per-ingredient, multi-round).
    # Old parse payloads (pre-transcript) fall back to "" (side-phrase guard inert).
    transcript = str(row["payload"].get("transcript") or "")
    resolved, composition = await resolve_with_composition(resolver, items, transcript)
    decision = await clarify.decide(items, parsed.missing_details)
    merged = parsed.model_copy(update={"items": items})

    new_id = uuid4()
    meal_conf = meal_confidence(resolved.items)
    result = ParseResult(
        parse_id=new_id,
        supersedes=req.parse_id,
        meal_type=parsed.meal_type,
        items=[_result_item(r) for r in resolved.items],
        totals=resolved.totals,
        meal_confidence=meal_conf,
        questions=decision.questions,
        missing_details=parsed.missing_details,
        model=row["model"],
        prompt_version=row["prompt_version"],
        certainty=build_certainty(
            [item_from_resolved(r) for r in resolved.items],
            meal_conf,
            transcript,
            suppressed=composition.suppressed_names,
            absorbed_by=composition.absorbed_by,
        ),
    )

    await store.insert(
        parse_id=new_id,
        user_id=user_id,
        capture_id=_as_uuid(row.get("capture_id")),
        transcript_id=_as_uuid(row.get("transcript_id")),
        supersedes=req.parse_id,
        payload=_payload(
            merged,
            result,
            transcript=transcript,
            chain={
                "root_parse_id": str(row["payload"].get("root_parse_id") or row["id"]),
                "origin_indices": origin_indices,
                "learned_names": row["payload"].get("learned_names") or [],
            },
        ),
        model=row["model"],
        prompt_version=row["prompt_version"],
    )
    return result


def _as_uuid(value: str | None) -> UUID | None:
    return UUID(value) if value else None
