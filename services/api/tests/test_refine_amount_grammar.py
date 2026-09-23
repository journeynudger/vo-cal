"""The refine amount answer grammar has one address per side (docs/PARSER_CONTRACT.md,
"Refine answers"): the app composes "<amount> <unit>" through RefineAmountAnswer (VoCalCore)
and this regex parses it. The table below is the Swift test's table; both sides must agree.
"""

from __future__ import annotations

import pytest

from api.parser.clarify import _parse_amount_answer
from api.parser.schemas import Unit


@pytest.mark.parametrize(
    ("answer", "expected"),
    [
        ("4 oz", (4.0, Unit.OZ)),
        ("1.5 cup", (1.5, Unit.CUP)),
        ("200 g", (200.0, Unit.G)),
        ("2", (2.0, None)),
        ("0.25 tsp", (0.25, Unit.TSP)),
    ],
)
def test_swift_composed_answers_parse(answer: str, expected) -> None:
    assert _parse_amount_answer(answer) == expected


def test_every_contract_unit_parses_from_its_raw_value() -> None:
    for unit in Unit:
        assert _parse_amount_answer(f"1 {unit.value}") == (1.0, unit)
