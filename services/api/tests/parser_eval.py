"""B7: parser quality harness — the binding regression net (decision #22).

Runs the whole fixture corpus through the offline pipeline
(FakeParserClient parse -> dictionary resolve -> confidence -> clarify) and
scores it: item extraction (name precision/recall/F1), stated-field accuracy,
clarifying-question precision/recall, and parse+resolve latency. Writes
tests/fixtures/SCORES.md.

Exit status is a merge gate: nonzero if any canonical-four check fails or if
overall item-extraction F1 < 0.90.

Run from the repo root: ``scripts/parser-eval``.
"""

from __future__ import annotations

import asyncio
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from api.nutrition.resolver import Resolver
from api.parser.clarify import ClarifyEngine
from api.parser.llm import FakeParserClient, ParseError, parse_transcript
from tests.corpus import CANONICAL_IDS, Fixture, load_corpus

_REPO_ROOT = Path(__file__).resolve().parents[3]
SCORES_PATH = Path(__file__).resolve().parent / "fixtures" / "SCORES.md"
# Absolute floor, kept as a last line of defense. The REAL gate is the ratchet below: the
# committed SCORES.md is the baseline and any metric moving down fails the run. Before
# 2026-09-23 this floor was the only gate, so a corpus could lose four fixtures' worth of
# extraction accuracy (F1 1.000 -> 0.91) and still print PASS; names were not part of the
# canonical-four check at all (gate-failure proof, restructure Phase 0.4).
ITEM_EXTRACTION_F1_GATE = 0.90
# Metrics the ratchet holds. Higher is better for every one. The table prints three
# decimals, so both sides are compared at that precision (0.6667 computed vs 0.667
# committed is the same number, not a regression). Fixture count may never shrink.
_RATCHETED = ("fixtures", "extraction_f1", "field_accuracy", "canonical_field_accuracy",
              "question_precision", "question_recall")
_TABLE_DECIMALS = 3
_SCORES_LABELS = {
    "Fixtures": "fixtures",
    "Item-extraction F1": "extraction_f1",
    "Field accuracy (all)": "field_accuracy",
    "Field accuracy (canonical four)": "canonical_field_accuracy",
    "Question precision": "question_precision",
    "Question recall": "question_recall",
}


def parse_scores_baseline(text: str) -> dict[str, float]:
    """The aggregate table of a SCORES.md, as {metric: value}. Missing rows are absent."""
    out: dict[str, float] = {}
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 2 or cells[0] not in _SCORES_LABELS:
            continue
        try:
            out[_SCORES_LABELS[cells[0]]] = float(cells[1].split()[0])
        except ValueError:
            continue
    return out


def regressions(baseline: dict[str, float], current: dict[str, float]) -> list[str]:
    """Every ratcheted metric that moved DOWN from the baseline, as printable reasons."""
    out: list[str] = []
    for key in _RATCHETED:
        if key not in baseline or key not in current:
            continue
        now, was = round(current[key], _TABLE_DECIMALS), round(baseline[key], _TABLE_DECIMALS)
        if now < was:
            out.append(f"{key} regressed: {now:.3f} < committed {was:.3f}")
    return out


def committed_baseline() -> dict[str, float]:
    """The SCORES.md at HEAD (the last agreed numbers), falling back to the working copy
    outside a git checkout. An empty dict means no baseline: the floor alone applies."""
    try:
        text = subprocess.run(
            ["git", "show", f"HEAD:{SCORES_PATH.relative_to(_REPO_ROOT).as_posix()}"],
            capture_output=True, text=True, check=True, cwd=_REPO_ROOT,
        ).stdout
    except (subprocess.CalledProcessError, OSError):
        text = SCORES_PATH.read_text() if SCORES_PATH.exists() else ""
    return parse_scores_baseline(text)


@dataclass
class FixtureScore:
    fixture: Fixture
    ok_count: bool
    name_tp: int
    name_expected: int
    name_predicted: int
    field_correct: int
    field_total: int
    expected_question: bool
    got_question: bool
    error: str | None
    latency_ms: float

    @property
    def canonical(self) -> bool:
        return self.fixture.id in CANONICAL_IDS

    @property
    def canonical_pass(self) -> bool:
        return self.ok_count and self.field_correct == self.field_total and self.error is None


