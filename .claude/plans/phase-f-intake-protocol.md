# Phase F — Intake + Protocol Generation

> Status: Queued (blocked on Phase A only; can run parallel with B/C/D — but D outranks it)
> Owner: @lorenzo
> Branch: `phase-f-intake-protocol`
> Next: F0

## Goal

Pillar 1: P0 items 1 and 2. Welcome → phone OTP auth → multi-step nutrition intake (beyond height/weight/age/sex: activity, occupation, training, hunger history, the gray area) → a real personalized protocol (calories, protein, carbs, fats, fiber, meal structure, behavioral rules) with a plain-English "why" per target — ending in the logging-lingo tutorial that teaches users how to speak meals before their first log. This is also where activation events start flowing (beta gate: 70% complete intake+protocol). Touches: `apps/ios/VoCal/Views/{Welcome,Intake,Protocol}/`, `services/api/src/api/{intake,protocols}/`, `docs/PROTOCOL_LOGIC.md`.

## Decisions locked

- **Deterministic protocol math, AI explanation layer.** Targets come from the rule engine in `PROTOCOL_LOGIC.md` (Mifflin-St Jeor → TDEE → goal adjustment → macro split) — unit-tested, auditable. Claude writes only the "why" prose from structured inputs; it cannot change a number.
- **Safety rails in the engine, not the prompt:** deficit/surplus caps (~0.5–1% bodyweight/week), absolute calorie floors, protein bounds. Also App-Review posture (no extreme-diet output possible).
- **Phone OTP ported from Beacon** (PhoneEntry → OTPVerification → profile); no social login, so Sign in with Apple isn't required.
- **Intake gray-area answers are text in P0.** Voice-captured intake answers would be elegant but expand capture-surface scope; text only. (Flagged as future delta.)
- **Onboarding visual grammar follows the screenshots:** progress bar top, one decision per screen, large statement headlines with a gold highlight word, black pill Continue.

## Context

Until this phase lands, Today (E) runs on a stubbed protocol. The "not medical advice" disclaimer requirement and the rating-questionnaire posture are coordinated with Phase I (I3). Welcome copy is locked positioning: **"Photos guess. Voice knows."** / CTA **"Build my protocol"**.

---

## Tasks

### F0. Welcome screen

- [ ] **Step 1.** `Views/Welcome/WelcomeView.swift` — full-bleed `vcBackground`, oversized headline "Photos guess. **Voice knows.**" (gold on the highlight word, screenshot grammar), one-line subcopy on the effort thesis ("For people willing to do the work"), black pill CTA `Build my protocol`.
- [ ] **Acceptance:** first-launch routes here; auth'd users skip to Today.
- [ ] **Commit:** `feat(ios): welcome screen`

### F1. Auth port (phone OTP)

