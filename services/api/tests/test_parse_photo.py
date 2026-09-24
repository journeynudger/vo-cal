"""A photo is a capture and a priced parse; what the photo cannot show is asked
(parser/photo.py, POST /parse/photo, parser/clarify.py absence_index).

Offline: the recorded photo reply (tests/fixtures/photo_responses/default.json) stands in
for the vision model; the ladder prices its items exactly as it prices a transcript's.
"""

from __future__ import annotations

from api.storage import CAPTURE_PHOTO_BUCKET

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


def _post_photo(client, headers, *, data: bytes = JPEG, media_type: str = "image/jpeg", client_capture_id: str = "photo_1", note: str | None = None):
    form = {"client_capture_id": client_capture_id}
    if note is not None:
        form["note"] = note
    return client.post(
        "/parse/photo",
        files={"photo": ("meal.jpg", data, media_type)},
        data=form,
        headers=headers,
    )


def test_photo_is_stored_as_a_capture_and_priced_by_the_ladder(client, auth_headers, fake_db, fake_storage):
    resp = _post_photo(client, auth_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    names = [i["name"] for i in body["items"]]
    assert names == ["ground beef", "hamburger bun", "french fries", "mayonnaise"]
    assert body["totals"]["kcal"] > 300
    assert all(i["macros"]["kcal"] > 0 for i in body["items"]), "every item priced, none left at zero"

    # The blind spot is a question whose first option is None, in the model's own words.
    sauce = next(q for q in body["questions"] if q["field"] == "items[3].amount")
    assert sauce["question"] == "Is there sauce on the burger?"
    assert sauce["options"][0] == "None"
    assert sauce["options"] == ["None", "1 tsp", "1 tbsp", "2 tbsp"]

    # The capture: bytes in the photo bucket, a row with the image type, the parse linked.
    rows = fake_db.tables["captures"]
    assert len(rows) == 1
    capture = rows[0]
    assert capture["content_type"] == "image/jpeg"
    assert capture["audio_path"].endswith("/photo_1.jpg")
    assert fake_storage.blobs[(CAPTURE_PHOTO_BUCKET, capture["audio_path"])] == JPEG
    parse_row = fake_db.tables["parses"][0]
    assert parse_row["capture_id"] == capture["id"]
    assert parse_row["prompt_version"].startswith("vocal-photo-")


def test_none_to_the_sauce_question_removes_the_hidden_item(client, auth_headers):
    parsed = _post_photo(client, auth_headers).json()
    before = parsed["totals"]["kcal"]
    refined = client.post(
        "/parse/refine",
        json={"parse_id": parsed["parse_id"], "answers": [{"field": "items[3].amount", "value": "None"}]},
        headers=auth_headers,
    )
    assert refined.status_code == 200, refined.text
    body = refined.json()
    assert [i["name"] for i in body["items"]] == ["ground beef", "hamburger bun", "french fries"]
    assert body["totals"]["kcal"] < before
    assert not any(q["field"] == "items[3].amount" for q in body["questions"])


def test_an_amount_to_the_sauce_question_keeps_it_at_that_amount(client, auth_headers):
    parsed = _post_photo(client, auth_headers).json()
    mayo_before = next(i for i in parsed["items"] if i["name"] == "mayonnaise")
    refined = client.post(
        "/parse/refine",
        json={"parse_id": parsed["parse_id"], "answers": [{"field": "items[3].amount", "value": "2 tbsp"}]},
        headers=auth_headers,
    ).json()
    mayo = next(i for i in refined["items"] if i["name"] == "mayonnaise")
    assert mayo["amount"] == 2
    assert mayo["unit"] == "tbsp"
    assert mayo["macros"]["kcal"] > mayo_before["macros"]["kcal"]


def test_a_note_rides_along_as_the_transcript(client, auth_headers, fake_db):
    resp = _post_photo(client, auth_headers, note="lunch at the diner, no sauce")
    assert resp.status_code == 200, resp.text
    assert fake_db.tables["parses"][0]["payload"]["transcript"] == "lunch at the diner, no sauce"


def test_replaying_the_same_photo_reuses_the_capture(client, auth_headers, fake_db):
    first = _post_photo(client, auth_headers)
    second = _post_photo(client, auth_headers)
    assert first.status_code == 200
    assert second.status_code == 200
    assert len(fake_db.tables["captures"]) == 1
    assert len(fake_db.tables["parses"]) == 2  # parses are append-only artifacts


def test_a_png_is_accepted_and_a_mislabelled_or_odd_upload_is_refused(client, auth_headers, fake_db):
    assert _post_photo(client, auth_headers, data=PNG, media_type="image/png", client_capture_id="photo_png").status_code == 200
    assert _post_photo(client, auth_headers, data=b"not an image", media_type="image/jpeg", client_capture_id="photo_bad").status_code == 415
    assert _post_photo(client, auth_headers, data=JPEG, media_type="text/plain", client_capture_id="photo_txt").status_code == 415
    assert _post_photo(client, auth_headers, data=b"", media_type="image/jpeg", client_capture_id="photo_empty").status_code == 422
    assert _post_photo(client, auth_headers, client_capture_id="../escape").status_code == 422
    assert len(fake_db.tables["captures"]) == 1  # only the PNG landed


def test_an_oversized_photo_is_refused_before_storage(client, auth_headers, fake_db):
    huge = b"\xff\xd8\xff" + b"\x00" * (8 * 1024 * 1024 + 1)
    assert _post_photo(client, auth_headers, data=huge, client_capture_id="photo_huge").status_code == 413
    assert fake_db.tables.get("captures", []) == []


def test_photo_captures_are_owner_scoped(client, auth_headers, auth_headers_user_2, fake_db):
    mine = _post_photo(client, auth_headers).json()
    theirs = client.post(
        "/parse/refine",
        json={"parse_id": mine["parse_id"], "answers": [{"field": "items[3].amount", "value": "None"}]},
        headers=auth_headers_user_2,
    )
    assert theirs.status_code == 404
