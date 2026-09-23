# Voice-accuracy handoff (2026-09-23)

> Written by a Fable 5.1 session after a full survey of the nutrition pipeline. Purpose: a
> fresh session picks this up cold and makes voice logging PREDICTABLE and CONSISTENT
> enough that Lorenzo and Francesco trust it as a source of truth. Nothing here has been
> implemented yet; every finding below is grounded in code read on `main` at `a90a966`.

## 0. Where the repo is

- `main` = `a90a966` (build 25 on TestFlight; backend live on Fly, prod migrations applied
  by `.github/workflows/deploy.yml`, trigger with `gh workflow run Deploy --ref main`).
- Verification tiers: `scripts/check-api` (ruff + pytest, ~3s, 677+ tests), `scripts/check`
  (adds SPM), `scripts/parser-eval` (offline extraction corpus, writes SCORES.md, regression
  gate), `bin/ios-app-build` (zero-warnings bar), `scripts/calorie-eval` (LIVE pricing
  corpus, needs keys - see §2).
- TestFlight: `.claude/skills/publish` is the only lane. Use the App Store Connect API key
  flags (`-authenticationKeyPath /Users/lorenzo/Downloads/AuthKey_5NM2XND9DL.p8
  -authenticationKeyID 5NM2XND9DL -authenticationKeyIssuerID
  cc603e50-ffb0-4af6-b337-5038f009f692`), never Xcode's signed-in account (it fails).
  Use ABSOLUTE paths for archive/export/plist; the shell cwd drifts between calls.
- Rules that bind: `AGENTS.md` (no DB migrations, no push without approval, LLM extracts /
  deterministic code calculates, facts-first UI claims). No em dashes in any user-facing
  copy (Lorenzo rule; product-wide sweep already done).

## 1. The problem, in the user's words

Lorenzo (2026-09-23): voice tracking is "hit or miss". Sometimes everything is on point,
other times everything is wrong. Concrete incidents:

1. Said "200 g cosmic crisp apple" -> came out "incredibly low calories". Changed unit to
   grams and typed 200 manually -> apple came out ~350 kcal (truth is ~110-120 kcal).
