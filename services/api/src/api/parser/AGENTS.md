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
- The provider follows the model id (`provider_for`): `claude*` is Anthropic, `gpt*` and
  `o*` OpenAI, `gemini*` Gemini; `PARSER_PROVIDER` only settles an id without a family. A
  contradicting provider secret took every production parse down on 2026-09-24.
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

## Learned names (`meals/learning.py`)

- A rename on the result sheet teaches: the confirm-time diff (`meals/router.py::_record_corrections`)
  measures against the ROOT of the supersedes chain (`payload.root_parse_id`, `origin_indices`),
  so a rename made through `/parse/refine` lands as a `name` correction row.
- `parse` derives the user's learned map from those rows (`name` teaches, `name_forget`
  unteaches, latest wins) and applies it BEFORE resolution, recording each rename on the
  parse row (`payload.learned_names`, with the name as heard). Deterministic, owner-scoped,
  one query per parse. Reverting an applied rename at confirm unteaches it;
  `GET /meals/learned-names` lists the map and `POST /meals/learned-names/forget` appends the
  unteach row. Nothing is stored twice and nothing is deleted.
