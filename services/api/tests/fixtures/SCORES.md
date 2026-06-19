# Parser corpus SCORES

> Binding regression net (decision #22): a SCORES regression does not merge.
> **Mode: recorded-fixture (offline).** The LLM is `FakeParserClient` serving
> golden tool outputs from `tests/fixtures/llm_responses/`. A live-model
> baseline (Sonnet 4.6 vs Haiku 4.5) is a TODO blocked on `ANTHROPIC_API_KEY`
> — run `uv run pytest -m live_llm` once a key is set, then record both here.
> Resolution is dictionary-only; FDC long-tail accuracy is covered by
> `tests/test_resolver.py::test_fdc_fallback_resolves_long_tail`.

## Aggregate

| Metric | Value |
|---|---|
| Fixtures | 34 |
| Item-extraction precision | 1.000 |
| Item-extraction recall | 1.000 |
| Item-extraction F1 | 1.000 |
| Field accuracy (all) | 1.000 |
| Field accuracy (canonical four) | 1.000 |
| Question precision | 0.500 |
| Question recall | 1.000 |
| Latency p50 | 0.0 ms |
| Latency p95 | 0.1 ms |

## Per-fixture

| id | canonical | count ok | names tp/exp | fields | expect Q | got Q | err |
|---|---|---|---|---|---|---|---|
| canonical_beef | ✓ | ✓ | 1/1 | 4/4 | n | n |  |
| canonical_burger | ✓ | ✓ | 4/4 | 1/1 | Y | Y |  |
| canonical_chipotle | ✓ | ✓ | 5/5 | 7/7 | n | n |  |
| canonical_rice | ✓ | ✓ | 1/1 | 3/3 | n | n |  |
| ambiguous_bowl_of_rice |  | ✓ | 1/1 | 1/1 | Y | Y |  |
| ambiguous_pasta |  | ✓ | 1/1 | 1/1 | Y | Y |  |
| ambiguous_some_chicken |  | ✓ | 2/2 | 2/2 | Y | Y |  |
| brand_chobani |  | ✓ | 1/1 | 1/1 | n | n |  |
| brand_quest_bar |  | ✓ | 1/1 | 3/3 | n | n |  |
| filler_breakfast_oatmeal |  | ✓ | 2/2 | 5/5 | n | n |  |
| filler_eggs_toast |  | ✓ | 2/2 | 2/2 | n | n |  |
| filler_snack_almonds |  | ✓ | 1/1 | 1/1 | n | n |  |
| mealtype_dinner_fish |  | ✓ | 2/2 | 5/5 | n | n |  |
| mealtype_lunch |  | ✓ | 2/2 | 2/2 | n | n |  |
| mixed_milk_cereal |  | ✓ | 2/2 | 4/4 | n | Y |  |
| mixed_units_meal |  | ✓ | 2/2 | 4/4 | n | n |  |
| modifier_double_protein |  | ✓ | 1/1 | 2/2 | n | n |  |
| modifier_extra_cheese_light_dressing |  | ✓ | 3/3 | 2/2 | n | Y |  |
| modifier_half_bagel |  | ✓ | 2/2 | 1/1 | n | n |  |
| no_question_egg_count |  | ✓ | 2/2 | 2/2 | n | n |  |
| no_question_low_impact |  | ✓ | 2/2 | 2/2 | n | Y |  |
| question_unknown_burger_ratio |  | ✓ | 3/3 | 1/1 | Y | Y |  |
| question_unknown_oil_amount |  | ✓ | 2/2 | 2/2 | Y | Y |  |
| runon_big_dinner |  | ✓ | 3/3 | 6/6 | n | n |  |
| runon_breakfast_stack |  | ✓ | 3/3 | 6/6 | n | n |  |
| runon_no_punctuation |  | ✓ | 3/3 | 4/4 | n | n |  |
| runon_taco_night |  | ✓ | 5/5 | 3/3 | n | Y |  |
| spoken_eighty_twenty |  | ✓ | 1/1 | 3/3 | n | n |  |
| spoken_four_ounces |  | ✓ | 1/1 | 2/2 | n | n |  |
| spoken_ninety_three_seven |  | ✓ | 1/1 | 3/3 | n | Y |  |
| spoken_two_hundred_grams |  | ✓ | 1/1 | 3/3 | n | n |  |
| state_cooked_pasta |  | ✓ | 1/1 | 3/3 | n | n |  |
| state_raw_beef |  | ✓ | 1/1 | 4/4 | n | n |  |
| state_unspecified_steak |  | ✓ | 1/1 | 3/3 | n | Y |  |