- [ ] **Step 1.** Add Supabase SPM dep to `project.yml`. Port from Beacon: `SupabaseAuthService` (+protocol+mock), `PhoneEntryView`, `OTPVerificationView`, `CountryCodePicker`, `PhoneFormatter` — restyled to Vo-Cal tokens. Profile row created on first sign-in; JWT flows through `APIClient` (already Bearer-ready from A5's dependency).
- [ ] **Step 2.** Sign-out in Settings placeholder. (Account deletion lands in I2.)
- [ ] **Acceptance:** fresh install → OTP → authenticated session persisted across relaunch; API requests carry the JWT; RLS verified end-to-end from device.
- [ ] **Commit:** `feat(ios): phone OTP auth (Beacon port)`

### F2. Intake flow

- [ ] **Step 1.** Port Beacon's `OnboardingStepContainer` pattern → `IntakeFlowView` with progress bar. Steps: ① basics (age, sex, height, weight — wheel pickers); ② goal + rate (lose/maintain/gain, slider bounded by the safety rails, with the screenshot-style affirmation interstitial "Gaining **6 kg** is a realistic target." in gold); ③ activity + occupation (sedentary→very active; desk/on-feet/manual); ④ training (type, frequency, years); ⑤ hunger + eating history (appetite pattern, problem windows, past tracking experience); ⑥ schedule → meal structure preference (meals/day, fasting window); ⑦ the gray area (free-text: injuries, meds, travel, shift work, anything).
- [ ] **Step 2.** `intake/router.py` — `POST /intake` (versioned `intake_responses` row); client autosaves per-step so a killed app resumes mid-intake (activation funnel protection).
- [ ] **Test:** step validation bounds; resume-mid-intake; API round-trip.
- [ ] **Acceptance:** full intake completes in ≤3 min self-test; killing the app mid-flow resumes at the same step.
- [ ] **Commit:** `feat(intake): multi-step intake flow + versioned persistence`

### F3. Protocol engine (rule-based core)

- [ ] **Step 1.** `protocols/engine.py` implementing `docs/PROTOCOL_LOGIC.md`: BMR (Mifflin-St Jeor) → TDEE (activity × occupation adjustments) → goal-rate kcal delta with rails → protein g/kg (goal + training age) → fat floor g/kg → carbs = remainder → fiber 14g/1000kcal → meal structure from step-⑥ prefs → behavioral rules selected from a static library keyed on intake answers (e.g. hunger-window rule, pre-logging rule, weigh-in cadence).
- [ ] **Test:** golden cases (cut/maintain/gain × male/female × activity extremes); rails clamp; all targets integer-rounded consistently.
- [ ] **Acceptance:** engine output for 6 golden personas matches hand-checked spreadsheet values exactly.
- [ ] **Commit:** `feat(protocols): deterministic protocol engine with safety rails`

### F4. AI "why" layer

- [ ] **Step 1.** `protocols/why.py` — Claude (same provider plumbing as B3) receives structured engine output + intake facts, returns per-target plain-English rationale (2–3 sentences each: kcal, protein, carbs, fat, fiber, meal structure, each behavioral rule) via tool-forced JSON; tone rules in prompt (specific to their inputs, no hype, no medical claims); length-validated; cached on the `protocols` row.
- [ ] **Step 2.** Deterministic fallback templates if the LLM call fails — protocol generation never blocks on the why layer (capture-path-isolation thinking applied to onboarding).
- [ ] **Acceptance:** generated whys reference the user's actual occupation/training inputs (spot-check 3 personas); LLM-down path still returns a complete protocol.
- [ ] **Commit:** `feat(protocols): AI why-layer with deterministic fallback`

### F5. Protocol screen + lingo tutorial

- [ ] **Step 1.** `Views/Protocol/ProtocolView.swift` — targets as StatCards (numerals + gold accents), each with a "why" expander; meal structure section; behavioral rules list; "not medical advice" disclaimer footer (I3 copy); black pill `Start logging`.
- [ ] **Step 2.** Lingo tutorial (3–4 cards, swipeable, screenshot onboarding grammar): ① say amounts + units ("4 ounces, 200 grams"); ② say states + ratios ("cooked rice, 93/7 beef"); ③ say brands + prep ("Kerrygold, pan-fried"); ④ every ingredient gets its own breath — ending CTA straight into the first voice log. Effort framing is the product's spine — this tutorial is positioning, not chrome.
- [ ] **Step 3.** `POST /protocols/generate` endpoint wiring; `ProtocolService` (+mock); re-view protocol anytime from Settings.
- [ ] **Acceptance:** fresh user lands on Today with live targets after tutorial; protocol re-viewable; whys render.
- [ ] **Commit:** `feat(ios): protocol screen + logging-lingo tutorial`

### F6. Activation events

- [ ] **Step 1.** Client metric events: `intake_started`, `intake_step_completed(n)`, `intake_completed`, `protocol_generated`, `protocol_viewed`, `tutorial_completed`, `first_log_started` — into the D4 pipeline; `scripts/beta-metrics` activation row switches from placeholder to real funnel.
- [ ] **Acceptance:** funnel visible step-by-step in `client_metrics` for a fresh test user.
- [ ] **Commit:** `feat(metrics): activation funnel events`

---

## Exit Criteria

- ✅ Fresh install → OTP → intake → protocol with per-target whys → lingo tutorial → Today with live targets.
- ✅ Protocol numbers are deterministic, rail-clamped, and reproducible from the intake row.
- ✅ Whys reference the user's actual inputs; LLM failure degrades gracefully.
- ✅ Activation funnel events flowing into beta-metrics.

## Amendments

*(none yet)*

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| F0 Welcome | not started | — |
| F1 Auth port | not started | — |
| F2 Intake flow | not started | — |
| F3 Protocol engine | not started | — |
| F4 AI why layer | not started | — |
| F5 Protocol screen + tutorial | not started | — |
| F6 Activation events | not started | — |
