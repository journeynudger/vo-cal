# Photo parse fixtures

Recorded tool outputs for `POST /parse/photo` (parser/photo.py `FakePhotoParserClient`),
keyed by the note typed with the photo (`note`), lowercased and whitespace-collapsed;
`default.json` answers any photo without a matching note. An image's bytes cannot key a
fixture, so the suite never depends on a particular picture.

`default.json` is authored in the tool's shape (2026-09-25): a burger plate with fries and
the blind spot a photo cannot confirm, mayonnaise, asked as an amount question whose first
option is None. Record a real reply with `scripts/photo-probe` once one exists.
