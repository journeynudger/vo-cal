# Latency, measured

`scripts/latency-probe`, live providers, 2026-09-25. Three runs: before the estimator race
and prompt caching, after them, and the parse model comparison over the whole recorded corpus.

## What one spoken meal paid, before

Production (2026-09-24): transcription 2.0 s; one eight-item parse 17.5 s. The probe found
the seconds in two places: the parse call on Sonnet 4.6 (p50 3.9 s, p95 6.6 s) and the
estimator for a novel item (8.7 s for a Chipotle bowl on a cold cache), while every curated
food resolved in under 5 ms.

Before: Resolution p50 1 ms, p95 9613 ms, max 9613 ms.
After the estimator race: Resolution p50 2 ms, p95 6327 ms, max 6327 ms.

## The parse model, over the recorded corpus (47 transcripts)

| Model | p50 ms | p95 ms | Exact fixture match | Same item names | Different items |
|---|---|---|---|---|---|
| claude-sonnet-4-6 | 3196 | 5573 | 26 | 35 | 12 |
| claude-haiku-4-5 | 1405 | 2053 | 24 | 35 | 12 |

The fixtures were recorded from Sonnet, and Sonnet itself matches them exactly on only 26:
amounts and units vary from run to run on hedged speech. At the level that decides which food
is priced (the item names), the two models are equal (one disagreement each way: Haiku on
"a salad with extra cheese and light ranch", Sonnet on "a can of coke"). Haiku is the default
parser model from 2026-09-25 (`config.py parser_model`).

## The after run, per transcript



| Transcript | claude-sonnet-4-6 | claude-haiku-4-5 |
|---|---|---|
| 4oz 93/7 beef | 3426 (same) | 1136 (same) |
| 200g cooked jasmine rice | 2324 (same) | 969 (same) |
| Chipotle bowl, double chicken, white rice, mild salsa, light | 4217 (same names) | 1967 (same names) |
| burger, unknown beef, regular cheddar, mayo | 6363 (same) | 2041 (same) |
| yeah for breakfast I think I had oatmeal, maybe a cup, with  | 3292 (same) | 1542 (same) |
| logging lunch, a turkey sandwich and an apple | 2607 (same names) | 1329 (same names) |
| I had a Big Mac and a Sprite | 4050 (same) | 1676 (same) |
| for dinner I had 6oz grilled chicken breast, a cup of white  | 3392 (same names) | 1409 (same names) |

| Model | p50 | p95 | Extraction equal to the recorded fixture |
|---|---|---|---|
| claude-sonnet-4-6 | 3409 | 6363 | 5/8 |
| claude-haiku-4-5 | 1475 | 2041 | 5/8 |

## Resolution on a cold cache (the ladder with the estimator, FatSecret and USDA live)

| Transcript | Items | Wall-clock | Slowest item |
|---|---|---|---|
| 4oz 93/7 beef | 1 | 6 | ground beef (5 ms) |
| 200g cooked jasmine rice | 1 | 0 | jasmine rice (0 ms) |
| Chipotle bowl, double chicken, white rice, mild salsa, light | 5 | 6327 | mild salsa (6327 ms) |
| burger, unknown beef, regular cheddar, mayo | 4 | 1 | mayonnaise (0 ms) |
| yeah for breakfast I think I had oatmeal, maybe a cup, with  | 2 | 0 | oatmeal (0 ms) |
| logging lunch, a turkey sandwich and an apple | 2 | 0 | turkey sandwich (0 ms) |
| I had a Big Mac and a Sprite | 2 | 79 | Big Mac (79 ms) |
| for dinner I had 6oz grilled chicken breast, a cup of white  | 3 | 4 | chicken breast (0 ms) |

Resolution p50 2 ms, p95 6327 ms, max 6327 ms.

