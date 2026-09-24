"""Which long-tail source is better: FatSecret or USDA FDC? Measured, not argued.

Truth: the curated dictionary (210 foods with per-100 g numbers reviewed by hand). Each
source is asked for every dictionary food by its canonical name and judged on coverage
(found a relevant row), agreement (kcal per 100 g within the tolerance of the curated
number), serving data (grams for one serving; cups, pieces) and latency. A long-tail list
with no truth (the nutritionist's examples, brands, restaurant items) is printed for
reading. The report is written to tests/fixtures/FOOD_SOURCES.md.

Live: needs FATSECRET_CLIENT_ID/SECRET and USDA_FDC_API_KEY in the environment (.env) and
an allow-listed IP for FatSecret. ``--record`` also writes the raw FatSecret responses for
the fixture foods into tests/fixtures/fatsecret_responses/, replacing the authored ones.

    scripts/food-source-eval            # the report
    scripts/food-source-eval --record   # plus recorded fixtures
    scripts/food-source-eval --limit 40 # a quick loop
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

from api.db import FakeDatabase
from api.nutrition.dictionary import get_dictionary
from api.nutrition.fatsecret_client import FatSecretClient
from api.nutrition.fdc_client import FdcClient

FIXTURES = Path(__file__).resolve().parent / "fixtures"
REPORT = FIXTURES / "FOOD_SOURCES.md"
TOLERANCE = 0.15  # kcal per 100 g within 15 percent of the curated number counts as agreement

LONG_TAIL = [
    ("spanakopita", None), ("halloumi", None), ("pierogi", None), ("bison bacon", None),
    ("street taco chicken", None), ("beef medallions", None), ("protein pancake", None),
    ("greek yogurt protein smoothie", None), ("big mac", "McDonald's"), ("burrito bowl", "Chipotle"),
    ("greek yogurt", "Chobani"), ("2% milk", "Fairlife"), ("protein bar", "Quest"),
    ("oikos triple zero", None), ("kodiak protein pancake mix", None), ("cosmic crisp apple", None),
]


async def _time(coro):
    t = time.perf_counter()
    result = await coro
    return result, (time.perf_counter() - t) * 1000


def _agree(value: float | None, truth: float) -> bool:
    return value is not None and truth > 0 and abs(value - truth) <= TOLERANCE * truth


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values) or [0.0]
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


async def _score_dictionary(fs: FatSecretClient, fdc: FdcClient, limit: int | None) -> list[dict]:
    entries = list(get_dictionary()._by_canonical.values())
    seen: set[str] = set()
    unique = []
    for entry in entries:
        if entry.canonical_name not in seen:
            seen.add(entry.canonical_name)
            unique.append(entry)
    if limit:
        unique = unique[:limit]
    rows = []
    for entry in unique:
        name = entry.canonical_name
        fs_result, fs_ms = await _time(fs.resolve(name)) if fs.configured else (None, 0.0)
        fdc_result, fdc_ms = await _time(fdc.resolve(name)) if os.environ.get("USDA_FDC_API_KEY") else (None, 0.0)
        rows.append({
            "name": name, "truth": entry.profile.kcal,
            "fs": None if fs_result is None else fs_result.per_100g.kcal,
            "fs_serving": None if fs_result is None else fs_result.serving_grams,
            "fs_units": None if fs_result is None else sorted(fs_result.unit_conversions),
            "fs_ms": round(fs_ms),
            "fdc": None if fdc_result is None else fdc_result.profile.kcal,
            "fdc_ms": round(fdc_ms),
        })
    return rows


async def _score_long_tail(fs: FatSecretClient, fdc: FdcClient) -> list[tuple]:
    tail = []
    for name, brand in LONG_TAIL:
        term = f"{brand} {name}" if brand else name
        fs_result, fs_ms = await _time(fs.resolve(term, branded=bool(brand))) if fs.configured else (None, 0.0)
        fdc_result, fdc_ms = await _time(fdc.resolve(term, branded=bool(brand))) if os.environ.get("USDA_FDC_API_KEY") else (None, 0.0)
        tail.append((term, fs_result, round(fs_ms), fdc_result, round(fdc_ms)))
    return tail


def _report(rows: list[dict], tail: list[tuple]) -> list[str]:
    n = len(rows) or 1
    fs_ms = [r["fs_ms"] for r in rows if r["fs_ms"]]
    fdc_ms = [r["fdc_ms"] for r in rows if r["fdc_ms"]]
    lines = [
        "# Food sources, measured",
        "",
        f"Truth: {len(rows)} curated dictionary foods (kcal per 100 g). Agreement = within {int(TOLERANCE * 100)} percent.",
        "",
        "| Source | Found | Agree with the curated number | Serving grams | Cups/pieces | Latency p50 / p95 ms |",
        "|---|---|---|---|---|---|",
        f"| FatSecret | {sum(r['fs'] is not None for r in rows)}/{n} | {sum(_agree(r['fs'], r['truth']) for r in rows)}/{n} | {sum(bool(r['fs_serving']) for r in rows)}/{n} | {sum(bool(r['fs_units']) for r in rows)}/{n} | {_percentile(fs_ms, 0.5):.0f} / {_percentile(fs_ms, 0.95):.0f} |",
        f"| USDA FDC | {sum(r['fdc'] is not None for r in rows)}/{n} | {sum(_agree(r['fdc'], r['truth']) for r in rows)}/{n} | 0/{n} (per-100 g rows only) | 0/{n} | {_percentile(fdc_ms, 0.5):.0f} / {_percentile(fdc_ms, 0.95):.0f} |",
        "",
        "## Where they disagree with the curated number",
        "",
        "| Food | Curated | FatSecret | USDA |",
        "|---|---|---|---|",
    ]
    for r in rows:
        fs_off = r["fs"] is not None and not _agree(r["fs"], r["truth"])
        fdc_off = r["fdc"] is not None and not _agree(r["fdc"], r["truth"])
        if fs_off or fdc_off:
            fs_text = "miss" if r["fs"] is None else f"{r['fs']:.0f}"
            fdc_text = "miss" if r["fdc"] is None else f"{r['fdc']:.0f}"
            lines.append(f"| {r['name']} | {r['truth']:.0f} | {fs_text} | {fdc_text} |")
    lines += ["", "## Long tail (no curated truth; read them)", "", "| Term | FatSecret | USDA |", "|---|---|---|"]
    for term, fsr, fsms, fdcr, fdcms in tail:
        left = "miss" if fsr is None else f"{fsr.description}: {fsr.per_100g.kcal:.0f} kcal/100 g, serving {fsr.serving_description} ({fsr.serving_grams} g), units {sorted(fsr.unit_conversions)} [{fsms} ms]"
        right = "miss" if fdcr is None else f"{fdcr.description}: {fdcr.profile.kcal:.0f} kcal/100 g [{fdcms} ms]"
        lines.append(f"| {term} | {left} | {right} |")
    return lines


async def _record_fixtures(fs: FatSecretClient) -> None:
    import httpx

    from api.nutrition.fatsecret_client import API_URL

    out = FIXTURES / "fatsecret_responses"
    async with httpx.AsyncClient(timeout=10) as client:
        token = await fs._access_token(client)
        headers = {"Authorization": f"Bearer {token}"}
        for term, stem in (("spanakopita", "spanakopita"), ("McDonald's big mac", "bigmac")):
            search = (await client.post(API_URL, data={"method": "foods.search", "format": "json", "search_expression": term, "max_results": 8}, headers=headers)).json()
            (out / f"{stem}_search.json").write_text(json.dumps(search, indent=2))
            foods = search.get("foods", {}).get("food")
            first = foods[0] if isinstance(foods, list) else foods
            if first:
                detail = (await client.post(API_URL, data={"method": "food.get.v4", "format": "json", "food_id": first["food_id"]}, headers=headers)).json()
                (out / f"{stem}_detail.json").write_text(json.dumps(detail, indent=2))
    print(f"recorded fixtures into {out}")


async def run(limit: int | None, record: bool) -> int:
    db = FakeDatabase()
    fs = FatSecretClient(db)
    fdc = FdcClient(db)
    rows = await _score_dictionary(fs, fdc, limit)
    tail = await _score_long_tail(fs, fdc)
    lines = _report(rows, tail)
    REPORT.write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:8]))
    print(f"report: {REPORT}")
    if record and fs.configured:
        await _record_fixtures(fs)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--record", action="store_true")
    args = parser.parse_args()
    if not (os.environ.get("FATSECRET_CLIENT_ID") and os.environ.get("FATSECRET_CLIENT_SECRET")):
        print("FATSECRET_CLIENT_ID/SECRET are not set; put them in .env", file=sys.stderr)
        return 2
    return asyncio.run(run(args.limit, args.record))


if __name__ == "__main__":
    sys.exit(main())
