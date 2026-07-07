# parser/ — the voice-pipeline brain (transcript → structured meal)

Contract: `docs/PARSER_CONTRACT.md` is canonical; `schemas.py` mirrors it exactly and the
Swift mirror is `Sources/VoCalCore/ParserContract.swift`. If they disagree, the doc wins.

## Flow (all wired in `router.py`, which computes nothing itself)

```
transcript ──llm.py──▶ ParsedMeal ──nutrition/resolver──▶ ResolvedItems
      │                                   │
      │                    confidence.py (item/meal 0-1)
      │                    certainty.py  (0-100 score, tips, coaching)
      │                    clarify.py    (>75kcal/10g material questions, ≤4)
      ▼
  parses row (immutable) ── /parse/refine re-scores with answers (score visibly rises)
```

## The LLM seam (`llm.py`)

- Providers: Anthropic (default, `PARSER_MODEL`), Gemini, OpenAI — all forced through the
  same `record_parsed_meal` tool contract, so downstream is provider-agnostic.
- The prompt lives in `prompts.py` (`SYSTEM_PROMPT` + `FEW_SHOT` + `build_messages`);
  bump `PROMPT_VERSION` on any change — it's stamped on every parses row.
- **Mock/offline**: `FakeParserClient` serves recorded tool outputs from
  `tests/fixtures/llm_responses/*.json`, keyed by lowercased whitespace-normalized
  transcript. To make a new transcript work offline, record a fixture file
  (`{"transcript": ..., "model": ..., "tool_input": {...}}`).
- One retry on validation error; a parse failure is NEVER a capture failure (audio is safe).

## Hard rules

- The model extracts structure; it never invents amounts (unstated → null + missing_detail).
- All numbers (macros, thresholds, scores) are deterministic Python: resolver/confidence/
  certainty/clarify. Certainty copy has a tested shame-word ban — keep copy calm.
- Negations ("no cheese", "black coffee") must never be coached on (`certainty.negated_details`).
- Verify with `scripts/check-api` AND `scripts/parser-eval` (fixture corpus SCORES —
  a regression does not merge). Scorer tests build `ParsedItem`s directly — no LLM needed.
