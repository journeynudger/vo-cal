# Handoff: FatSecret and the UI verification loop (2026-09-24)

For a session with no other context. Read `AGENTS.md` first, then this.

## State of the world

- `main` carries `79e15a2` (the UI loop) and `6f0e7fd` (FatSecret ahead of the curated
  suffix head), plus the commits after them named below. The Deploy workflow on `6f0e7fd`
  succeeded end to end (gate, `supabase db push`, `fly deploy`, authed smoke). TestFlight
  build 29 goes up through the publish lane in this pass; its bump commit lands last.
- FatSecret ships OFF: `FATSECRET_ENABLED` is unset in production. The two credentials are
  staged as Fly secrets (`FATSECRET_CLIENT_ID`, `FATSECRET_CLIENT_SECRET`, released by the
  deploy). Before turning it on: (1) allow-list the production egress IP 152.236.10.30 in
  the FatSecret app (better: allocate a static egress IP on Fly and list that, finding 28);
  (2) wait until no tester runs a build before 29 (older decoders reject
  `source: "fatsecret"`); (3) `fly secrets set FATSECRET_ENABLED=true -a vo-cal`.
- The client secret was pasted into chat on 2026-09-24. Rotate it in the FatSecret console
  and update `.env` and the Fly secret; nothing in the repository holds it.

## What FatSecret changed (services/api/src/api/nutrition)

- Ladder (`resolver.py`): personal foods → exact dictionary → FatSecret → curated suffix
  head → estimator → USDA FDC → unresolved. Branded: curated brand line → FatSecret (brand
  in the query, within 2.5x of the head) → estimator → curated head → FDC branded.
- Row choice (`fatsecret_client.py`): every word said must appear (one letter of tolerance
  for long words), the row must end in the word said last or in that word plus a category
  noun ("Halloumi Cheese"), Generic before Brand for brand-less queries, then the fewest
  extra words. "2%" is a content word. Servings with a negative nutrient are skipped.
  Unweighed servings are carried as 100 g and refuse a stated mass.
- Measured: `services/api/tests/fixtures/FOOD_SOURCES.md` (`scripts/food-source-eval`;
  `--record` also refreshes the fixtures, and refuses to record a refusal).

| Source | Found | Agree with curated | Serving grams | Cups/pieces | p50 latency |
|---|---|---|---|---|---|
| FatSecret (205 answered, 5 refused) | 198 | 135 | 197 | 166 | 101 ms |
| USDA FDC (210) | 157 | 61 | 0 | 0 | 1267 ms |

- Known long-tail misses to read in that file: "oikos triple zero" (the name omits the
  category noun and the row ends in "yogurt"), "kodiak protein pancake mix", flavored
  brand rows chosen when the plain one is not in the first eight results (Chobani).
- Error 21 ("Invalid IP address detected") is per edge node and lasted over an hour after
  the IP was listed; the client retries three times, the eval counts refusals apart.

## What the UI loop is (docs/UI_VERIFICATION.md)

- `bin/ios-render-tests`: every screen and component to PNG in `/tmp/ui`, compared to the
  goldens in `apps/ios/VoCalRenderTests/__Snapshots__` (3x, sRGB, light, animations off,
  fixed dates). Record only with `RECORD_SNAPSHOTS=1` and say why. Goldens carry their
  runtime (`RUNTIME.txt`, iOS 26.5) and skip out loud elsewhere; CI runs the non-golden
  tests. Proven with three planted bugs: five goldens failed, five passed, removed, green.
- `bin/ios-ui-audit`: the real app in mock mode through Xcode's accessibility audit,
  nightly in CI, as a ratchet against the baseline committed in the test (Today: 36
  Dynamic Type, 31 contrast, 6 hit areas; the settings pages have their own rows). A count
  above its baseline fails; lower a baseline in the commit that fixes the issue. Fonts and
  contrast are decisions 12 and 13 in 05-questions.md; the hit areas are finding 29.
- `bin/png-diff a.png b.png` says where two renders differ, in points.

## Verification ladder at the end of the pass

swift test 68/68 · check-api 800 passed · parser corpus unchanged · ios-app-build zero
warnings · voice runtime 12/12 · render tests 10/10 (five verify runs, zero mismatches) ·
accessibility audit: see the inventory above.

## Next

1. Decide items 12 and 13 in `docs/restructure/05-questions.md`; fix the six hit areas
   of finding 29; lower the audit baselines and re-record the goldens on purpose.
2. Static egress IP on Fly, then the FatSecret allow list, then the flag.
3. Re-run `scripts/food-source-eval --record` once no call is refused, and commit the
   recorded search fixtures over the authored ones.
4. When the CI runner image carries the pinned iOS, goldens compare in CI without change.