def _norm(text: str) -> str:
    return " ".join(text.lower().split())


def _name_hits(expected: list[str], predicted: list[str]) -> int:
    pred = [_norm(p) for p in predicted]
    hits = 0
    for name in expected:
        n = _norm(name)
        if any(n in p or p in n for p in pred):
            hits += 1
    return hits


async def _score_fixture(fixture: Fixture, resolver: Resolver) -> FixtureScore:
    client = FakeParserClient()
    started = time.perf_counter()
    try:
        meal, _, _ = await parse_transcript(client, fixture.transcript)
    except ParseError as exc:
        return FixtureScore(
            fixture,
            False,
            0,
            len(fixture.names),
            0,
            0,
            0,
            fixture.expect_question,
            False,
            str(exc),
            0.0,
        )

    decision = await ClarifyEngine(resolver).decide(meal.items, meal.missing_details)
    # Resolve to exercise the macro path (and surface resolver crashes).
    await resolver.resolve_meal(meal.items)
    latency_ms = (time.perf_counter() - started) * 1000

    predicted_names = [i.name for i in meal.items]
    name_tp = _name_hits(fixture.names, predicted_names)

    field_correct, field_total = _score_fields(fixture, meal)

    return FixtureScore(
        fixture=fixture,
        ok_count=(len(meal.items) == fixture.item_count),
        name_tp=name_tp,
        name_expected=len(fixture.names),
        name_predicted=len(predicted_names),
        field_correct=field_correct,
        field_total=field_total,
        expected_question=fixture.expect_question,
        got_question=len(decision.questions) > 0,
        error=None,
        latency_ms=latency_ms,
    )


def _score_fields(fixture: Fixture, meal) -> tuple[int, int]:
    correct = total = 0
    for idx, expected in fixture.amounts.items():
        total += 1
        if idx < len(meal.items) and meal.items[idx].amount == expected:
            correct += 1
    for idx, expected in fixture.units.items():
        total += 1
        got = meal.items[idx].unit.value if idx < len(meal.items) and meal.items[idx].unit else None
        if got == expected:
            correct += 1
    for idx, expected in fixture.states.items():
        total += 1
        if idx < len(meal.items) and meal.items[idx].state.value == expected:
            correct += 1
    for idx, expected in fixture.fat_ratios.items():
        total += 1
        if idx < len(meal.items) and meal.items[idx].fat_ratio == expected:
            correct += 1
    for idx, expected in fixture.brands.items():
        total += 1
        got = meal.items[idx].brand if idx < len(meal.items) else None
        if got and _norm(got) == _norm(str(expected)):
            correct += 1
    return correct, total


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    k = max(0, min(len(ordered) - 1, round((pct / 100) * (len(ordered) - 1))))
    return ordered[k]


def _prf(tp: int, predicted: int, expected: int) -> tuple[float, float, float]:
    precision = tp / predicted if predicted else 0.0
    recall = tp / expected if expected else 0.0
    f1 = (2 * precision * recall / (precision + recall)) if (precision + recall) else 0.0
    return precision, recall, f1


