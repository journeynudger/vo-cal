# Phase V — The plan built for you, and what to add without numbers

> Status: Active
> Owner: @lorenzo
> Branch: release/build-32
> Next: V4

## Goal

Two requests from the 2026-10-12 conversation with Francesco
(`docs/conversations/2026-10-12-lorenzo-francesco.md`, C-12 and C-09), which Lorenzo asked to
ship in TestFlight build 32 before it is archived.

**C-12, the meal plan generator.** Francesco's three steps: how do you want your day to look
(meals, snacks between them, a dessert after dinner); what foods should it include (typed, chosen
from what the person already eats, or read off a grocery receipt); may it add foods you didn't
name. Then the plan. Today the person writes the plan and the engine only checks it
(decision 65); this phase lets the engine draft it, inside the rule that has always held: the
model reads, deterministic code calculates (AGENTS.md #6).

**C-09, guidance without numbers.** For a person who chose no numbers, "recommendations based off
what you're eating, with you blind to the numbers. Let us do the work for you." One line, chosen
by code from the person's last week against the protocol the engine computes for everyone,
naming foods they already eat where it can.

Surface: `services/api/src/api/meals/{generator,guidance,receipt}.py`, `meals/router.py`,
`meals/today.py`, `checkin/router.py`; `apps/ios/VoCal/Views/MealPlan/`, `Views/Today/`,
`Services/`.

## Decisions locked

- **73. The engine may draft a meal plan from the person's day and foods (D5 b, amending 65;
  Lorenzo 2026-10-12).** The model's only part is reading a grocery receipt photo into food
  names; it never sees a target or writes a number. Deterministic code (`meals/generator.py`)
  sorts the foods into roles by their per-100 g macros and the dictionary's produce credit,
  places them into the slots of the day the person described, and sizes every portion so the
  draft lands on the protocol: calories within 5 percent where the foods allow (the check
  accepts 10), protein at the band's floor, fat at its share, produce toward its count. It adds
  a food the person did not name only when they allowed it, and says which. The draft opens in
  the builder, priced on the one confirm path; nothing is stored until the person saves it, and
  the saved plan's author stays `person` (no schema change). A plan the foods cannot make land
  is still drafted, and the check line says how far off it is.
- **74. Numbers-free guidance: one thing to add (2026-10-12).** Habits mode only. From the last
  seven days (at least three logged), against the protocol computed for everyone, the first gap
  in this order: protein under 80 percent of the band's floor, produce under 70 percent of its
  count, fat under 75 percent of its target (Francesco: low fat dysregulates hormones), fiber
  under 70 percent of its target. One catalog sentence, no number in it, naming up to two
  foods of the right kind from the person's own last 90 days, or the catalog's examples when
  they have none. Shown on Today under the tiles unless the person said "Nothing. I'll check in
  myself.", and as the weekly check-in's hold. Absent when nothing is short: no card says
  "all good" (no grade, decision 69).

## Context

Decision 65's reasoning stays true for everything this phase does not touch: a plan is the
person's own food, checked by the engine. The generator drafts from the foods the person names,
and the person edits and saves. Decision 72 (numbers-blind) is unaffected: meal-plan mode prints
numbers; habits mode never sees the generator's numbers.

---

## Tasks

### V0. The plan and the decisions

- [x] **Step 1.** This file; decisions 73 and 74 in `.claude/memory/decisions.md`; the master
  plan's phase row and amendment entry.

### V1. The generator, pure (`meals/generator.py`)

- [x] **Step 1.** Roles from macros and the dictionary: dessert (by name), fat (60 percent of
  energy or more from fat), fruit and vegetable (produce credit), protein (35 percent of energy
  from protein and at least 8 g per 100 g), starch (50 percent from carbs), dish (the rest).
- [x] **Step 2.** The day: meal names by count (2: Lunch, Dinner; 3: Breakfast, Lunch, Dinner;
  4 and 5 add an afternoon and a late-morning meal), snacks after the first meals, dessert
  last; at most 8 slots.
- [x] **Step 3.** Calories split (snacks and dessert small and capped, meals equal); per meal a
  protein, a vegetable (lunch and dinner) or fruit (breakfast), a starch, and fat where the day
  needs it; portions solved per meal, then balanced for the day (protein to the floor, fat to
  its share, starch to the calories), rounded to 5 g or whole pieces.
- [x] **Step 4.** Additions only when allowed, from a curated staples list that the dictionary
  prices.
- [x] **Test:** roles; the day's shape; landing on a protocol with ample foods; protein short
  with and without additions; no starch; dessert with and without one named; nothing named
  plus additions builds a day from staples; nothing named without additions is refused.

### V2. The endpoints

- [x] **Step 1.** `POST /meals/plan/generate` (the draft, priced on the confirm path, checked),
  `GET /meals/plan/foods` (the person's most-logged foods, 90 days), `POST /meals/plan/receipt`
  (a receipt photo to food names; the photo is not stored; a recorded fake offline).
- [x] **Test:** each endpoint, owner-scoped; the draft is never stored; the receipt refuses a
  non-image and returns names only.

### V3. Guidance (`meals/guidance.py`)

- [x] **Step 1.** The pure choice and its catalog; `TodayResponse.guidance` (additive) in habits
  mode, honoring the nudge level; the numbers-free check-in hold carries it.
- [x] **Test:** each gap; the order; too few days; nothing short; no digit in any line; foods
  named from the person's history; the Today field and the check-in.

### V4. iOS: the generator

- [ ] **Step 1.** `PlanGeneratorView`: the three steps in Francesco's words, the receipt from
  the camera or the library, the draft applied to the builder, the added foods named.
- [ ] **Step 2.** The entry in the builder ("Build it for me"), the service methods, the mocks.

### V5. iOS: guidance on Today

- [ ] **Step 1.** The card under the habits tiles; the model decodes `guidance` tolerantly; the
  mock's habits day carries one.

### V6. Verification and the record

- [ ] **Step 1.** `scripts/check-api`, `bin/ios-app-build`, the render loop (renders read),
  the change list in the conversation doc updated.
