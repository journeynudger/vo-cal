"""The parser-eval gate must fail on ANY regression from the committed SCORES.md.

Incident (restructure Phase 0.4, 2026-09-23): a canonical fixture's expected name was
regressed in a throwaway worktree and `scripts/parser-eval` still printed PASS, because
its only gate was a fixed F1 floor of 0.90 (four fixtures of headroom on a 45-fixture
corpus) and the canonical check ignored names. The committed SCORES.md is the baseline;
these tests pin the ratchet that compares against it.
"""

from __future__ import annotations

from tests.parser_eval import parse_scores_baseline, regressions

_SCORES = """
## Aggregate

| Metric | Value |
|---|---|
| Fixtures | 45 |
| Item-extraction precision | 1.000 |
| Item-extraction recall | 1.000 |
| Item-extraction F1 | 1.000 |
| Field accuracy (all) | 1.000 |
| Field accuracy (canonical four) | 1.000 |
| Question precision | 0.667 |
| Question recall | 1.000 |
| Latency p50 | 0.1 ms |
| Latency p95 | 0.3 ms |
"""


def test_baseline_parses_the_aggregate_table():
    baseline = parse_scores_baseline(_SCORES)
    assert baseline == {
        "fixtures": 45.0,
        "extraction_f1": 1.0,
        "field_accuracy": 1.0,
        "canonical_field_accuracy": 1.0,
        "question_precision": 0.667,
        "question_recall": 1.0,
    }


def test_any_metric_moving_down_is_a_regression():
    baseline = parse_scores_baseline(_SCORES)
    same = dict(baseline)
    assert regressions(baseline, same) == []
    fewer_fixtures = dict(baseline, fixtures=44.0)
    assert any("fixtures" in r for r in regressions(baseline, fewer_fixtures))
    one_name_missed = dict(baseline, extraction_f1=0.978)  # inside the old 0.90 floor
    assert any("extraction_f1" in r for r in regressions(baseline, one_name_missed))
    better = dict(baseline, question_precision=0.7, fixtures=46.0)
    assert regressions(baseline, better) == []


def test_float_noise_is_not_a_regression():
    baseline = parse_scores_baseline(_SCORES)
    assert regressions(baseline, dict(baseline, extraction_f1=0.9999999)) == []


def test_missing_baseline_metric_is_not_a_regression():
    assert regressions({}, {"extraction_f1": 0.5}) == []
