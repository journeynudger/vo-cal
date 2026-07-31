"""Calorie-accuracy harness — runs the ground-truth corpus through the LIVE pipeline.

parser-eval proves extraction (the right items/amounts come out of the transcript);
this proves PRICING: the kcal a user sees for a spoken meal lands inside a
generously-banded ground-truth range (fixtures/calorie_corpus.json). A failure here
is a real accuracy bug — dictionary gap, resolution routing, estimator drift, or
compose misfire — not noise.

Needs a dev server with LIVE providers (TEST_MODE off; the fixture parser only knows
recorded transcripts):

    cd services/api && FORCE_OFFLINE=true DEV_ENDPOINTS=true DEBUG=true TEST_MODE=false \
        uv run uvicorn api.main:app --port 8001

Run:  scripts/calorie-eval [--url http://127.0.0.1:8001] [--only SUBSTR] [-j N]

Estimates are durably cached by the server (usda_cache), so re-runs are cheap while
the server stays up. Results: .tmp/calorie-eval.json + a console table; exit 1 on
any failure (regression-gate style, like parser-eval).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from pathlib import Path
from typing import Any

import httpx

_REPO = Path(__file__).resolve().parents[3]
_CORPUS = Path(__file__).parent / "fixtures" / "calorie_corpus.json"
_OUT = _REPO / ".tmp" / "calorie-eval.json"

_WATER_NAMES = ("water", "h2o")
_GRAMS_PER_OZ = 28.3495


def _is_water(item: dict[str, Any]) -> bool:
    name = (item.get("name") or "").lower()
    return any(w in name for w in _WATER_NAMES) and (item.get("macros") or {}).get("kcal", 1) == 0


async def _run_case(client: httpx.AsyncClient, case: dict[str, Any]) -> dict[str, Any]:
    text = case["text"]
    lo, hi = case["total"]
    started = time.monotonic()
    try:
        resp = await client.post(
            "/__dev/capture",
            json={"text": text, "email": "dev@vo-cal.test"},
            timeout=180,
        )
        resp.raise_for_status()
        parse = resp.json()["parse"]
    except Exception as exc:
        return {"text": text, "ok": False, "error": str(exc)[:200], "ms": _ms(started)}

    total = float(parse["totals"]["kcal"])
    items = parse["items"]
    failures: list[str] = []
    if not (lo <= total <= hi):
        failures.append(f"total {total:.0f} kcal outside [{lo}, {hi}]")

    if "water_oz" in case:
        w_lo, w_hi = case["water_oz"]
        water_items = [i for i in items if _is_water(i)]
        if not water_items:
            failures.append("no zero-kcal water item in parse")
        else:
            grams = sum(float(i.get("grams") or 0) for i in water_items)
            oz = grams / _GRAMS_PER_OZ
            if not (w_lo * 0.85 <= oz <= w_hi * 1.15):
                failures.append(f"water {oz:.1f} oz outside [{w_lo}, {w_hi}]")

    return {
        "text": text,
        "ok": not failures,
        "total_kcal": round(total, 1),
        "expected": [lo, hi],
        "failures": failures,
        "items": [
            {
                "name": i["name"],
                "kcal": round(float(i["macros"]["kcal"]), 1),
                "grams": i.get("grams"),
                "source": i.get("source"),
            }
            for i in items
        ],
        "certainty": (parse.get("certainty") or {}).get("score"),
        "ms": _ms(started),
    }


def _ms(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


async def _main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8001")
    ap.add_argument("--only", default=None, help="run only cases whose text contains this")
    ap.add_argument("-j", "--jobs", type=int, default=4)
    args = ap.parse_args()

    cases = json.loads(_CORPUS.read_text())["cases"]
    if args.only:
        cases = [c for c in cases if args.only.lower() in c["text"].lower()]
    if not cases:
        print("no cases matched")
        return 2

    async with httpx.AsyncClient(base_url=args.url) as client:
        try:
            health = await client.get("/health", timeout=5)
            health.raise_for_status()
            pre = await client.get("/__dev/preflight", timeout=10)
            parse_check = pre.json()["checks"]["parse_provider"]
            if parse_check.get("fake"):
                print("REFUSING: server parse provider is the recorded-fixture fake "
                      "(TEST_MODE?) — corpus texts would all miss. Start a live server.")
                return 2
        except Exception as exc:
            print(f"REFUSING: no healthy dev server at {args.url}: {exc}")
            return 2

        sem = asyncio.Semaphore(args.jobs)

        async def bounded(case: dict[str, Any]) -> dict[str, Any]:
            async with sem:
                return await _run_case(client, case)

        results = await asyncio.gather(*(bounded(c) for c in cases))

    passed = [r for r in results if r["ok"]]
    failed = [r for r in results if not r["ok"]]
    for r in failed:
        print(f"\nFAIL  {r['text']!r}")
        for f in r.get("failures", []) or [r.get("error", "?")]:
            print(f"      - {f}")
        for i in r.get("items", []):
            print(f"        {i['name']!r}: {i['kcal']} kcal / {i['grams']} g ({i['source']})")

    lat = sorted(r["ms"] for r in results)
    p50 = lat[len(lat) // 2]
    p95 = lat[min(len(lat) - 1, int(len(lat) * 0.95))]
    print(f"\nCALORIE-EVAL: {len(passed)}/{len(results)} passed | latency p50 {p50}ms p95 {p95}ms")

    _OUT.parent.mkdir(exist_ok=True)
    _OUT.write_text(json.dumps({"passed": len(passed), "failed": len(failed), "results": results}, indent=1))
    print(f"results -> {_OUT.relative_to(_REPO)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(_main()))
