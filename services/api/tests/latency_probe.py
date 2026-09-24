"""Where the seconds go in one spoken meal, measured live.

Requirement (Lorenzo, 2026-09-24): "it just takes forever to log my meal, figure out why and
cut the time as much as possible without losing accuracy." Production showed one eight-item
parse at 17.5 s (transcription 2.0 s). This probe times the two paid stages separately, per
transcript, against the real providers, and writes tests/fixtures/LATENCY.md:

  1. the parse LLM call (``parse_transcript``), per model, with the extracted items compared
     to the recorded fixture for that transcript (the corpus truth), so a faster model only
     counts if it extracts the same thing;
  2. resolution of the parsed items on a cold cache (``build_resolver`` with the estimator,
     FatSecret and USDA live), the slowest item named.

    scripts/latency-probe                              # both stages, the default models
    scripts/latency-probe --models claude-haiku-4-5    # one model
    scripts/latency-probe --no-resolve                 # the LLM stage only
    scripts/latency-probe --out .tmp/latency-before.md # keep a before/after pair

Needs ANTHROPIC_API_KEY (and, for resolution, FATSECRET_* and USDA_FDC_API_KEY) in the
environment; the wrapper exports them from .env. TEST_MODE must be off (the wrapper unsets it).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import sys
import time
from pathlib import Path

from api.db import FakeDatabase
from api.nutrition.build import build_resolver
from api.parser.llm import AnthropicParserClient, parse_transcript
from api.parser.router import resolve_with_composition

FIXTURES = Path(__file__).resolve().parent / "fixtures"
REPORT = FIXTURES / "LATENCY.md"

# The canonical four plus four shapes that hurt in the field: a long hedged breakfast, a
# composed sandwich, a branded restaurant meal, an oil-and-rice dinner.
TRANSCRIPTS = [
    "4oz 93/7 beef",
    "200g cooked jasmine rice",
    "Chipotle bowl, double chicken, white rice, mild salsa, light cheese",
    "burger, unknown beef, regular cheddar, mayo",
    "yeah for breakfast I think I had oatmeal, maybe a cup, with a scoop of protein powder",
    "logging lunch, a turkey sandwich and an apple",
    "I had a Big Mac and a Sprite",
    "for dinner I had 6oz grilled chicken breast, a cup of white rice, and a tablespoon of olive oil",
]

DEFAULT_MODELS = ("claude-sonnet-4-6", "claude-haiku-4-5")


def _recorded(transcript: str) -> list[tuple] | None:
    key = " ".join(transcript.lower().split())
    for path in (FIXTURES / "llm_responses").glob("*.json"):
        data = json.loads(path.read_text())
        if " ".join(data["transcript"].lower().split()) == key:
            return [_shape(i) for i in data["tool_input"]["items"]]
    return None


def _shape(item: dict) -> tuple:
    return (
        str(item.get("name") or "").lower().strip(),
        item.get("amount"),
        item.get("unit"),
        item.get("state") or "unspecified",
        item.get("fat_ratio"),
    )


async def _time_parse(model: str, transcript: str) -> tuple[float, list[tuple], str | None]:
    client = AnthropicParserClient(model=model)
    started = time.perf_counter()
    try:
        meal, _, _ = await parse_transcript(client, transcript)
    except Exception as exc:
        return (time.perf_counter() - started) * 1000, [], f"{type(exc).__name__}: {exc}"[:80]
    return (time.perf_counter() - started) * 1000, [_shape(i.model_dump(mode="json")) for i in meal.items], None


async def _time_resolution(transcript: str) -> tuple[float, str, int]:
    """Cold-cache resolution of the transcript's items: wall-clock, slowest item, item count."""
    client = AnthropicParserClient()
    meal, _, _ = await parse_transcript(client, transcript)
    resolver = build_resolver(FakeDatabase(), estimate_unknowns=True)
    per_item: dict[str, float] = {}

    async def timed(item):
        t = time.perf_counter()
        try:
            await resolver.resolve_item(item)
        finally:
            per_item[item.name] = (time.perf_counter() - t) * 1000

    started = time.perf_counter()
    await asyncio.gather(*(timed(i) for i in meal.items))
    wall = (time.perf_counter() - started) * 1000
    slowest = max(per_item, key=per_item.get) if per_item else "-"
    # The composed path is what /parse runs; time it too so the report shows the real stage.
    started = time.perf_counter()
    await resolve_with_composition(build_resolver(FakeDatabase(), estimate_unknowns=True), meal.items, transcript)
    composed = (time.perf_counter() - started) * 1000
    return max(wall, composed), f"{slowest} ({per_item.get(slowest, 0):.0f} ms)", len(meal.items)


