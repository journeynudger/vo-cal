# Master Plan — Vo-Cal to TestFlight

> Status: Active.
> Source: Approved reuse inventory + build order (2026-06-12 session): Beacon scaffold + Serein voice layer, FastAPI/Supabase single backend, foreground-only capture, black/gold Cal-AI design.

## Context

Vo-Cal is a voice-first macro tracker for people willing to do the work: speak every ingredient, get an accurate log faster than typing. **The one thing this build must prove: people will log meals by voice and trust the output.** Every phase is sequenced so that proof arrives as early as possible (Phase D) and everything after it is supporting cast.

Nine phases (A–I) take the project from empty directory to a TestFlight build with the 30-day concierge beta instrumentation live. Per-phase work lives in its own sub-plan in this directory. P0 scope is fixed (ten items, listed below); the out-of-scope list is a hard MUST-NOT.

This is a reuse-first build. **Never edit, delete, or restructure anything inside Beacon or Serein — copy out only.**

## The product thesis (resolves ambiguity during any phase)

- Photos guess; voice knows. Voice captures what a photo can't: beef fat ratio, cheese type, condiment amount, prep method.
- Weighing and knowing your food is table stakes. Vo-Cal's edge is the **handoff**: spoken, fully-specified meal → accurate log, faster than typing.
- Users voice every individual ingredient, not "burger with cheddar." A short lingo tutorial teaches this up front. Effort is required by design.
- Pillar 1: a real personalized nutrition protocol (activity, occupation, training, hunger history, the gray area — beyond height/weight/age/sex).
- Pillar 2: low-friction, high-accuracy voice meal logging.

## P0 scope (build ONLY these)

1. Nutrition onboarding intake — Phase F
2. Protocol generation (rule-based + AI, plain-English "why" per target) — Phase F
3. Voice meal capture (Serein layer) — Phase C
4. Transcript-to-food parser (structured output) — Phase B
5. Macro estimate (USDA FoodData Central + internal food dictionary) — Phase B
6. Confidence score per item — Phase B
7. ONE clarifying question, only when a missing detail could shift the meal by >75 cal or >10g of a macro — Phase B (engine) + D (UX)
8. Daily macro dashboard — Phase E
9. Weekly check-in — Phase G
10. Manual admin review panel — Phase H

**Out of scope — do not build:** photo logging, social features, payments/billing UI, branded/restaurant database, gamification, text-search food logging, anything not in the list above.

## Beta gate (30-day concierge beta success criteria)

These numbers are the binding gate; instrumentation that produces them is in-scope work (Phase E task E3, Phase D task D4, Phase F task F6, verified in Phase I).

| Metric | Target |
|---|---|
| Activation | 70% complete intake + protocol |
| Engagement | 10+ meals logged in first 7 days |
| Log speed | avg log under 30s |
| Trust proxy | correction rate under 25% by end of week 2 |
| Retention | 50%+ retained at 14 days |
| Willingness to pay | 5 users at $15–25/mo OR 1 coach at $50–100/mo |

## Phase status

| Phase | Title | Sub-plan | Status |
|---|---|---|---|
| A | Foundation & scaffold | [`_completed/phase-a-foundation.md`](./_completed/phase-a-foundation.md) | ✅ Done |
| B | Parser + nutrition engine | [`_completed/phase-b-parser-nutrition.md`](./_completed/phase-b-parser-nutrition.md) | ✅ Done |
| C | Voice capture port (Serein → VoCalVoice) | [`phase-c-voice-port.md`](./phase-c-voice-port.md) | 🟡 Active (C0 done) |
| D | Voice log loop end-to-end (the thesis) | [`phase-d-voice-log-loop.md`](./phase-d-voice-log-loop.md) | ⏳ Queued (after B + C) |
| E | Today dashboard + beta-gate metrics | [`phase-e-today-dashboard.md`](./phase-e-today-dashboard.md) | ⏳ Queued (after D) |
| F | Intake + protocol generation | [`phase-f-intake-protocol.md`](./phase-f-intake-protocol.md) | ⏳ Queued (after A; parallel with B/C/D) |
| G | Weekly check-in | [`phase-g-weekly-checkin.md`](./phase-g-weekly-checkin.md) | ⏳ Queued (after E + F) |
| H | Admin review panel | [`phase-h-admin-review.md`](./phase-h-admin-review.md) | ⏳ Queued (after D) |
| I | TestFlight readiness & publish | [`phase-i-testflight.md`](./phase-i-testflight.md) | ⏳ Queued (last) |

## Dependencies

```
A ──→ B ──┐
A ──→ C ──┴──→ D ──→ E ──┐
A ──→ F ─────────────────┼──→ G
              D ──→ H ───┤
E + F + G + H ───────────┴──→ I (TestFlight)
```

- B and C are independent of each other and can run in parallel (B is backend-only pytest work; C is Swift port work).
- F needs only A (backend scaffold + design system) — it can run in parallel with B/C/D whenever D stalls, but D outranks it: the thesis gate comes first. Until F lands, Today uses stubbed protocol targets via mock services.
- D is the **thesis gate**: real device, speak a meal, trusted log in under 30s. Do not start E polish before D's exit criteria pass.
- I starts only when E, F, G, H are done. Its App Review prep tasks (privacy copy, account deletion) can be drafted earlier if a session has slack, but the phase itself runs last.

