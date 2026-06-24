"""G: POST /checkin/recommend + POST /protocols/{id}/revise — monthly recalibration.

Offline (FakeDatabase). Intake weight is the starting baseline; the check-in carries current
weight + adherence; the active protocol's kcal/IBW recovers the current allocation. Proves the
branch logic surfaces (recalibrate on loss; diagnostics when stalled + non-compliant), that
revise applies a real recommendation and rejects a no-op one, and the prerequisite gates.
"""

from __future__ import annotations

# Intake weight 200 lb ≈ 90.72 kg (the recalibration starting baseline).
START_KG = 90.72


def _intake() -> dict:
    return {
        "age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0,
        "goal": "cut", "work": "desk", "train": "moderate", "kids": False,
        "med": "none", "stress": "moderate",
    }


def _seed_protocol(client, headers) -> str:
    client.post("/intake", json={"intake": _intake()}, headers=headers)
    resp = client.post("/protocols/generate", json={"intake": _intake()}, headers=headers)
    return resp.json()["protocol_id"]


def _checkin(client, headers, *, weight_kg: float, adherence: int):
    return client.post(
        "/checkin/checkins",
        json={"weight_kg": weight_kg, "adherence_self": adherence},
        headers=headers,
    )


def test_recommend_requires_auth(client):
    assert client.post("/checkin/recommend").status_code == 401


def test_recommend_recalibrates_on_loss(client, auth_headers):
    _seed_protocol(client, auth_headers)
    _checkin(client, auth_headers, weight_kg=88.0, adherence=5)  # down ~2.7 kg
    resp = client.post("/checkin/recommend", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["kind"] == "recalibrate_ibw"
    assert body["targets"] is not None
    assert body["targets"]["target_kcal"] > 0


def test_recommend_diagnostics_when_stalled_and_noncompliant(client, auth_headers):
    _seed_protocol(client, auth_headers)
    _checkin(client, auth_headers, weight_kg=START_KG, adherence=1)  # no change, low adherence
    body = client.post("/checkin/recommend", headers=auth_headers).json()
    assert body["kind"] == "diagnostics"
    assert body["targets"] is None
    assert body["diagnostics"]


def test_recommend_422_without_checkin(client, auth_headers):
    _seed_protocol(client, auth_headers)  # intake + protocol, but no check-in
    assert client.post("/checkin/recommend", headers=auth_headers).status_code == 422


def test_recommend_422_without_protocol(client, auth_headers):
    client.post("/intake", json={"intake": _intake()}, headers=auth_headers)
    _checkin(client, auth_headers, weight_kg=88.0, adherence=5)
    assert client.post("/checkin/recommend", headers=auth_headers).status_code == 422


def test_revise_applies_recommendation(client, auth_headers):
    pid = _seed_protocol(client, auth_headers)
    v1 = client.get("/protocols/active", headers=auth_headers).json()["targets"]
    _checkin(client, auth_headers, weight_kg=88.0, adherence=5)

    resp = client.post(f"/protocols/{pid}/revise", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["version"] == 2
    assert body["active"] is True
    # Recalibrating to a lower bodyweight moves the bodyweight-derived targets (protein +
    # water); kcal is IBW/height-based so it holds unless cal/kg is cut (branch 2).
    revised = body["targets"]
    assert (revised["protein"], revised["water_oz"]) != (v1["protein"], v1["water_oz"])
    # the new version is now the active protocol
    assert client.get("/protocols/active", headers=auth_headers).json()["version"] == 2


def test_revise_409_when_no_revision_recommended(client, auth_headers):
    pid = _seed_protocol(client, auth_headers)
    _checkin(client, auth_headers, weight_kg=START_KG, adherence=1)  # diagnostics, no targets
    assert client.post(f"/protocols/{pid}/revise", headers=auth_headers).status_code == 409


def test_revise_409_for_non_active_protocol(client, auth_headers):
    _seed_protocol(client, auth_headers)
    _checkin(client, auth_headers, weight_kg=88.0, adherence=5)
    stale = "99999999-9999-9999-9999-999999999999"
    assert client.post(f"/protocols/{stale}/revise", headers=auth_headers).status_code == 409


# -- red-team regressions -----------------------------------------------------


def test_recommend_holds_on_gain_never_cuts(client, auth_headers):
    """A weight GAIN must HOLD, not get a calorie cut with a false 'you did the work' headline."""
    _seed_protocol(client, auth_headers)
    _checkin(client, auth_headers, weight_kg=93.5, adherence=5)  # up ~2.8 kg, high adherence
    body = client.post("/checkin/recommend", headers=auth_headers).json()
    assert body["kind"] == "hold"
    assert body["targets"] is None


def test_recalibration_never_cuts_below_calorie_floor():
    """A one-point cut on a tiny IBW would land below the protective floor; it must be raised."""
    from api.checkin.recommend import RecalInputs, recommend

    rec = recommend(
        RecalInputs(
            current_weight_kg=40.0,
            starting_weight_kg=40.0,  # flat -> reduce branch (compliant)
            ideal_body_weight_kg=40.0,
            current_cal_per_kg=25.0,  # -1 point -> 24*40 = 960 kcal, below the 1600 floor
            adherence=1.0,
            calorie_floor=1600,
        )
    )
    assert rec.kind.value == "reduce_allocation"
    assert rec.targets is not None
    assert rec.targets.target_kcal == 1600
    assert any("floor" in note for note in rec.clamps)
