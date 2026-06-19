"""Phase H admin store tests — the pure assembly/aggregate helpers (no DB, no app).

These are the functions ``scripts/review`` and the router both import; testing
them directly keeps the math honest independent of the HTTP layer.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from api.admin.store import (
    assemble_chain,
    confidence_calibration,
    correction_rate_by_week,
    filter_logs,
    question_precision,
    top_corrected_foods,
)

BASE = datetime(2026, 6, 1, tzinfo=UTC)


def _meal(mid, *, conf=0.9, parse_id=None, deleted=False, days=0, items=1):
    return {
        "id": mid,
        "user_id": "u1",
        "name": mid,
        "meal_type": "lunch",
        "parse_id": parse_id,
        "items": [{"name": f"food{i}"} for i in range(items)],
        "totals": {"kcal": 100.0},
        "confidence": conf,
        "logged_at": (BASE + timedelta(days=days)).isoformat(),
        "deleted_at": (BASE.isoformat() if deleted else None),
    }


def _parse(pid, *, questions):
    return {"id": pid, "payload": {"result": {"questions": questions}}}


def _corr(mid, *, idx=0, field="amount"):
    return {"meal_log_id": mid, "item_index": idx, "field": field,
            "parsed_value": "a", "confirmed_value": "b"}


# -- filter_logs -------------------------------------------------------------


def test_filter_excludes_deleted():
    meals = [_meal("m1"), _meal("m2", deleted=True)]
    out = filter_logs(meals, [], [])
    assert [r["id"] for r in out] == ["m1"]


def test_filter_low_confidence():
    meals = [_meal("hi", conf=0.95), _meal("lo", conf=0.5)]
    out = filter_logs(meals, [], [], low_confidence=True)
    assert [r["id"] for r in out] == ["lo"]


def test_filter_has_corrections():
    meals = [_meal("m1"), _meal("m2")]
    out = filter_logs(meals, [_corr("m1")], [], has_corrections=True)
    assert [r["id"] for r in out] == ["m1"]
    assert out[0]["corrections_count"] == 1


def test_filter_question_asked():
    meals = [_meal("asked", parse_id="p1"), _meal("silent", parse_id="p2")]
    parses = [_parse("p1", questions=[{"field": "x"}]), _parse("p2", questions=[])]
    asked = filter_logs(meals, [], parses, question_asked=True)
    silent = filter_logs(meals, [], parses, question_asked=False)
    assert [r["id"] for r in asked] == ["asked"]
    assert [r["id"] for r in silent] == ["silent"]


def test_filter_user_and_date_range():
    meals = [_meal("d0", days=0), _meal("d5", days=5)]
    meals[1]["user_id"] = "u2"
    out = filter_logs(meals, [], [], user_id="u1")
    assert [r["id"] for r in out] == ["d0"]
    ranged = filter_logs(meals, [], [], start=BASE + timedelta(days=1))
    assert [r["id"] for r in ranged] == ["d5"]


def test_filter_sorted_newest_first():
    meals = [_meal("old", days=0), _meal("new", days=3)]
    out = filter_logs(meals, [], [])
    assert [r["id"] for r in out] == ["new", "old"]


# -- assemble_chain ----------------------------------------------------------


def test_assemble_chain_sorts_corrections_and_joins_capture():
    meal = _meal("m1", parse_id="p1")
    parse = {"id": "p1", "capture_id": "cap1",
             "payload": {"parsed_meal": {"items": []}, "result": {"items": [], "questions": []}}}
    corrections = [_corr("m1", idx=2, field="unit"), _corr("m1", idx=0, field="amount")]
    capture = {"id": "cap1", "audio_path": "u/cap1.caf"}
    metrics = [{"name": "log_duration_ms", "value": 12000, "ts": BASE.isoformat()}]
    chain = assemble_chain(meal, parse, corrections, capture, metrics)
    assert chain["meal_log_id"] == "m1"
    assert chain["audio_path"] == "u/cap1.caf"
    # sorted by (item_index, field)
    assert [(c["item_index"], c["field"]) for c in chain["corrections"]] == [(0, "amount"), (2, "unit")]
    assert chain["metrics"][0]["name"] == "log_duration_ms"


def test_assemble_chain_tolerates_missing_parse_and_capture():
    chain = assemble_chain(_meal("m1"), None, [], None, [])
    assert chain["parse_payload"] == {}
    assert chain["audio_path"] is None
    assert chain["questions"] == []


# -- aggregates --------------------------------------------------------------


def test_correction_rate_by_week():
    meals = [_meal("m1", days=0, items=2), _meal("m2", days=1, items=2)]
    out = correction_rate_by_week(meals, [_corr("m1")])
    assert len(out) == 1
    assert out[0]["items"] == 4
    assert out[0]["corrected"] == 1
    assert out[0]["rate"] == 0.25


def test_confidence_calibration_buckets():
    meals = [_meal("hi1", conf=0.9), _meal("hi2", conf=0.95), _meal("lo", conf=0.2)]
    out = confidence_calibration(meals, [_corr("hi1")])
    top = next(b for b in out if b["bucket"] == "0.9-1.0")
    assert top["meals"] == 2
    assert top["corrected_meals"] == 1
    assert top["observed_correction_rate"] == 0.5
    low = next(b for b in out if b["bucket"] == "0.2-0.3")
    assert low["observed_correction_rate"] == 0.0


def test_question_precision():
    meals = [_meal("asked_corr", parse_id="p1"), _meal("asked_clean", parse_id="p2")]
    parses = [_parse("p1", questions=[{"field": "x"}]), _parse("p2", questions=[{"field": "y"}])]
    out = question_precision(meals, parses, [_corr("asked_corr")])
    assert out["meals_with_questions"] == 2
    assert out["meals_with_questions_then_corrected"] == 1
    assert out["precision"] == 0.5


def test_top_corrected_foods_maps_names():
    meals = [_meal("m1", items=2)]  # items: food0, food1
    corrections = [_corr("m1", idx=0, field="amount"), _corr("m1", idx=0, field="unit"),
                   _corr("m1", idx=1, field="state")]
    out = top_corrected_foods(meals, corrections)
    assert out[0]["food"] == "food0"
    assert out[0]["corrections"] == 2
    assert out[0]["fields"] == {"amount": 1, "unit": 1}


def test_aggregates_empty_inputs_dont_crash():
    assert correction_rate_by_week([], []) == []
    assert confidence_calibration([], []) == []
    assert question_precision([], [], [])["precision"] is None
    assert top_corrected_foods([], []) == []
