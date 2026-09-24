"""The ratchet table for the API: mechanical rules over the tracked sources as text.

Same contract as Tests/VoCalCoreTests/TidyTests.swift (docs/restructure/01-ratchets.md):
rows are data, one enforcer runs every row, ceilings only go down, a nonzero ceiling
names its exact file set, and every rule states its kind. Comment lines and docstring
lines are skipped; the table itself and docs/ sit outside every root.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[3]

# Modules whose string literals reach a person: questions, certainty copy, nudges,
# recalibration wording, the protocol's "why" lines, HTTP details the app shows.
_USER_FACING = [
    "services/api/src/api/parser/certainty.py",
    "services/api/src/api/parser/clarify.py",
    "services/api/src/api/parser/prompts.py",
    "services/api/src/api/parser/router.py",
    "services/api/src/api/meals/router.py",
    "services/api/src/api/checkin",
    "services/api/src/api/nudges",
    "services/api/src/api/protocols/why.py",
]


@dataclass(frozen=True)
class Rule:
    id: str
    description: str
    roots: list[str]
    pattern: str
    max: int
    expected_paths: list[str] | None = None
    excluding: list[str] = field(default_factory=list)


RULES = [
    # INCIDENT: Lorenzo's product-wide rule, no em dashes in copy a person reads. The
    # 2026-08-23 sweep landed on feature/help-tour and never reached main; on 2026-09-23 five
    # user-facing strings still carried one (a few-shot question, the focus tip, an HTTP detail).
    Rule("TIDY-PY-WORDS-001", "No em dash in a string a person reads; use a period, a comma or 'to'.",
         _USER_FACING, r'"[^"]*—[^"]*"', 0),
    # SUPERSESSION: log through `logging` (MUST-NOT #5 is enforced at the logger call sites;
    # a print bypasses the formatter and the privacy rules).
    Rule("TIDY-PY-PRINT-001", "Log through logging.getLogger(__name__), never print.",
         ["services/api/src"], r"^\s*print\(", 0),
    # SUPERSESSION: the app is async; a blocking sleep stalls every request on the loop.
    Rule("TIDY-PY-SLEEP-001", "Use asyncio.sleep in the async app, never time.sleep.",
         ["services/api/src"], r"\btime\.sleep\(", 0),
    # SUPERSESSION: fix the finding instead of silencing it. The nine files that carry a
    # suppression today are the whole set; a tenth needs its own argument here.
    Rule("TIDY-PY-NOQA-001", "Fix the ruff finding instead of adding # noqa.",
         ["services/api/src"], r"# noqa", 15, expected_paths=[
             "services/api/src/api/account/router.py",
             "services/api/src/api/checkin/recommend.py",
             "services/api/src/api/main.py",
             "services/api/src/api/meals/router.py",
             "services/api/src/api/nutrition/dictionary.py",
             "services/api/src/api/nutrition/estimator.py",
             "services/api/src/api/parser/llm.py",
             "services/api/src/api/transcribe/elevenlabs.py",
             "services/api/src/api/weekbudget/router.py",
         ]),
    # BOUNDARY: services/api/AGENTS.md, every external dependency degrades behind a seam;
    # a broad catch belongs at a seam (estimator, transcriber, storage) and nowhere new.
    # 12, not 11 (2026-09-25): the estimator's lane race reads each lane's result at the
    # provider seam (nutrition/estimator.py _answer), a decline never a 500.
    Rule("TIDY-PY-EXCEPT-001", "Catch the specific error; a broad catch belongs only at an external seam.",
         ["services/api/src"], r"\bexcept Exception\b", 12, expected_paths=[
             "services/api/src/api/captures/router.py",
             "services/api/src/api/captures/store.py",
             "services/api/src/api/dev/router.py",
             "services/api/src/api/meals/store.py",
             "services/api/src/api/nutrition/estimator.py",
             "services/api/src/api/protocols/store.py",
             "services/api/src/api/transcribe/elevenlabs.py",
         ]),
]


def _tracked_python_files() -> list[str]:
    out = subprocess.run(["git", "ls-files", "--", "services/api"], capture_output=True, text=True, check=True, cwd=_REPO)
    return sorted(p for p in out.stdout.splitlines() if p.endswith(".py") and (_REPO / p).exists())


def _in_roots(path: str, rule: Rule) -> bool:
    if path in rule.excluding:
        return False
    return any(path == root or path.startswith(root.rstrip("/") + "/") for root in rule.roots)


def _violations(rule: Rule) -> list[tuple[str, int, str]]:
    regex = re.compile(rule.pattern)
    found: list[tuple[str, int, str]] = []
    for path in _tracked_python_files():
        if not _in_roots(path, rule):
            continue
        in_docstring = False
        for number, line in enumerate((_REPO / path).read_text().splitlines(), start=1):
            stripped = line.strip()
            quotes = stripped.count('"""')
            if quotes % 2 == 1:
                in_docstring = not in_docstring
                continue
            # A one-line docstring ("""…""") is documentation, not copy a person reads.
            if in_docstring or stripped.startswith("#") or (quotes == 2 and stripped.startswith('"""')):
                continue
            if regex.search(line):
                found.append((path, number, stripped))
    return found


@pytest.mark.parametrize("rule", RULES, ids=[r.id for r in RULES])
def test_ratchet(rule: Rule) -> None:
    found = _violations(rule)
    listing = "\n".join(f"{p}:{n}: {text}" for p, n, text in found[:50]) or "No violations."
    assert len(found) <= rule.max, f"[{rule.id}] {rule.description}\nobserved={len(found)} max={rule.max}\n{listing}"
    if rule.expected_paths is not None:
        observed = sorted({p for p, _, _ in found})
        assert observed == sorted(rule.expected_paths), (
            f"[{rule.id}] the named exception set changed (a violation may not be traded for another).\n"
            f"observed={observed}\nexpected={sorted(rule.expected_paths)}"
        )


def test_rules_are_well_formed() -> None:
    ids = [r.id for r in RULES]
    assert len(set(ids)) == len(ids)
    for rule in RULES:
        assert re.fullmatch(r"TIDY-PY-[A-Z]+-\d{3}", rule.id), rule.id
        re.compile(rule.pattern)
        for root in rule.roots:
            assert (_REPO / root).exists(), f"{rule.id}: root {root} does not exist"
        if rule.max > 0:
            assert rule.expected_paths, f"{rule.id}: a nonzero ceiling must name its exact path set"
