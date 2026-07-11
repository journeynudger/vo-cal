# services/api — FastAPI backend

FastAPI app factory (`src/api/main.py:create_app`), Python 3.14, deps via **uv** (`uv sync`).
Run tests + lint: `scripts/check-api` from the repo root (~2s; ruff + pytest, all offline).

## The seams (how this app fakes everything offline)

Every external dependency is behind a seam and silently degrades to a fake when unconfigured.
**`GET /__dev/preflight` tells you which fakes are live — curl it before trusting results.**

| Seam | Real | Fake (when) |
|---|---|---|
| Database (`db.py`) | Supabase via service-role key | `FakeDatabase` in-memory (no creds) — NOTHING persists across restarts |
| Storage (`storage.py`) | Supabase Storage `capture-audio` | `FakeStorage` dict |
| Parser LLM (`parser/llm.py`) | Anthropic/Gemini/OpenAI by `PARSER_PROVIDER`+key | `FakeParserClient` — recorded fixtures in `tests/fixtures/llm_responses/`, keyed by normalized transcript; **unknown transcripts fail** |
| Transcription (`transcribe/elevenlabs.py`) | ElevenLabs Scribe (`ELEVENLABS_API_KEY`) | `FakeTranscriber` — one canned transcript |
| Nutrition estimator (`nutrition/estimator.py`) | AI-FIRST for branded/unknown foods, cheapest-capable chain: durable cache → **haiku + web_search** (reads the label online, returns up to 4 SOURCES shown to the user) → knowledge-only sonnet; per-100g identity, Atwater-validated, cached (`usda_cache`, `est:` keys) | `None` → deterministic path only; unknowns stay UNRESOLVED (0 kcal) |

`TEST_MODE=true` forces the fakes even when keys exist (the suite is always offline).

## Domain layout (one folder per domain: router / schemas / store)

`captures` (audio ground truth) → `transcribe` → `parser` (LLM extract + deterministic
resolve/confidence/certainty/clarify) → `meals` (confirm/today/summary) → `checkin` (nudges,
recalibration) · `protocols` (the PRO IP calorie engine) · `intake` · `nutrition` (dictionary,
FDC, resolver, estimator) · `admin` (audit-logged) · `account` (deletion) · `dev` (`/__dev`,
local-only).

## Rules that bite here

- **The LLM extracts; deterministic code calculates** (AGENTS.md #6). Numbers come from
  `nutrition/resolver.py` + `protocols/engine.py` — never from a model.
- Stores answer "what is durably true", nothing else. Owner-scope (`user_id=`) every read.
- `captures`/`transcripts`/`parses`/`corrections` are immutable — reprocessing writes new rows.
- Never log transcript text, item names, or macro values (MUST-NOT #5) — ids/counts/confidence only.
- Boot guards in `main.py` refuse to start dev surfaces (`TEST_MODE`, `DEV_ENDPOINTS`)
  against a hosted database. Don't weaken them.
- Parser/nutrition changes: run `scripts/parser-eval` too — a SCORES regression does not merge.

## Gotchas (paid for in production)

- Pydantic response models: an ADDED field must be emitted server-side AND optional/custom-decoded
  in the Swift mirror — a non-optional Swift field with a missing key killed every parse once
  (`is_estimate`). See `Sources/VoCalCore/ParserContract.swift`.
- Server timestamps have microseconds; plain `.iso8601` Swift decoding rejects them.
- `FakeDatabase` mirrors RLS owner-scoping AND declared UNIQUE indexes (`_UNIQUE_INDEXES`) —
  keep it in lockstep with new migrations or dedup bugs ship green.
