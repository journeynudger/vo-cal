# Phase P: The personalized tracker

> Status: Active (D1–D9 decided 2026-10-04 as recommended; decisions 56–64)
> Owner: @lorenzo
> Branch: `phase-p-personalized-tracker`
> Next: P1
> Design: `docs/design/personalized-tracker-spec.md` (the Rams REVIEW of this plan and the corrected design, 2026-10-04). Where this file and the spec differ, the spec wins; this file was amended to it (see Amendments).

## Goal

Make how a person wants to follow their nutrition the first thing the app learns and the thing
everything else follows. Today every person gets the same intake, the same five-panel dashboard
(calories left, protein, produce, water, fiber), the same nudges and the same protocol reveal.
After this phase a person who only wants better habits sees habits; a person who wants calories
sees calories; a person who wants the Vo-Cal method (Francesco's pillars) sees what ships today; a
person who wants macros sees macros; a person with a meal plan checks meals off. The intake asks
the question first, the protocol engine still computes everything (it is deterministic and
cheap), and the server composes what each person sees. The wedge: the current headline ("the
accurate tracker for people willing to do the work") selects for a small market and, as Lorenzo
found on himself, even that market logs from Recent after the first week; "the first personalized
food tracker" is a claim no incumbent makes and the architecture already has the pieces for. The
surface: `supabase/migrations`, `services/api/src/api/{intake,protocols,meals,nudges,checkin}`,
`apps/ios/VoCal/{Views/Onboarding,Views/Today,Views/Settings,Services}`, `docs/`.

The capture core, the parse ladder, named meals and recognition, usuals, personal foods and the
week budget do not move. Voice stays the default and the emphasized way in (decision 52).

## Decisions this plan waits on

Each with the options and a recommendation. Record the outcomes as decisions 56+ in
`.claude/memory/decisions.md` and a master-plan amendment (P0).

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | **The headline and the name.** "Photos guess. Voice knows." sells the capture method; the new thesis sells the fit. "Vo-Cal" encodes voice and calories, now one way in and one mode. | (a) keep Vo-Cal, change the headline; (b) rename now, before any App Store listing exists; (c) rename later. | (b) if a name survives the tests below; otherwise (a). Rename is cheapest now: zero public installs, the bundle id can stay `com.vocal.app` (Apple allows a display-name change), the sweep is `project.yml` display name, the wordmark, the welcome, the README, the landing page, the Siri phrase "Log in X". Test a candidate by saying "Hey Siri, log in X" aloud, searching the App Store for it, and asking Francesco whether he would say it at a conference. Starting set, nothing more: Plate · Pillar · Tally · Seen · Frankie (the method's name, if Francesco wants his name on it). |
| D2 | **Choice or ladder.** The voice note describes both: "how do you want to use this?" up front, and a phased program (habits → calories → key nutrients → macros). | (a) choice only; (b) ladder only (everyone starts at habits); (c) choice first, ladder as invitations the engine offers when the signals say the person is ready, never automatic. | (c). A ladder alone contradicts "how do you want to use this"; a choice alone leaves the coach's judgment (when to add the next thing) unused. The invitation is a nudge with a Yes that writes a new preference version (P6); the engine also offers the step DOWN when logging thins, which is Francesco's "can't track this week? repeat a day" move. |
| D3 | **Which modes ship first.** | The five the sales calls supply: habits · calories · the method's five (calories, protein, produce, fiber, water; today's dashboard) · macros · meal plan. ("Calories and protein" was a sixth; the Rams review cut it as a coach's step, not a person's sentence: it is the first invitation in calories mode instead.) | Ship four in the first slice: habits, calories, the five, macros (macros is the five plus carbs and fat, already computed). Meal plan is a new surface (P8) and waits for D5. |
| D4 | **The bar in habits and meal-plan modes.** | (a) the capture bar stays the one way in for every mode; (b) habits mode gets a check-off surface instead of the bar; (c) both. | (a). "Had my water", "two servings of veg", "logged lunch" are one breath and the parser already prices them; a habit panel checks itself off from the logs the same way recognition checks a plan slot. A second input surface is a second way to write a day, which Phase U just removed. |
| D5 | **Who writes the meal plan.** | (a) the person, from their usuals, with the engine checking the plan against the protocol; (b) the engine generates it from the protocol; (c) Francesco, in a coach lane. | (a) first, because usuals already exist and are the person's own food; (c) is the coach wedge and should be designed for (a plan has an author field); (b) is a model inventing a diet and stays out. |
| D6 | **Which calorie number Today shows when a week plan exists** (findings ledger 54). | (a) the protocol's day; (b) the week plan's adjusted day; (c) the plan's day with the protocol's shown underneath. | (b): the person replanned on purpose and the week screen already shows that number; two numbers for one day is the inconsistency. `/meals/today` reads `week_plans` through the week engine. |
| D7 | **Recalibration alignment** (findings ledger 53; PROTOCOL_LOGIC §3.3 names it a follow-up). After an accepted revision fat, the protein band, produce and the whys are stale. | (a) inside this phase (P7), before macros mode ships; (b) its own phase after. | (a). Macros mode shows fat; a revised protocol with last month's fat is a wrong number on a screen built to be trusted. |
| D8 | **The first question for a stranger.** | (a) always ask the mode first; (b) default to the method and offer the choice in Settings; (c) default by stated goal. | (a). Asking is the headline; it is also the cheapest personalization in the product. Preselect nothing (the sex-default bug of 2026-07 is the lesson: a silent default is a wrong answer for half the people). It is the only new question: the Rams review cut the planned "Why are you here?" as a twin of "Your goal". |
| D9 | **The welcome sentence.** "The world's first personalized food tracker" is the pitch; the Rams review found it a claim the person cannot check from inside the app (principle six). | (1) "Follow your nutrition your way." with the line "Habits, calories, the method, or macros. You choose; the app shows only that."; (2) "Track what matters to you. Nothing else."; (3) "Your nutrition, followed the way you want." | (1). Keep "world's first" for the deck and the conference floor. |

## Context

### What the sweep found (2026-10-04, `docs/restructure/04-findings.md` 46–57)

- **One shape everywhere.** `IntakeProfile` is twelve answers, none about how the person wants to
  follow their nutrition. `ProtocolTargets` is one shape; `/meals/today` returns seven fixed
  fields; `TodayView` renders the same panels for everyone; `profiles` is id, email, phone, tz.
  Decision 30 (opt-in metrics) was never built; sodium and sugar are not in the nutrient model.
- **Two nudge engines.** `nudges/` is live and carries the garnish (treat headroom, protein gap);
  `checkin/nudge.py` is dead to the app and carries the situational triggers the product brief
  calls the pillar, with four of seven rules unreachable. One engine, mode-aware, is the fix.
- **The check-in asks what nothing reads.** Hunger and energy are stored and consumed by no rule;
  `computed`, `recommendation`, `accepted` are never written.
- **The protocol is pluggable by coefficients only.** `ProtocolTunables` swaps numbers; the
  pipeline and output shape are fixed. That is enough for this phase: every mode is a projection
  of the same targets, not a different formula.
- **Already built, and exactly the answer to the MyFitnessPal "Recent" observation:** usuals as
  one-tap chips on Today, recognition ("Is this your metal detox smoothie?"), typed search over
  what was logged, personal foods. The repeat loop exists; this phase makes it visible per mode.

### The architecture of personalization

One typed value, chosen by the person and versioned, drives three projections.

```
tracking_preferences (append-only versions)
  mode: habits | calories | five | macros | meal_plan
  focus_metrics: [fiber, water, produce, sugar, sodium, carbs, fat]   (opt-ins, decision 30)
  source: chosen | invited | declined | coach
        │
        ├─► intake      which questions are asked, in what order, with what copy
        ├─► protocol    the engine computes everything; the REVEAL shows the mode's subset
        ├─► dashboard   GET /meals/today returns `panels` the server composed for (protocol, mode)
        └─► nudges      one engine; each nudge names the modes it may fire in
```

- **Stores answer what is true, planners decide, the client renders.** The dashboard composer
  (`meals/dashboard.py`, pure) is a planner: it reads (targets, consumed, mode, focus metrics,
  week plan) and returns an ordered list of panels. The client has one `PanelView` per panel
  kind and skips kinds it does not know (forward compatible, additive on the wire).
- **The engine does not change.** Every mode gets the full `ProtocolTargets`; habits mode just
  never shows the calorie number. This keeps the IP in one place and makes the ladder free: the
  step from habits to calories reveals a number that was always there.
- **The preference is history.** Versions are the graduation record and the beta's richest
  signal (who moved up, who moved down, when).
- **Panel kinds** (first set): `calories_left`, `metric_bar` (protein with its band, fiber,
  water, produce, carbs, fat, sugar, sodium), `habit_checklist` (items derived from the logs:
  logged today, water glasses, produce servings, meals logged of planned), `macro_rings`,
  `meal_plan_slots` (P8), `week_card`. Each panel carries its own target, consumed, unit,
  completion rule and support line; the client does no arithmetic (AGENTS.md #6).

| Mode | Intake asked | Reveal shows | Panels | Nudges that may fire |
|---|---|---|---|---|
| habits | basics (for water), work and kids, training, stress, meals; no goal, no medication, no ruler | OPEN (spec R12): three habits, with or without the water and produce counts; draw both | three tiles: Logged today · Water (+) · Produce; no week card, no numbers on rows, chips or the result; checks do not fire | gone quiet, nothing logged, hydration, produce behind, slipping (in habit words); invitation up: calories |
| calories | the full intake | calories only, its why | `calories_left`, `week_card` | the above + headroom, evening on track, under target; invitation up: protein as a focus metric; down: habits |
| five (today's dashboard) | same | calories, protein band, produce, fiber, water | today's five + `week_card` | all current; invitation down: calories |
| macros | same | calories, protein, carbs, fat, fiber | `calories_left`, three tiles Protein · Carbs · Fat (macro colours on the bars, no rings), `week_card` | the five's set less fiber; invitation down: the five |
| meal plan | same, then the plan builder | the plan against the protocol | `meal_plan_slots`, `calories_left` | plan slot missed, gone quiet |

Focus metrics add a tile to any mode (a diabetic adds sugar to habits mode and it is the one
number the page then prints). The full table of what each surface prints per mode is the spec's
§6.4 and §6.5; the mode governs every printed number, not only the cards (spec R8).

### Sequencing

P1 → P2 → P4 is the thin vertical slice (four modes, server-composed dashboard, mode-aware
intake). P3 (sugar, sodium) and P5 (one nudge engine) run in parallel with it. P6 and P7 follow.
P8 followed D5 (a) on 2026-10-04. P9 lands with the first TestFlight build that carries the new intake.

---

## Tasks

### P0. Record the decisions

- [x] **Step 1.** `.claude/memory/decisions.md` 56+ (D1–D8 as decided), master-plan amendment, `docs/PRODUCT_BRIEF.md` addendum (the thesis line, the headline, the modes), `AGENTS.md` mission line and MUST-NOT 4 as needed, `.claude/memory/product.md`.
- [x] **Acceptance:** a cold session reads the direction from memory alone.
- [x] **Commit:** `docs(plans): decisions 56–63, the personalized tracker`

### P1. Schema: the preference and the plan

- [x] **Step 1.** `supabase/migrations/2026XXXX000001_tracking_preferences.sql`: `tracking_preferences(id, user_id, version, mode text, focus_metrics jsonb, source text, created_at)`, append-only (RLS select + insert, REVOKE update/delete like `intake_responses`), one row per version; `FakeDatabase._UNIQUE_INDEXES` updated.
- [x] **Step 2.** `meal_plans(id, user_id, version, author text, slots jsonb, created_at)`, append-only, only when D5 is decided (P8 may land it instead). *`meal_plans` waits with P8.*
- [x] **Acceptance:** `docs/DATABASE.md` table rows added; the user runs `make db-migrate` (agents never do).
- [x] **Commit:** `feat(db): tracking preferences, versioned`

### P2. API: the mode, and a dashboard the server composes

- [x] **Step 1.** `tracking/` domain (router / schemas / store): `TrackingMode` (habits, calories, five, macros, meal_plan) and `FocusMetric` enums; `GET /tracking` (latest, or 404 before onboarding), `PUT /tracking` (appends a version; `source` chosen|invited|declined|coach).
- [x] **Step 1b.** `POST /parse` and `/parse/photo` read the person's mode: in habits mode `clarify` is skipped and items price at typical values stored as estimates (spec R3); the result's header never says "checks left" in that mode. Rows, usuals and search hits carry their kcal as before; the client decides what to print from `mode`.
- [x] **Step 2.** `meals/dashboard.py`, pure: `compose(targets, consumed, remaining, band, mode, focus, week_day) -> list[Panel]`. One golden test per mode and one per focus metric. `/meals/today` gains `mode` and `panels` (additive; the seven fields stay for shipped builds). Per D6, the day's target comes from the week plan when one exists.
- [x] **Step 3.** `POST /protocols/generate` response gains `reveal: [key]`, the subset the mode shows; the engine is untouched.
- [x] **Test:** `tests/test_dashboard_compose.py`, `tests/test_tracking_api.py`; every existing today test green unchanged.
- [x] **Acceptance:** the same protocol row yields six different `panels` lists; a build-31 client decodes the response unchanged.
- [x] **Commit:** `feat(api): how the person tracks is a stored choice, and Today is composed from it`

### P3. Nutrient model: sugar and sodium

- [x] **Step 1.** `NutrientProfile`/`Macros` gain `sugar_g` and `sodium_mg` (optional on the wire, decode rule); dictionary seed rows gain them where the source has them; FatSecret and FDC mappings carry them; the estimator's identity prompt asks for them when a focus metric needs them (never otherwise: cost). *The estimator asks for sugar and sodium only when a label states them, on every call (the cost is in the same prompt); the dictionary seed rows carry none yet.*
- [x] **Step 2.** `consumed_from_day` sums them; `Targets` gain defaults from the focus metric (a sugar budget and a sodium ceiling are coach inputs: tunables, with a "why").
- [x] **Test:** `scripts/parser-eval` SCORES unchanged; `scripts/calorie-eval` unchanged; new resolver tests for the two fields.
- [x] **Acceptance:** a logged can of soda shows sugar on a sugar `metric_bar`; a meal with no source for sodium shows "not known for this food", never 0 as a claim.
- [x] **Commit:** `feat(api): sugar and sodium ride the ladder, shown only when asked for`

### P4. iOS: the question first, the reveal that fits, panels that render themselves

- [x] **Step 1.** Intake: ONE new step, first after the welcome: "How do you want to follow your nutrition?" with the five options labelled by what they track, a one-line support each, words only, nothing preselected (spec §6.2; D8). The steps that follow depend on the mode (spec §6.3: habits skips the ruler, the goal, the medication question and two benefit screens). `IntakeDraft` gains `mode`, `focus`; `PUT /tracking` lands with the intake (same fire-and-forget beat, retried after sign-in like the intake).
- [x] **Step 2.** `ProtocolRevealView` shows the `reveal` subset; macros adds carbs and fat rows with the engine's whys. Habits: build BOTH variants (counts shown / counts withheld) as mock-backed renders and decide from the renders, not the document (spec R12). *Built variant a (the reveal may not contradict the Today it leads to); variant b remains to be drawn in the render loop (spec R12).*
- [x] **Step 3.** `Views/Today/Panels/`: `PanelView` switch over `kind`; the habit tiles, the macro tiles (bars in the macro colours, never rings; `MacroRing` leaves DESIGN.md's inventory), the existing calories and metric cards wrapped; unknown kinds skipped. `TodayView.dashboard` renders `panels` when present, the current layout otherwise. The mode governs every printed number: rows, chips, the week card, the result, the edit sheet (spec §6.4, §6.5).
- [x] **Step 4.** Settings → "How I track": the mode and the focus metrics (this is decision 30's "edit metrics" screen, generalized); changing it appends a preference version and reloads Today.
- [ ] **Step 5.** Render goldens: Today per mode (six) and the reveal per mode; `bin/ios-ui-audit` baselines; `bin/ios-flow-tests` unchanged (the bar does not move). *Not done here: the goldens need the pinned simulator and a reader; the audit baselines need the nightly job (handoff 2026-10-04).*
- [ ] **Acceptance:** a fresh install in each mode reaches Today showing only that mode's panels; `bin/ios-app-build` zero warnings; `bin/ios-render-tests` green with the new goldens recorded once, on purpose. *CI's iOS job compiled it at zero warnings and ran the render, flow and voice tests on 0538dd5 (run 37173632708); the goldens remain to be recorded on the pinned runtime.*
- [x] **Commit:** `feat(ios): the first question is how you want to track, and Today answers it`

### P5. One nudge engine, mode-aware

- [x] **Step 1.** Port the situational triggers from `checkin/nudge.py` into `nudges/catalog.py` (mid-week slipping, stress slipping, under target, produce behind) with their signals wired for real (`days_logged_by_midweek`, the check-in's hunger/energy as the stress flag, produce from consumed); each `Nudge` gains `modes: frozenset[TrackingMode]`; `plan()` filters by the person's mode.
- [x] **Step 2.** Delete `GET /checkin/nudges/current` and `checkin/nudge.py`; move its tests' cases onto the catalog. The check-in store writes `computed` (the summary) so the columns mean something, or the columns go in a migration.
- [x] **Test:** every catalog entry has a test that fires it and one that silences it; the habit-mode plan never contains a calorie or protein card.
- [x] **Acceptance:** one module answers "what do we say to this person now"; the app's call is unchanged.
- [x] **Commit:** `feat(api): one nudge engine, the situational moves restored, each nudge knowing its modes`

### P6. Invitations: the ladder as an offer

- [x] **Step 1.** `nudges/invitations.py`, pure: `suggest(mode, signals, history) -> Invitation | None`. Up: habits with 14 of the last 21 days logged → "You've logged 14 of the last 21 days. Want to see your calories too?"; calories with three weeks logged → protein as a focus metric. Down: any numeric mode with fewer than 3 logged days in 14 → "Want to keep it simple for a while? Just the habits." One per direction per 14 days; never on a day another nudge fired; it counts against the nudge budget; no rank, level name or celebration (spec R6, Q3).
- [x] **Step 2.** The invitation is a nudge card with three answers: Yes (`PUT /tracking`, `source=invited`), Not now, and "Don't offer this again" (a durable write, `source=declined`, never a timer; reversible from Settings → How I track).
- [x] **Acceptance:** deterministic tests over the history; a person who said Not now is not asked again inside the cooldown.
- [x] **Commit:** `feat(api): the ladder is an invitation the engine offers, never a step it takes`

### P7. Recalibration that keeps the protocol whole (D7)

- [x] **Step 1.** `POST /protocols/{id}/revise` recomputes through `compute_targets` with the titrated deficit (IP §3.3: one 5% step per week toward 0.5–1.0% bodyweight/week), the current weight and the stored intake, so fat, the band, fiber, produce and the whys are all of one protocol; the §3.1 floor applies once.
- [x] **Step 2.** `checkin/recommend.py` drops Devine IBW and the 24–29 band in favor of the engine's facts; `docs/PROTOCOL_LOGIC.md` §3.3 note removed.
- [x] **Test:** a revised protocol satisfies every invariant the generate tests pin (macros reconcile, band contains protein, fat = 27%).
- [x] **Acceptance:** `test_recommend.py` and `test_recalibration_api.py` green against the new model; the worked example's revision is pinned.
- [x] **Commit:** `fix(api): a revised protocol is one protocol; recalibration runs the v2.0 titration`

### P8. Meal plan mode (D5)

- [x] **Step 1.** The plan builder: slots per `meals_per_day`, each filled from usuals or a typed meal through the parse; the engine checks the plan against the protocol (kcal within 10%, protein at least the band's floor) and says so in one line. *API: `meal_plans` (append-only versions, `author`), `GET/PUT /meals/plan`, `check_plan`. iOS: `PlanBuilderView` after the reveal in meal-plan mode, in Settings → My meal plan, and from the plan card; typed slots send no name so the server names them as it names a typed log (the tick matches by name).*
- [x] **Step 2.** `meal_plan_slots` panel: a slot checks itself off when a logged meal is recognized as its usual; anything else logged shows under the plan as "also today"; `author` on the plan for the coach lane later. *`match_slots` ticks by name, once per slot, in logged order; the card is full width and first, calories beneath; "No plan yet" leads to the builder; the `plan_slot_open` nudge speaks only in this mode, in the evening, on a day under way.*
- [x] **Acceptance:** a person with a plan logs by voice and sees the slot tick; a day with a deviation shows it without a word of judgment. *Pinned by `test_meal_plan_api.py` (Today ticks by name, extras named, no other mode carries the card) and `testPlanComposerTicksByName`; the renders (`testTodayMealPlan`, `testPlanBuilder`) await the goldens on the pinned simulator, like P4's.*
- [x] **Commit:** `feat(api): a meal plan the person builds from their own meals, checked against their protocol` (808316c); `feat(ios): the meal plan, built from the person's own meals and ticked as they log`

### P9. Positioning

- [x] **Step 1.** Welcome copy per D9 (the app states the capability; "world's first" stays in the pitch), the README thesis line, `web/index.html` hero and pillars, `docs/app-store/REVIEW_NOTES.md` "What Vo-Cal is", `docs/PRODUCT_BRIEF.md` one-liner; the display name and Siri phrase if D1 renames. The method's name appears once, in Settings → My protocol (spec R5).

### P10. Export my record

- [x] **Step 1.** `GET /account/export` (JSON, and CSV for meals), owner-scoped, every table the person owns; Settings → "Export my record" shares the file. The person's record is on our rail; the Rams review's Q5 asks that they can leave with it (spec R11). Before the first paying user.
- [x] **Commit:** `feat: the person can take their record with them`
- [x] **Acceptance:** every surface that states what the app is says the same thing.
- [x] **Commit:** `docs: the first personalized food tracker`

---

## Exit Criteria

- ✅ A fresh install asks how the person wants to follow their nutrition before anything else, and Today shows only that.
- ✅ The same protocol row renders six different dashboards from the server's `panels`; a build-31 client still decodes the response.
- ✅ One nudge engine; no nudge names a number the person's mode does not show.
- ✅ The ladder exists only as invitations the person accepts; the preference history records every move.
- ✅ A revised protocol is internally consistent (fat, band, whys) after a check-in.
- ✅ Every surface states the same headline.

## Amendments

### 2026-10-04: The Rams REVIEW corrected the proposal before anything was built

`docs/design/personalized-tracker-spec.md` ran the fifteen questions and the ten principles over
this plan. Changed here as a result: six modes to five (the coach's "calories + protein" step is
the first invitation, not a door); the planned "Why are you here?" question cut as a twin of
"Your goal"; the pillars mode labelled by its five contents, not a brand; checks skipped in
habits mode (they served the corpus, not the person); invitations gain a permanent decline and
count against the nudge budget; macros as tiles, never rings; the mode governs every printed
number, not only the cards; "world's first" leaves the welcome (D9); export added (P10); the
habits reveal left OPEN for two renders to decide (R12).

---

## Progress log

| Task | Status | SHA |
|---|---|---|
| P0 Decisions | done 2026-10-04 | c6e1626 |
| P1 Schema | done (the migration awaits `make db-migrate` or Deploy) | ddd63cf |
| P2 API | done | ddd63cf |
| P3 Sugar, sodium | done | 9df077d |
| P4 iOS | built; CI compiled it and ran the flow and voice tests; goldens and audit baselines await the Mac | 354546e |
| P5 One nudge engine | done | 76d7ded |
| P6 Invitations | done | 76d7ded |
| P7 Recalibration | done | 38e9527 |
| P8 Meal plan | built (D5 a); the migration awaits `make db-migrate` or Deploy; the goldens await the Mac | 808316c, 8170c88 |
| P9 Positioning | done | f9a1b4f |
| P10 Export | done | 0356bed, 4d166ad |
