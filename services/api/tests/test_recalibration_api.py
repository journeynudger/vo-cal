"""G: POST /checkin/recommend + POST /protocols/{id}/revise — monthly recalibration.

Offline (FakeDatabase). Intake weight is the starting baseline; the check-in carries current
weight + adherence; the active protocol's kcal/IBW recovers the current allocation. Proves the
branch logic surfaces (recalibrate on loss; diagnostics when stalled + non-compliant), that
revise applies a real recommendation and rejects a no-op one, and the prerequisite gates.
"""

from __future__ import annotations

from api.protocols.engine import DEFAULT_TUNABLES

# Intake weight 200 lb ≈ 90.72 kg (the recalibration starting baseline).
START_KG = 90.72


def _intake() -> dict:
    return {
        "age": 35, "sex": "male", "height_in": 70.0, "weight_lb": 200.0,
        "goal": "cut", "work": "desk", "train": "moderate", "kids": False,
        "med": "none", "stress": "moderate",
    }


def _small_female_intake() -> dict:
    """Small female on a cut: IBW (Devine) is 45.5 kg, so the raw IBW-based calorie target
    lands below the 1400 female floor and is floored at generation. Used to prove the floor
    survives a recalibration revise (the band ceiling alone would re-derive 1320 kcal)."""
    return {
        "age": 30, "sex": "female", "height_in": 60.0, "weight_lb": 110.0,
        "goal": "cut", "work": "desk", "train": "none", "kids": False,
        "med": "none", "stress": "low",
    }


def _seed_protocol(client, headers, intake: dict | None = None) -> str:
    intake = intake or _intake()
    client.post("/intake", json={"intake": intake}, headers=headers)
    resp = client.post("/protocols/generate", json={"intake": intake}, headers=headers)
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


def test_revise_reconciles_carbs_to_new_budget(client, auth_headers):
    # After a revise the protein basis moves but kcal/fat may not, so carbs must be re-derived as
    # the remainder or the stored macros no longer sum to kcal (RT-37). Previously carbs carried
    # over stale; now they reconcile within rounding.
    pid = _seed_protocol(client, auth_headers)
    _checkin(client, auth_headers, weight_kg=88.0, adherence=5)
    t = client.post(f"/protocols/{pid}/revise", headers=auth_headers).json()["targets"]
    macro_kcal = t["protein"] * 4 + t["carbs"] * 4 + t["fat"] * 9
    assert abs(macro_kcal - t["kcal"]) <= 4


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


def test_revise_never_persists_below_sex_calorie_floor(client, auth_headers):
    """End-to-end: revising a *floored* female protocol must keep the sex floor (IP §3.1).

    The v2.0 engine floors a small female's calories at the 1200 female floor (her raw
    maintenance-minus-deficit target lands below it). A later weight-loss recalibration must
    re-apply that same floor — the recalibration path now sources the floor from the engine
    tunables, so generate and revise share ONE value and revise can never persist a sub-floor
    target (PROTOCOL_LOGIC §3.1 health rail).
    """
    floor = DEFAULT_TUNABLES.calorie_floor_female  # 1200, single source of truth
    intake = _small_female_intake()
    pid = _seed_protocol(client, auth_headers, intake=intake)

    # Generation floors the female to the female floor (the rail this test guards through revise).
    v1 = client.get("/protocols/active", headers=auth_headers).json()["targets"]
    assert v1["kcal"] == floor

    # Lose ~1.9 kg (110 lb ≈ 49.9 kg -> 48.0 kg): the recalibrate_ibw branch, high adherence.
    _checkin(client, auth_headers, weight_kg=48.0, adherence=5)

    resp = client.post(f"/protocols/{pid}/revise", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["version"] == 2
    # The rail held: persisted at the floor, never below it.
    assert body["targets"]["kcal"] == floor
    assert body["targets"]["kcal"] >= floor
    # The active protocol now carries the floored target, not a sub-floor one.
    active = client.get("/protocols/active", headers=auth_headers).json()
    assert active["version"] == 2
    assert active["targets"]["kcal"] == floor
