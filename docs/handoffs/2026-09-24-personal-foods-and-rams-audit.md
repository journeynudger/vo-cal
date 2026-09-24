# Handoff: personal foods and the Rams audit, 2026-09-24

Read the permanent documents first: `AGENTS.md`, `docs/CAPTURE_LIFECYCLE.md` (section 5 now
names the person's own foods), `docs/PARSER_CONTRACT.md` (the "Personal foods" section),
`docs/restructure/06-rams-audit.md` (the audit, its findings and the three open decisions),
then `git log` from `2c64b52`.

## Where the tree is

- Branch `main`, commits from `f62ba45` (personal foods, API) to the ship of this pass; the
  tree is clean after the ship commit.
- Shipped with this pass: the API (Deploy applies `supabase/migrations/20260924000001_personal_foods.sql`
  through `supabase db push` before `fly deploy`; the authed smoke runs after) and TestFlight
  build 28 (the label sheet, the recipe sheet, My foods, the honest onboarding, the copy).

## What this pass added

- Server: the `foods` domain (`services/api/src/api/foods/`): label and batch foods, versioned
  rows, `PersonalFoodIndex` consulted by the resolver before every database, the additive
  `personal_food_id` on parse items.
- App: `LabelFoodSheet` (from an item's edit sheet), `BatchFoodSheet` (under the result, with
  "Log one serving now"), `PersonalFoodsView` (Settings > My foods), the "One of your foods"
  and "Counted as" card lines, `PersonalFoodsService` (live and mock).
- Copy: no fabricated statistics in onboarding, no streaks, "Working out the numbers".

## Verification owed after each step, if resumed

`scripts/check-api` (780), `swift test` (67), `bin/ios-app-build` (zero warnings),
`bin/ios-sim-voice-test` (12/12); on the live API after a deploy, one label food saved and
spoken by name (`POST /foods/personal`, then `POST /parse` with the name) proves the index
on real PostgREST; the deploy smoke does not yet do this (questions ledger).

## Open, in the owner's order

The three Rams decisions (questions ledger 9 to 11: the Today badge, the "100%" wording,
photo as an attachment), branch protection (4), the Fly organizations (6), the landing page
(8). Then the nutritionist's remaining wish: speaking a label's numbers end to end without
the sheet, which needs a contract change to the parser (declared nutrition on a parsed
item) and is not started.

## Restore

`git checkout 2c64b52` restores the tree to before this pass. It does not undo the deploy,
the migration (the `personal_foods` table stays; it is additive), TestFlight build 28, or
rows written to `personal_foods`.
