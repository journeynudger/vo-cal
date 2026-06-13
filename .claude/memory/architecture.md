# Architecture

> Phase A complete: scaffold, schema (written, unapplied — docker down), tooling, doctrine all real. Voice port in flight (C0 done). Update sections as phases land.

## Stack

| Layer | Tech | Path | Source of the pattern |
|-------|------|------|----------------------|
| iOS | Swift 6 (strict concurrency), SwiftUI, iOS 26+, XcodeGen | `apps/ios/` | Beacon |
| Voice | `VoCalVoice` SPM (state machine + CAFRepairer) + app-layer coordinator | `Sources/VoCalVoice/`, `apps/ios/VoCal/Voice/` | Serein (port) |
| Shared types | `VoCalCore` SPM (parser contract, IDs, codecs) | `Sources/VoCalCore/` | new |
| API | FastAPI, Python via uv | `services/api/` | Beacon |
| Worker | In-repo enrichment worker (transcribe → parse) | `services/api/src/api/enrichment/` | Serein pattern, Python |
| DB / Auth / Storage | Supabase (Postgres + RLS, phone OTP, `capture-audio` bucket) | migrations TBD Phase A6 | Beacon |
| Admin | Next.js internal panel | `services/admin-web/` | Beacon web shape |
| Deploy | Fly.io (API + worker), hosted Supabase | Phase I5 | Beacon |

Providers: ElevenLabs Scribe (`scribe_v1`) transcription; Claude tool-forced structured output for parse (`PARSER_MODEL`, default `claude-sonnet-4-6`) and "why"/check-in phrasing; USDA FoodData Central for long-tail nutrition.

## Data flow

speak → capture (filesystem session ledger) → local outbox commit (**"Saved"**) → upload (queue/planner/worker) → blob + immutable `captures` row (**uploaded**) → `transcripts` artifact → `parses` artifact (**ready**) → user confirm (**logged**, `meal_logs` + append-only `corrections`) → Today aggregation.

## Data model (immutability classes)

- **Immutable after commit:** `captures`, `transcripts`, `parses`, `corrections`, `checkins`, `admin_reviews`, protocol versions.
- **Append-only:** corrections (never patch a parse), protocol re-versions (`supersedes` FK), tombstone deletes for `meal_logs`.
- **Mutable:** `profiles`, `saved_meals`, caches (`usda_cache` — derived, rebuildable).
- RLS owner-only on all user tables; `food_dictionary`/`usda_cache` read-all; `admin_*` service-role only.

## Project-wide rules (the short list; full doctrine in AGENTS.md post-A1)

1. **Capture-path isolation (Serein).** Nothing non-audio may gate, delay, or sit on the mic-hot path. Test: delete the subsystem — does capture still work? Then it doesn't belong on the path.
2. **Claim ladder, proofs not booleans.** `accepted → mic_active → confirmed_listening → saved` + derived `transcribed → parsed → logged`. UI states are projections of proof types (`LocalCommitReceipt`), never optimistic flags.
3. **LLM extracts; deterministic code calculates.** Macro math, unit conversion, thresholds, protocol targets are Python with tests. The LLM never invents numbers.
4. **Same storage ≠ same authority.** Stores record facts; planners decide next work; workers perform effects. Don't fuse.
5. **Thin client (Beacon).** Business logic server-side; the one exception is the local-first capture path.
6. **iOS notifications are observations, not commands.** Default response non-destructive; destructive action needs evidence beyond the notification.
7. **Corpus is binding.** `scripts/parser-eval` SCORES regression does not merge (post-B7).
8. **Never edit Beacon or Serein.** Copy out only.

## Verification tiers (budgets measured in A7/C6 — fill in)

| Command | Proves | Budget |
|---------|--------|--------|
| `scripts/check-api` | ruff + pytest for `services/api` | TBD |
| `scripts/check` | SPM `swift test` + check-api | TBD |
| `bin/ios-app-build` | app compiles, zero warnings (no simulator) | TBD |
| `bin/ios-sim-voice-test` | 9 voice scenarios on pinned simulator | TBD |
| `scripts/parser-eval` | corpus SCORES (no regression) | TBD |

Pick the narrowest tier that proves the change given blast radius; batch compile fixes, rebuild once.

## Conventions

- Branches `phase-<letter>-<slug>`; Conventional Commits with scope (`feat(ios):`, `feat(api):`, `feat(voice):`, `docs(plans):`).
- One commit per task; tick the sub-plan `[x]` + SHA in the same commit.
- Design tokens live in `apps/ios/VoCal/Theme/VoCalTheme.swift` only — no inline hex in views. Reference: `docs/DESIGN.md`.
- iOS: `@Observable` ViewModels; services behind protocols with mocks (`-UITestMode` flag swaps them); accessibility IDs in `A11y.swift`.
- API: one package per domain with `router.py` / `schemas.py` / `store.py`; observability middleware on everything.
- Identifiers: bundle `com.vocal.app`, app group `group.com.vocal.shared`, scheme `VoCal` (confirm in I0).
