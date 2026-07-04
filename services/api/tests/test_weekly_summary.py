"""GET /meals/summary — the check-in's capture-quality week (certainty layer).

Offline: FakeDatabase seeded with stored meal_logs rows (the shape MealsStore writes),
re-scored deterministically. Pins: honest sparse-data handling (no fake trends), the
count/avg/most-missing aggregation, and tz-aware weekly windowing.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4

TEST_USER = "11111111-1111-1111-1111-111111111111"


def _meal_row(logged_at: datetime, *, name="pasta", amount=None, confidence=0.55) -> dict:
    return {
        "id": str(uuid4()),
        "user_id": TEST_USER,
        "client_meal_id": str(uuid4()),
        "name": name,
        "meal_type": "lunch",
        "items": [
            {
                "name": name, "amount": amount, "unit": None, "state": "unspecified",
                "fat_ratio": None, "brand": None, "prep_method": None, "variant": None,
                "grams": 200.0, "macros": {"kcal": 220.0, "protein": 8.0, "carbs": 43.0, "fat": 1.3},
                "confidence": confidence, "source": "dictionary", "is_estimate": False,
            }
        ],
        "totals": {"kcal": 220.0, "protein": 8.0, "carbs": 43.0, "fat": 1.3},
        "confidence": confidence,
        "logged_at": logged_at.isoformat(),
    }


def test_summary_requires_auth(client):
    assert client.get("/meals/summary", params={"date": "2026-07-03"}).status_code == 401


def test_summary_empty_week_is_honest(client, auth_headers):
    resp = client.get("/meals/summary", params={"date": "2026-07-03"}, headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["meals_logged"] == 0
    assert body["avg_certainty"] is None
    assert body["focus_tip"] is None
    assert body["sufficient_data"] is False


def test_summary_sparse_week_shows_count_but_no_trends(client, auth_headers, fake_db):
    day = datetime(2026, 7, 2, 12, 0, tzinfo=UTC)
    fake_db.tables.setdefault("meal_logs", []).extend([_meal_row(day), _meal_row(day)])
    body = client.get(
        "/meals/summary", params={"date": "2026-07-03"}, headers=auth_headers
    ).json()
    assert body["meals_logged"] == 2
    assert body["sufficient_data"] is False  # < 3 meals: no thin trends, no focus tip
    assert body["focus_tip"] is None
    assert body["avg_certainty"] is not None  # the honest average still shows


def test_summary_full_week_aggregates_certainty_and_focus(client, auth_headers, fake_db):
    base = datetime(2026, 6, 28, 12, 0, tzinfo=UTC)
    rows = [
        _meal_row(base + timedelta(days=i % 4), amount=None)  # vague pastas → portion missing
        for i in range(6)
    ]
    fake_db.tables.setdefault("meal_logs", []).extend(rows)
    body = client.get(
        "/meals/summary", params={"date": "2026-07-03"}, headers=auth_headers
    ).json()
    assert body["meals_logged"] == 6
    assert body["days_logged"] == 4
    assert body["sufficient_data"] is True
    assert 5 <= body["avg_certainty"] <= 99
    assert body["most_common_missing_detail"] == "portion_size"
    assert "bowl" in body["focus_tip"] or "cups" in body["focus_tip"]


def test_summary_window_excludes_older_meals(client, auth_headers, fake_db):
    inside = datetime(2026, 7, 1, 12, 0, tzinfo=UTC)
    outside = datetime(2026, 6, 20, 12, 0, tzinfo=UTC)  # > 7 days before the end day
    fake_db.tables.setdefault("meal_logs", []).extend([_meal_row(inside), _meal_row(outside)])
    body = client.get(
        "/meals/summary", params={"date": "2026-07-03"}, headers=auth_headers
    ).json()
    assert body["meals_logged"] == 1
