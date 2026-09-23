# Glossary

## Claim ladder (capture truth states — never claim above proof)

- **accepted** — request landed; UI may acknowledge optimistically. The only rung where optimism is allowed.
- **mic_active** — recorder actually started; file open.
- **confirmed_listening** — liveness proof: audio bytes observed flowing. "Listening" UI gates on this.
- **saved** — capture durably committed to the local outbox (`LocalCommitReceipt`). Means exactly this — not uploaded, not transcribed, not counted.
- **transcribed / parsed / logged** — derived rungs (Vo-Cal extension): transcript artifact exists / parse artifact exists / user confirmed the meal (server `meal_logs` row).

## Capture pipeline

- **Capture** — immutable voice recording + metadata; the append-only ground truth. A transcription failure is never a capture failure.
- **Session ledger** — filesystem-only state for in-progress recordings (app-group container). Never SQLite while recording.
- **Outbox** — local SQLite store of committed captures; touched once, at finalization.
- **Artifact** — immutable derived record (`transcripts`, `parses` rows). Reprocessing creates new rows, never mutations.
- **Correction** — append-only field-level diff between parsed and user-confirmed values. The training data AND the admin-audit trail.
- **Usual** — a saved meal (`saved_meals`) re-loggable in one tap.
- **Quarantine** — where unrecoverable/corrupt sessions go, visibly. Nothing vanishes silently.
- **CAF** — Core Audio Format; single-file 24kHz mono 16-bit recording. **CAFRepairer** fixes truncated files on crash recovery.
- **debug-events.jsonl** — runtime milestone trace (the truth channel); **observability.jsonl** — bounded lossy telemetry, off the hot path.

## Parser / nutrition

- **Parser contract** — the JSON schema in `docs/PARSER_CONTRACT.md`: `meal_type`, `items[]` (name, amount, unit, state, fat_ratio, brand, prep_method, confidence), `missing_details[]`.
- **The threshold** — clarifying question fires only if a missing detail could shift the meal >75 kcal or >10g of a macro. One question max, skippable.
- **Dictionary** — internal curated food table (aliases, per-100g macros, unit + raw↔cooked conversions, light/double modifiers). First-line resolution.
- **FDC** — USDA FoodData Central API; long-tail nutrition behind a read-through cache (`usda_cache`).
- **Resolution source** — `dictionary` | `fdc` | `unresolved`; feeds confidence.
- **SCORES** — committed corpus eval results (`tests/fixtures/SCORES.md`); regressions don't merge.
- **Corpus** — `tests/fixtures/transcripts.yaml`, ≥30 messy real-speech utterances; canonical four: "4oz 93/7 beef", "200g cooked jasmine rice", "Chipotle bowl…", "burger, unknown beef…".
- **Calibration** — stated confidence vs observed correction rate (admin H2 chart). If 90%-confidence items get corrected 30% of the time, the badge lies.

## Protocol

- **Protocol** — personalized targets (kcal, protein, carbs, fat, fiber) + meal structure + behavioral rules, each with a plain-English **"why"**. Engine-computed (Mifflin-St Jeor → TDEE → rails → split); AI writes prose only.
- **Rails** — engine-enforced safety bounds: deficit/surplus caps, calorie floors, protein bounds.
- **Gray area** — intake step ⑦: free-text context (injuries, meds, shift work) that doesn't fit structured fields.
- **Lingo tutorial** — the 3–4 card walkthrough teaching how to speak meals (amounts, states, ratios, brands). Positioning, not chrome.
- **Protocol version** — immutable row; check-in acceptance creates v(n+1) via `supersedes` FK.

## Beta

- **Beta gate** — the six 30-day concierge metrics (see `product.md`); computed by `scripts/beta-metrics`.
- **Concierge beta** — 5–10 hand-onboarded external TestFlight testers; runbook not yet written (phase I, step I7).
- **Thesis gate** — Phase D's exit bar: ≥10 real meals, median <30s, zero trust violations, before dashboard polish starts.

## Tech shorthand

- **XcodeGen** — `project.yml` generates the gitignored `.xcodeproj`.
- **UITestMode** — launch flag swapping real services for mocks; every screen state reachable offline.
- **DST** — deterministic simulation testing (Serein's seeded property tests for the voice kernel).
- **RLS** — Postgres row-level security; owner-only on all user tables.
- **Scribe** — ElevenLabs `scribe_v1` speech-to-text.
- **App group** — `group.com.vocal.shared`; shared container where the session ledger lives.
- **Tombstone** — soft-delete record; originals persist until explicit GC (INVARIANTS rule).