def run() -> int:
    corpus = load_corpus()
    resolver = Resolver()  # dictionary-only; FDC long-tail is unit-tested separately
    scores = asyncio.run(_run_all(corpus, resolver))

    name_tp = sum(s.name_tp for s in scores)
    name_pred = sum(s.name_predicted for s in scores)
    name_exp = sum(s.name_expected for s in scores)
    n_precision, n_recall, n_f1 = _prf(name_tp, name_pred, name_exp)

    field_correct = sum(s.field_correct for s in scores)
    field_total = sum(s.field_total for s in scores)
    field_acc = field_correct / field_total if field_total else 1.0

    q_tp = sum(1 for s in scores if s.expected_question and s.got_question)
    q_fp = sum(1 for s in scores if not s.expected_question and s.got_question)
    q_fn = sum(1 for s in scores if s.expected_question and not s.got_question)
    q_precision = q_tp / (q_tp + q_fp) if (q_tp + q_fp) else 1.0
    q_recall = q_tp / (q_tp + q_fn) if (q_tp + q_fn) else 1.0

    latencies = [s.latency_ms for s in scores if s.error is None]
    p50, p95 = _percentile(latencies, 50), _percentile(latencies, 95)

    canon = [s for s in scores if s.canonical]
    canon_pass = all(s.canonical_pass for s in canon)
    canon_field_acc = (
        sum(s.field_correct for s in canon) / sum(s.field_total for s in canon)
        if sum(s.field_total for s in canon)
        else 1.0
    )

    _write_scores(
        scores,
        n_precision,
        n_recall,
        n_f1,
        field_acc,
        canon_field_acc,
        q_precision,
        q_recall,
        p50,
        p95,
    )

    failures = []
    if not canon_pass:
        failures.append("canonical-four did not all pass (count + fields)")
    canon_names_missed = [s.fixture.id for s in canon if s.name_tp < s.name_expected]
    if canon_names_missed:
        failures.append(f"canonical-four names regressed: {', '.join(canon_names_missed)}")
    if n_f1 < ITEM_EXTRACTION_F1_GATE:
        failures.append(f"item-extraction F1 {n_f1:.3f} < gate {ITEM_EXTRACTION_F1_GATE}")
    current = {
        "fixtures": float(len(scores)),
        "extraction_f1": n_f1,
        "field_accuracy": field_acc,
        "canonical_field_accuracy": canon_field_acc,
        "question_precision": q_precision,
        "question_recall": q_recall,
    }
    failures.extend(regressions(committed_baseline(), current))

    print(
        f"corpus: {len(scores)} fixtures | extraction F1 {n_f1:.3f} | "
        f"field acc {field_acc:.3f} | Q P/R {q_precision:.2f}/{q_recall:.2f} | "
        f"p50 {p50:.1f}ms p95 {p95:.1f}ms"
    )
    print(f"canonical-four: {'PASS' if canon_pass else 'FAIL'} (field acc {canon_field_acc:.3f})")
    if failures:
        for f in failures:
            print(f"GATE FAIL: {f}", file=sys.stderr)
        return 1
    print(f"SCORES written to {SCORES_PATH}")
    return 0


async def _run_all(corpus: list[Fixture], resolver: Resolver) -> list[FixtureScore]:
    return [await _score_fixture(f, resolver) for f in corpus]


def _write_scores(scores, n_p, n_r, n_f1, field_acc, canon_field_acc, q_p, q_r, p50, p95) -> None:
    lines = [
        "# Parser corpus SCORES",
        "",
        "> Binding regression net (decision #22): a SCORES regression does not merge.",
        "> **Mode: recorded-fixture (offline).** The LLM is `FakeParserClient` serving",
        "> golden tool outputs from `tests/fixtures/llm_responses/`. A live-model",
        "> baseline (Sonnet 4.6 vs Haiku 4.5) is a TODO blocked on `ANTHROPIC_API_KEY`",
        "> — run `uv run pytest -m live_llm` once a key is set, then record both here.",
        "> Resolution is dictionary-only; FDC long-tail accuracy is covered by",
        "> `tests/test_resolver.py::test_fdc_fallback_resolves_long_tail`.",
        "",
        "## Aggregate",
        "",
        "| Metric | Value |",
        "|---|---|",
        f"| Fixtures | {len(scores)} |",
        f"| Item-extraction precision | {n_p:.3f} |",
        f"| Item-extraction recall | {n_r:.3f} |",
        f"| Item-extraction F1 | {n_f1:.3f} |",
        f"| Field accuracy (all) | {field_acc:.3f} |",
        f"| Field accuracy (canonical four) | {canon_field_acc:.3f} |",
        f"| Question precision | {q_p:.3f} |",
        f"| Question recall | {q_r:.3f} |",
                "",
        "## Per-fixture",
        "",
        "| id | canonical | count ok | names tp/exp | fields | expect Q | got Q | err |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for s in scores:
        lines.append(
            f"| {s.fixture.id} | {'✓' if s.canonical else ''} | "
            f"{'✓' if s.ok_count else '✗'} | {s.name_tp}/{s.name_expected} | "
            f"{s.field_correct}/{s.field_total} | {'Y' if s.expected_question else 'n'} | "
            f"{'Y' if s.got_question else 'n'} | {s.error or ''} |"
        )
    lines.append("")
    SCORES_PATH.write_text("\n".join(lines))


if __name__ == "__main__":
    raise SystemExit(run())