2. A bread he had tracked successfully by voice before would not track, and manual
   unit/amount edits could not make it make sense. (Which bread: ASK HIM - likely a
   branded loaf such as Dave's Killer Bread / Ezekiel.)
3. Pre-made products (yogurts, smoothies) rarely land on the first try; he deletes and
   rephrases until they do.

He will not push the app to more users until these basics are consistent. Francesco
(the coach) does not trust it either. Success = the SAME food said any reasonable way
prices the same, sane number, and a manual amount edit never changes WHAT food is priced.

## 2. What the pipeline actually does (read these files first)

```
transcript -> parser/llm.py (Claude, forced tool; prompts.py PROMPT_VERSION 2026-08-20.8)
          -> ParsedItem{name, amount, unit, state, fat_ratio, brand, ...}
          -> nutrition/resolver.py Resolver._resolve_uncached   (THE LADDER, below)
          -> per-item grams + macros -> confidence/certainty/clarify -> parses row
/parse/refine (manual edits, chips) re-runs the SAME ladder on the edited ParsedItem.
/meals confirm (_reresolve in meals/router.py) re-runs the SAME ladder again at store time.
```

The ladder (`services/api/src/api/nutrition/resolver.py::_resolve_uncached`):

1. `brand` set -> `dictionary.lookup_branded` (accepts only entries that name the brand,
   e.g. Fairlife) else **AI estimator first** (`estimator.py`, haiku + web search on
   aggregator domains, fallback sonnet knowledge; cached forever in `usda_cache` under
   `est:<brand variant prep ratio name>`).
2. Exact dictionary hit (canonical/alias, `include_suffix=False`).
3. If amount is a MASS (g/oz/lb/ml): **USDA FDC search first** (`fdc_client.py`; POST
   /foods/search with dataType Foundation+SR+Survey+**Branded**, top hit by tier, gated only
   by `_fdc_profile_plausible`), then suffix rescue, then estimator.
   If amount is NOT a mass (count/serving/null): suffix rescue first, then estimator, never
   FDC.
4. Suffix rescue = longest token-suffix that is a curated name ("cosmic crisp apple" ->
   "apple"), `MatchKind.SUFFIX`, with prefix->variant pinning.
5. Unresolved (0 kcal + question).

### The offline proof (run 2026-09-23, dictionary only: no FDC, no estimator)

| phrasing (as ParsedItem) | result |
|---|---|
| "cosmic crisp apple", 200 g, no brand | dictionary/suffix, 200 g, **104 kcal (correct)** |
| "cosmic crisp apple", no amount | 182 g, 95 kcal (correct) |
| "apple", no amount, brand "Cosmic Crisp" | canonical apple, 95 kcal |
| "honeycrisp apple", 1 piece | 182 g, 95 kcal |
| "dave's killer bread", 2 slices (brand or not) | suffix -> white bread, 56 g, 149 kcal (sane; DKB is ~230) |
| "strawberry greek yogurt", brand Chobani | suffix -> greek yogurt, flavored variant pinned, 170 kcal (sane) |
| "sourdough toast", 2 slices | suffix -> white bread 149 kcal (should be sourdough 208; alias gap) |
| "green machine smoothie", brand Naked | **unresolved** (no smoothie head in seed) |

Reproduce with:
```bash
cd services/api && uv run python - <<'PY'
import asyncio
from api.parser.schemas import ParsedItem, Unit, State
from api.nutrition.resolver import Resolver
r = Resolver()  # dictionary only
it = ParsedItem(name="cosmic crisp apple", amount=200, unit=Unit.G, state=State.UNSPECIFIED,
                fat_ratio=None, brand=None, prep_method=None, confidence=0.9)
print(asyncio.run(r.resolve_item(it)))
PY
```

**Conclusion: the curated, deterministic path already answers Lorenzo's cases correctly.
The wrong numbers come from the two LIVE sources that are ordered ahead of it - FDC search
for stated masses and the AI estimator for branded/unknown items - and from the fact that
the ladder's branch depends on the amount's unit.**

## 3. Root causes (ranked; each is a CLASS, not the incident)

### RC1. Identity and quantity are conflated in one ladder
`fdc_can_price = amount is not None and unit in MASS_UNITS` decides which SOURCE identifies
the food. So "cosmic crisp apple" said with no amount goes suffix->apple (right), but said
with "200 g" goes FDC-first (whatever FDC's fuzzy top hit is). And a manual edit from a count
to "200 g" (via /parse/refine -> same ladder) can switch the identified food. This is the
most likely mechanism behind "low calories, then 350 after editing to 200 g": two different
identities priced for the same words. Fix: resolve IDENTITY once (per-100g profile +
serving/unit conversions + source), persist it on the parse item, and let refine/confirm
only RE-PRICE. Editing amount/unit must never re-identify.

### RC2. FDC is trusted too easily
- `fdc_client._search` includes Branded rows; `_rank_search_hits` merely prefers
  Foundation/SR, so a brand-less generic can price off a random label row.
- No relevance check: the chosen description is never compared to the query. "cosmic crisp
  apple" can return anything FDC's full-text ranks first.
- `_fdc_profile_plausible` accepts any row with Atwater <= 20 and kcal <= 250 (a junk row
  with 5 kcal and 1 g carbs passes) and anything internally consistent. No category sanity.
- The query is the raw item name (descriptors included), never the curated head.

### RC3. The AI estimator is validated for self-consistency, not sanity, and cached by phrasing
- `validate_estimate` checks Atwater and serving-basis identity only. A haiku read of a
  per-ounce or per-serving table that is internally consistent passes (e.g. 13 kcal/100 g
  apple). No category band.
- `estimate_cache_key` = normalized `brand variant prep ratio name`: "chobani strawberry
  greek yogurt", "strawberry chobani yogurt", "chobani greek yogurt strawberry" are three
  independent web searches, each frozen forever on first answer. This is exactly the
  "delete and rephrase until it works" experience.
- Branded grocery items whose HEAD is curated (yogurt, milk, bread, creamer) still go
  estimator-first (the 2026-07 Chobani protein-drink decision), so a nondeterministic web
  read outranks a deterministic curated match every time.

### RC4. Seed gaps for high-frequency heads
No `smoothie` entries at all (Naked, Bolthouse, Oikos smoothies -> estimator or
unresolved). Cultivars/descriptors are not aliases (they only work via suffix rescue, which
RC1 bypasses for masses). "sourdough toast" lands on white bread.

### RC5. No way to correct IDENTITY pre-log
`MealItemEditSheet` edits amount/unit/fat ratio/state only, never the name; the only
identity fix is re-recording (or post-log manual macros in `LoggedMealEditView`).

## 4. The plan (do in this order; each step has its own tests)

### P0. Reproduce live (needs Lorenzo)
- No `.env` exists on this Mac and no keys are in the shell env. Ask Lorenzo to create
  repo-root `.env` (see `.env.example`) with `ANTHROPIC_API_KEY` and `USDA_FDC_API_KEY`
  (Supabase can stay blank; `FORCE_OFFLINE=true` runs the in-memory DB).
- Start: `cd services/api && FORCE_OFFLINE=true DEV_ENDPOINTS=true DEBUG=true
  TEST_MODE=false uv run uvicorn api.main:app --port 8001`; check
  `curl :8001/__dev/preflight` (parse provider must NOT be the fake).
- Run `scripts/calorie-eval` (57 cases) to get the baseline, then post Lorenzo's phrasings
  through `POST /__dev/capture {"text": ...}` and record per-item source/grams/kcal:
  "200 g cosmic crisp apple", "a cosmic crisp apple", "cosmic crisp apple 200 grams",
  "two slices of sourdough toast", "2 slices of Dave's Killer Bread", "a Chobani strawberry
  greek yogurt", "an Oikos triple zero vanilla yogurt", "a Naked green machine smoothie",
  "a Bolthouse strawberry banana smoothie". Then edit the apple to 200 g via /parse/refine
  (`items[0].amount` = "200 g") and confirm whether the SOURCE changes (RC1 proof).
- Optional, strongest evidence: Lorenzo's real `parses` rows in prod Supabase are the
  immutable audit trail (payload.result.items[].source/grams/macros). Ask him to run the
  query himself or paste the rows; do not ask for the service-role key in chat.

### P1. Separate identity from pricing (the architectural fix, RC1)
- In `resolver.py`: `resolve_identity(item) -> FoodIdentity{per_100g, serving_grams,
  unit_conversions, basis_state, raw_cooked_factor, source, match_kind, match_score,
  variant axis, sources, identity_key}` and `price(identity, item) -> grams + macros`.
  Identity must not read `item.amount`/`item.unit` at all.
- Persist identity on `ParseResultItem` (new optional fields; Swift mirror
  `Sources/VoCalCore/ParserContract.swift` must add them as OPTIONAL, see the
  `is_estimate` gotcha in `services/api/AGENTS.md`). `/parse/refine` and meals `_reresolve`
  reuse the stored identity when name/brand/variant/fat_ratio are unchanged and only
  re-price; they re-identify only when identity fields changed.
- Tests: editing "1 piece" -> "200 g" keeps the same source/per-100g; confirm-time totals
  equal preview totals for the same items (there is an existing regression class here, see
  `_reresolve` docstring about 827 vs 377 kcal).

### P2. Deterministic-first identity (RC2, RC4)
- Run the curated lookup INCLUDING suffix rescue before FDC and before the estimator for
  every amount kind. Keep the "50 g bison bacon" case by letting FDC override a SUFFIX hit
  only when FDC's top Foundation/SR row description contains every prefix token
  (`bison`); otherwise the curated head wins.
- Brand-less items never price from Branded FDC rows (drop "Branded" from the search
  dataType when `item.brand` is None). Add a relevance gate: the chosen description must
  share the head noun with the query. Strengthen `_fdc_profile_plausible` with a sanity
  band against the curated head when a suffix head exists (e.g. 0.4x..2.5x kcal/100 g).
- Seed: add cultivar/descriptor aliases (cosmic crisp/honeycrisp/gala/fuji/granny smith/
  pink lady apple; roma/cherry/grape tomato; russet/yukon potato; cavendish banana; "sourdough
  toast" -> sourdough), a smoothie family (fruit/green/protein smoothie, ml density, 12/15.2
  oz bottle conversions), and any heads the P0 run shows missing. Extend
  `produce_servings_for` coverage accordingly.

### P3. Estimator consistency (RC3)
- Category sanity band: when the item has a curated suffix head, an estimate whose
  kcal/100 g falls outside the head's band is DECLINED (falls to the curated head with the
  variant chip). Log decline reasons with `food_ref` (never names).
- Normalize `estimate_cache_key` to a sorted token set of brand + name with descriptor
  stopwords removed (sizes, "the", packaging words), so phrasings share one cached answer.
- Branded grocery items with a curated head: price the curated head deterministically and
  only upgrade to the estimator's label read when it has web SOURCES and passes the band.
  Restaurant/menu items (brand in `nutrition/sources.py::RESTAURANT_DOMAINS`) keep AI-first.
- Bump `ESTIMATOR_VERSION` so poisoned cache rows re-estimate.

### P4. Prove it: evals
- `tests/fixtures/calorie_corpus.json`: add the P0 phrasings with honest bands (200 g
  cosmic crisp apple [95,135]; a honeycrisp apple [70,130]; 2 slices Dave's Killer Bread
  [200,300]; Oikos triple zero [90,130]; Naked green machine 15.2 oz [250,300]; sourdough
  toast x2 [180,260]).
- NEW `tests/consistency_eval.py` + `scripts/consistency-eval`: groups of phrasings for
  the same food must land within +/-15% of each other AND inside the band. Groups: apple
  x4 phrasings, chobani yogurt x3, DKB bread x3, fairlife milk x3, green machine x3.
- `scripts/parser-eval` must not regress (SCORES.md canonical-four 100%).
- Unit tests for every new gate (resolver/fdc/estimator/dictionary suites already exist:
  `tests/test_resolver.py`, `test_fdc_client.py`, `test_estimator.py`, `test_dictionary.py`).

### P5. iOS (small, only what accuracy needs)
- Add a name field to `MealItemEditSheet` (send `items[i].name` as a refine answer; the
  server's `ClarifyEngine._apply` needs a `name` branch that re-identifies). This is the
  pre-log identity fix that currently does not exist (RC5).
- Surface the source honestly on the item card (dictionary vs USDA vs estimate with
  sources) - most of this exists (`is_estimate`, `sources`); make sure a suffix/head match
  says what it matched ("priced as: apple").

### P6. Ship
`scripts/check` green, `scripts/parser-eval` no regression, `scripts/calorie-eval` all
pass, `scripts/consistency-eval` all pass, `bin/ios-app-build` zero warnings, simulator
smoke of the edit flow. Then merge to `main`, push (Lorenzo approves pushes for this
work), `gh workflow run Deploy --ref main` and watch it, then the publish lane for
TestFlight with the API-key flags. Commit messages: Conventional Commits with the trailer
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## 5. File map (start here)

- `services/api/src/api/nutrition/resolver.py` - the ladder (`_resolve_uncached`, `to_grams`,
  `_fdc_profile_plausible`, `_estimate`)
- `services/api/src/api/nutrition/dictionary.py` - lookup, suffix rescue, `lookup_branded`,
  `_variant_from_prefix`; seed in `dictionary_seed.json` (188 entries)
- `services/api/src/api/nutrition/fdc_client.py` - search (Branded included), cache, mapping
- `services/api/src/api/nutrition/estimator.py` - grounded haiku + knowledge sonnet,
  `validate_estimate`, `estimate_cache_key`, `CachedEstimator`, `ESTIMATOR_VERSION`
- `services/api/src/api/nutrition/build.py` - single Resolver construction site
- `services/api/src/api/parser/router.py` - `/parse`, `/parse/refine`,
  `resolve_with_composition`; `parser/clarify.py::_apply` + `_parse_amount_answer` (manual
  edits: `^([\d.]+)\s*([a-z]*)$`, aliases grams/ounces/cups)
- `services/api/src/api/meals/router.py::_reresolve` - confirm-time re-resolution
- `services/api/tests/calorie_eval.py` + `fixtures/calorie_corpus.json` (57 cases);
  `tests/parser_eval.py` + `fixtures/transcripts.yaml` (44 fixtures)
- `docs/PARSER_CONTRACT.md`, `services/api/AGENTS.md`, `services/api/src/api/parser/AGENTS.md`
- `.claude/plans/parser-accuracy-2026-08-20.md` - the previous accuracy batch (brand lines,
  suffix rescue); its FDC-first-for-masses ordering is what P2 revisits.
- iOS: `apps/ios/VoCal/Views/VoiceLog/MealItemEditSheet.swift` (no name field),
  `ViewModels/VoiceLogViewModel.swift::applyEdits`, `Views/Today/LoggedMealEditView.swift`
  (post-log manual macros, `manual: true`)

## 6. Questions for Lorenzo (ask up front, in one message)
1. Put `ANTHROPIC_API_KEY` and `USDA_FDC_API_KEY` in repo-root `.env` (never paste keys in
   chat).
2. Which bread was it (brand and how you said it)? Which yogurt and smoothie products?
3. Roughly when (date/time) did the apple attempt happen, so the `parses` rows can be found?
