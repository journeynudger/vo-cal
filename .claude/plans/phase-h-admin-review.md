# Phase H — Admin Review Panel

> Status: Queued (blocked on Phase D — needs real logged data shapes)
> Owner: @lorenzo
> Branch: `phase-h-admin-review`
> Next: H0

## Goal

P0 item 10: the internal panel for auditing AI output during the concierge beta — hear the audio, read the transcript, inspect the parse, see exactly what the user corrected, and record a verdict. This is validation infrastructure (not user-facing): it's how correction-rate numbers get explained, how parser prompt iterations get evidence, and how trust failures get caught before users mention them. Touches: `services/admin-web/` (new Next.js app), `services/api/src/api/admin/`.

## Decisions locked

- **Next.js app in `services/admin-web/`** (Beacon's `services/web` shape) — boring, fast to build, never ships to users. Local-first (`make admin-dev`); deployment optional and access-gated if ever needed.
- **Admin access = Supabase auth + email allowlist enforced server-side** on every `/admin/*` route (service-role key never leaves the API). Simple and sufficient for a one-admin beta.
- **Admin reads are audit-logged** (Serein auditability value): every audio access writes an `admin_reviews`-adjacent audit row. Users' food diaries and voice recordings are sensitive — access must be explainable.
- **Verdicts are a fixed taxonomy**, not free text only: `parse_ok`, `parse_wrong_item`, `parse_wrong_amount`, `resolution_wrong_food`, `question_should_have_fired`, `question_unnecessary`, `transcript_wrong` + notes. Aggregatable, feeds parser iteration priorities.

## Context

Needs D (real meal_logs + corrections flowing). Reuses B7's SCORES thinking applied to production data: the panel's aggregates view is the live counterpart of the offline corpus eval.

---

## Tasks

### H0. Admin API

- [ ] **Step 1.** `admin/router.py` — allowlist-gated: `GET /admin/logs` (filterable: low confidence, has corrections, question asked/skipped, user, date range; paginated), `GET /admin/logs/{id}` (full chain: capture metadata + signed audio URL (short TTL) + transcript + parse JSON + confirmed items + field-level corrections diff + client metrics for that log), `POST /admin/logs/{id}/review` (verdict + notes → `admin_reviews`), `GET /admin/aggregates` (correction rate trend, confidence calibration buckets — stated confidence vs observed correction rate, question precision, per-food-source accuracy dictionary-vs-FDC).
- [ ] **Step 2.** Audit logging on every detail/audio read (who, what, when).
- [ ] **Test:** allowlist enforcement (non-admin JWT → 403), signed-URL TTL, aggregates math on seeded fixtures.
- [ ] **Acceptance:** pytest green; non-admin access provably impossible.
- [ ] **Commit:** `feat(admin): review API with audit-logged reads`

### H1. Review queue + detail UI

- [ ] **Step 1.** `services/admin-web/` Next.js scaffold (Beacon web conventions, plain Tailwind, no design-system ceremony — internal tool). Queue page: filter chips, table (user, time, meal, confidence, corrections count, question status, review status).
- [ ] **Step 2.** Detail page: audio player (signed URL), transcript pane, parse JSON tree alongside rendered item cards, corrections diff view (parsed → confirmed, field-level, highlighted), verdict buttons + notes, prev/next for queue flow.
- [ ] **Acceptance:** audit a real meal end-to-end — listen, compare, verdict — in under a minute per log.
- [ ] **Commit:** `feat(admin-web): review queue + audit detail view`

### H2. Aggregates dashboard

- [ ] **Step 1.** Aggregates page: correction-rate trend by week, confidence calibration chart (if 90%-confidence items get corrected 30% of the time, the badge is lying — this chart is the trust check on the trust feature), question precision (asked-and-answer-changed-macros vs asked-and-skipped/no-change), top corrected foods (dictionary gap list → feeds B1 dictionary additions).
- [ ] **Step 2.** Beta-gate numbers row (reuse `scripts/beta-metrics` queries as API) so the weekly review is one page.
- [ ] **Acceptance:** page renders real aggregates from dev data; dictionary gap list points at actual missing foods.
- [ ] **Commit:** `feat(admin-web): aggregates + calibration dashboard`

---

## Exit Criteria

- ✅ Any meal auditable end-to-end (audio → transcript → parse → corrections → verdict) with all access audit-logged.
- ✅ Confidence calibration and question precision visible — the parser iteration loop has evidence.
- ✅ Non-admin access mechanically impossible; signed audio URLs expire.

## Amendments

*(none yet)*

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| H0 Admin API | not started | — |
| H1 Queue + detail UI | not started | — |
| H2 Aggregates dashboard | not started | — |
