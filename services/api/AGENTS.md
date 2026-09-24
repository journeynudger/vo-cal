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
| Parser LLM (`parser/llm.py`) | Anthropic/Gemini/OpenAI by the model id's family (`provider_for`; `PARSER_PROVIDER` only for ids without one) and that provider's key | `FakeParserClient` — recorded fixtures in `tests/fixtures/llm_responses/`, keyed by normalized transcript; **unknown transcripts fail** |
| Transcription (`transcribe/elevenlabs.py`) | ElevenLabs Scribe (`ELEVENLABS_API_KEY`) | `FakeTranscriber` — one canned transcript |
| Nutrition estimator (`nutrition/estimator.py`) | AI-FIRST for branded/unknown foods, cheapest-capable: durable+versioned cache → **haiku + web_search steered to official-nutrition domains** (`nutrition/sources.py`; retries open if a domain is crawler-blocked; returns up to 4 SOURCES) → knowledge-only sonnet. per-100g identity, Atwater-validated, per-piece weights ≤300g; count units NEVER scale by serving size (`resolver._estimate` guard) | `None` → deterministic path only; unknowns stay UNRESOLVED (0 kcal) |

`TEST_MODE=true` forces the fakes even when keys exist (the suite is always offline).

## Domain layout (one folder per domain: router / schemas / store)

`captures` (audio and photo ground truth) → `transcribe` → `parser` (LLM extract from a transcript, a typed
text or a photo, `photo.py` + learned-name pass + deterministic resolve with the person's own `foods` first,
then confidence/certainty/clarify, then `meals/recognition.py` for a usual this sounds like) → `meals` (confirm with the root-of-chain
corrections diff, today/summary, names in `naming.py`, search in `search.py`, learned names, recently deleted; `learning.py`, `naming.py`, `recognition.py` and `search.py` are pure) → `checkin` (nudges,
recalibration) · `protocols` (the PRO IP calorie engine) · `intake` · `nutrition` (dictionary,
FatSecret, FDC, resolver, estimator) · `admin` (audit-logged) · `account` (deletion) · `dev` (`/__dev`,
local-only).

## Rules that bite here

- **The LLM extracts; deterministic code calculates** (AGENTS.md #6). Numbers come from
  `nutrition/resolver.py` + `protocols/engine.py` — never from a model.
- **Identity never reads the amount** (`nutrition/resolver.py`, 2026-09-23). `resolve_identity`
  picks WHICH food from name/brand/variant/fat ratio/prep only; `price()` does the grams. The
  identity is persisted on parse items and primed (`Resolver.prime`) on refine/confirm from SERVER
  rows only — an amount edit must never swap the food, and a client-sent identity is never trusted.
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