def _p(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(q * (len(ordered) - 1)))]


async def run(models: list[str], resolve: bool, out: Path) -> int:
    lines = ["# Latency, measured", "", f"{len(TRANSCRIPTS)} transcripts, live providers, cold caches. Times in milliseconds.", ""]
    lines += ["## The parse call, per model", "", "| Transcript | " + " | ".join(models) + " |", "|---|" + "---|" * len(models)]
    totals: dict[str, list[float]] = {m: [] for m in models}
    agree: dict[str, int] = dict.fromkeys(models, 0)
    for transcript in TRANSCRIPTS:
        truth = _recorded(transcript)
        cells = []
        for model in models:
            ms, shapes, error = await _time_parse(model, transcript)
            totals[model].append(ms)
            if error:
                cells.append(f"{ms:.0f} ({error})")
                continue
            same = truth is not None and shapes == truth
            names_same = truth is not None and [s[0] for s in shapes] == [s[0] for s in truth]
            agree[model] += int(same)
            mark = "same" if same else ("same names" if names_same else "differs")
            cells.append(f"{ms:.0f} ({mark})")
        lines.append(f"| {transcript[:60]} | " + " | ".join(cells) + " |")
    lines += ["", "| Model | p50 | p95 | Extraction equal to the recorded fixture |", "|---|---|---|---|"]
    for model in models:
        lines.append(f"| {model} | {statistics.median(totals[model]):.0f} | {_p(totals[model], 0.95):.0f} | {agree[model]}/{len(TRANSCRIPTS)} |")

    if resolve:
        lines += ["", "## Resolution on a cold cache (the ladder with the estimator, FatSecret and USDA live)", "",
                  "| Transcript | Items | Wall-clock | Slowest item |", "|---|---|---|---|"]
        walls: list[float] = []
        for transcript in TRANSCRIPTS:
            try:
                wall, slowest, count = await _time_resolution(transcript)
            except Exception as exc:
                lines.append(f"| {transcript[:60]} | - | failed | {type(exc).__name__} |")
                continue
            walls.append(wall)
            lines.append(f"| {transcript[:60]} | {count} | {wall:.0f} | {slowest} |")
        if walls:
            lines += ["", f"Resolution p50 {statistics.median(walls):.0f} ms, p95 {_p(walls, 0.95):.0f} ms, max {max(walls):.0f} ms."]

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"report: {out}")
    return 0


def _every_recorded_transcript() -> list[str]:
    """Every transcript in the recorded corpus, for a model decision that rests on more than
    eight utterances (``--all``; the parse stage only, resolution is per-transcript cost)."""
    out: list[str] = []
    for path in sorted((FIXTURES / "llm_responses").glob("*.json")):
        out.append(json.loads(path.read_text())["transcript"])
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--models", default=",".join(DEFAULT_MODELS))
    parser.add_argument("--no-resolve", action="store_true")
    parser.add_argument("--all", action="store_true", help="every recorded transcript, parse stage only")
    parser.add_argument("--out", type=Path, default=REPORT)
    args = parser.parse_args()
    if args.all:
        TRANSCRIPTS[:] = _every_recorded_transcript()
        args.no_resolve = True
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY is not set", file=sys.stderr)
        return 2
    return asyncio.run(run([m.strip() for m in args.models.split(",") if m.strip()], not args.no_resolve, args.out))


if __name__ == "__main__":
    sys.exit(main())