## Decisions locked (master level)

Dated 2026-06-12, from the approved first-pass review. Re-litigating any of these requires a master-plan amendment.

- **Single backend: FastAPI + Supabase (Beacon shape).** Serein's Go/Fly/Tigris side is NOT carried. Its enrichment-worker design (claim/retry/backoff, immutable artifacts, transient-vs-permanent errors) is re-implemented in Python. One stack, not two.
- **Foreground-only capture for P0.** Serein's `VoiceCaptureIntent` (Action Button) + `VoiceLiveActivity` are not ported. `UIBackgroundModes: audio` IS enabled so an in-progress recording survives app-switch/lock mid-meal. Reversible later for lock-screen logging.
- **Claim ladder extended, not altered:** `accepted → mic_active → confirmed_listening → saved` (Serein, verbatim semantics) plus derived rungs `transcribed → parsed → logged` (logged = user confirmed). "Saved" means audio durably committed locally — never "macros counted."
- **Audio is ground truth; the meal log is a derived record.** Corrections never mutate — they are append-only records referencing the original parse. They are simultaneously the training data and the admin-audit trail.
- **Voice-only logging.** No text-search food logging (out of scope). Manual *editing* of parsed items before confirm is in scope.
- **Design: Cal AI screenshot layout, black/gold palette.** Background `#FAF9F6`, cards `#F4F2EE` r24, text `#1A1A1A`/`#8A8A8E`, black pill CTAs `#111111`, gold `#C4A35A` for highlighted numerals/active/confidence. Macro chips keep semantic colors (protein red / carbs amber / fats blue) for glanceability. SF Pro; numerals 40–64pt semibold.
- **Auth: phone OTP via Supabase, ported from Beacon** (PhoneEntry → OTPVerification → profile row). Proven code; no third-party social login, so Sign in with Apple is not required by App Review.
- **Transcription: server-side ElevenLabs Scribe** (Serein's proven provider), called from a FastAPI enrichment worker. Keeps audio as auditable ground truth against the transcript.
- **Parser LLM: Claude with tool-forced structured output.** Default `claude-sonnet-4-6`, env-overridable (`PARSER_MODEL`); `claude-haiku-4-5-20251001` is the latency fallback to evaluate in Phase B.
- **App group kept** (`group.com.vocal.shared`) even with no extensions in P0 — minimizes diffs in the Serein port and future-proofs share/widget surfaces.
- **Offline-capable capture path** (inverts Beacon's "no offline mode," which applies to everything *except* capture): speaking a meal works with no signal; capture commits locally; transcription/parse catch up when online. Server data is authoritative for everything else.

## Reuse map (where ported code comes from)

| Vo-Cal surface | Source | Path |
|---|---|---|
| Repo scaffold, Makefile, XcodeGen `project.yml`, CI, pre-commit | Beacon | `beacon/` root + `beacon/apps/ios/project.yml` |
| iOS service layer (Protocols + Mocks + UITestMode), `APIClient`, onboarding step container, OTP screens | Beacon | `beacon/apps/ios/Beacon/Services/`, `Views/Onboarding/` |
| FastAPI domain shape (router/schemas/store), observability middleware, metrics ingestion, instrumented DB client | Beacon | `beacon/services/python/src/api/` |
| Publish-to-TestFlight skill (bump-version, ExportOptions, archive/upload) | Beacon | `beacon/.claude/skills/publish/` |
| Voice state machine + CAF repair (SPM) | Serein | `Serein/Sources/SereinVoice/` |
| Voice coordinator, audio session config, session store, liveness, recovery | Serein | `Serein/apps/ios/SereinApp/Sources/VoiceCapture*.swift` |
| Local outbox, capture paths, JSONL debug recorder | Serein | `Serein/apps/ios/Shared/Sources/` |
| Sim voice self-test harness | Serein | `Serein/apps/ios/SereinApp/Sources/VoiceSelfTestRuntime.swift` + `Serein/bin/ios-sim-voice-test` |
| Voice doctrine docs (claim ladder, invariants) | Serein | `Serein/docs/VOICE_CAPTURE.md`, `Serein/docs/INVARIANTS.md` |
| Engineering doctrine (How to Think / How to Write / verification tiers) | Serein | `Serein/AGENTS.md` |
| Enrichment worker *pattern* (re-implemented in Python) | Serein | `Serein/services/capturerelay/internal/enrich/worker.go` |

## Amendments log

### 2026-06-18 — Right-sizing pass (lean for a 5–10 user beta)

Three scope-reducing decisions (memory/decisions.md #24–27), each removing a provider/dependency/build with no thesis loss:
- **Transcription on-device** (Apple iOS 26 SpeechTranscriber), not server ElevenLabs. C5 worker shrinks to parse-only; app posts transcript to /parse. Audio still uploads for audit.
- **Admin review = `scripts/review` CLI + Supabase Studio**, not a Next.js app. Phase H collapses to scripts.
- **Auth = Sign in with Apple**, not phone OTP. No SMS provider, no phone PII.
- No Prometheus stood up for the beta (dormant ported code).

Cross-plan scope changes that affect multiple sub-plans land here. Per-phase scope changes go in the relevant sub-plan's Amendments section.

### 2026-06-12 — Plans created

Master plan + nine sub-plans (A–I) generated from the approved reuse inventory and build order. No code exists yet; Phase A is the first executable sub-plan.
