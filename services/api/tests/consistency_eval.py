"""Consistency harness: the SAME food, said several reasonable ways, must price the same.

calorie-eval proves each utterance lands inside an honest band; this proves the property
Lorenzo and Francesco actually trust (2026-09-23): several phrasings of ONE food agree with
each other (within 15% of the group median) AND sit inside the band, and a manual amount
edit on the sheet re-prices the same food (the ``refine`` step below runs the real
/parse/refine through /__dev/refine). Groups live in fixtures/consistency_groups.json.

Needs the same LIVE dev server as calorie-eval (TEST_MODE off):

    cd services/api && FORCE_OFFLINE=true DEV_ENDPOINTS=true DEBUG=true TEST_MODE=false \
        uv run uvicorn api.main:app --port 8001

Run:  scripts/consistency-eval [--url http://127.0.0.1:8001] [--only SUBSTR]

Results: .tmp/consistency-eval.json + a console table; exit 1 on any failure.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import sys
import time
from pathlib import Path
from typing import Any

import httpx

_REPO = Path(__file__).resolve().parents[3]
_GROUPS = Path(__file__).parent / "fixtures" / "consistency_groups.json"
_OUT = _REPO / ".tmp" / "consistency-eval.json"

# "Within 15% of each other": every phrasing's total sits within this fraction of the
# group median. Wide enough for a 4 oz vs 5.3 oz cup to differ legitimately, tight enough
# that two different FOODS (apple vs apple crisp: 3x) can never pass.
TOLERANCE = 0.15


async def _price(client: httpx.AsyncClient, step: dict[str, Any]) -> dict[str, Any]:
    text = step["text"]
    started = time.monotonic()
    resp = await client.post(
        "/__dev/capture", json={"text": text, "email": "dev@vo-cal.test", "confirm": False},
        timeout=180,
    )
    resp.raise_for_status()
    parse = resp.json()["parse"]
    refine = step.get("refine")
    if refine:
        resp = await client.post(
            "/__dev/refine",
            json={"parse_id": parse["parse_id"], "answers": [refine]},
            timeout=180,
        )
        resp.raise_for_status()
        parse = resp.json()
    return {
        "text": text + (f"  [edit {refine['field']} = {refine['value']}]" if refine else ""),
        "total_kcal": round(float(parse["totals"]["kcal"]), 1),
        "items": [
            {
                "name": i["name"],
                "kcal": round(float(i["macros"]["kcal"]), 1),
                "grams": i.get("grams"),
                "source": i.get("source"),
                "identity": (i.get("identity") or {}).get("key"),
            }
            for i in parse["items"]
        ],
        "ms": int((time.monotonic() - started) * 1000),
    }


async def _run_group(client: httpx.AsyncClient, group: dict[str, Any]) -> dict[str, Any]:
    lo, hi = group["total"]
    try:
        results = await asyncio.gather(*(_price(client, s) for s in group["phrasings"]))
    except Exception as exc:
        return {"food": group["food"], "ok": False, "error": str(exc)[:200], "results": []}
    totals = [r["total_kcal"] for r in results]
    median = statistics.median(totals)
    failures: list[str] = []
    for r in results:
        if not (lo <= r["total_kcal"] <= hi):
            failures.append(f"{r['text']!r}: {r['total_kcal']:.0f} kcal outside [{lo}, {hi}]")
        if median > 0 and abs(r["total_kcal"] - median) > TOLERANCE * median:
            failures.append(
                f"{r['text']!r}: {r['total_kcal']:.0f} kcal is {abs(r['total_kcal'] - median) / median:.0%} "
                f"from the group median {median:.0f}"
            )
    return {
        "food": group["food"],
        "ok": not failures,
        "median": median,
        "expected": [lo, hi],
        "failures": failures,
        "results": results,
    }


async def _main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8001")
    ap.add_argument("--only", default=None, help="run only groups whose food contains this")
    args = ap.parse_args()

    groups = json.loads(_GROUPS.read_text())["groups"]
    if args.only:
        groups = [g for g in groups if args.only.lower() in g["food"].lower()]
    if not groups:
        print("no groups matched")
        return 2

    async with httpx.AsyncClient(base_url=args.url) as client:
        try:
            (await client.get("/health", timeout=5)).raise_for_status()
            pre = await client.get("/__dev/preflight", timeout=10)
            if pre.json()["checks"]["parse_provider"].get("fake"):
                print("REFUSING: server parse provider is the recorded-fixture fake "
                      "(TEST_MODE?) — start a live server.")
                return 2
        except Exception as exc:
            print(f"REFUSING: no healthy dev server at {args.url}: {exc}")
            return 2
        reports = [await _run_group(client, g) for g in groups]

    for rep in reports:
        mark = "ok  " if rep["ok"] else "FAIL"
        print(f"\n{mark} {rep['food']}  (band {rep.get('expected')}, median {rep.get('median')})")
        for r in rep["results"]:
            items = "; ".join(f"{i['name']}={i['kcal']}/{i['grams']}g ({i['source']}: {i['identity']})" for i in r["items"])
            print(f"      {r['total_kcal']:>7.1f}  {r['text']!r}  <- {items}")
        for f in rep.get("failures", []) or ([rep["error"]] if rep.get("error") else []):
            print(f"      - {f}")

    passed = sum(1 for r in reports if r["ok"])
    print(f"\nCONSISTENCY-EVAL: {passed}/{len(reports)} groups passed")
    _OUT.parent.mkdir(exist_ok=True)
    _OUT.write_text(json.dumps({"passed": passed, "failed": len(reports) - passed, "groups": reports}, indent=1))
    print(f"results -> {_OUT.relative_to(_REPO)}")
    return 0 if passed == len(reports) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(_main()))
