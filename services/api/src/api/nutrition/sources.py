"""Domain allowlist for web-search grounding on branded/restaurant foods.

Two tiers: each chain's own official nutrition domain(s) (highest trust — the
brand's own label data) and a shared list of trusted nutrition-database
aggregators used as a fallback for anything not in the restaurant map. Every
entry is a bare registrable domain — no scheme, no path, no "www." — so it can
be passed straight to a search tool's domain-allowlist parameter.
"""

from __future__ import annotations

import re

# US chain -> its official nutrition/menu domain(s), verified July 2026. Some
# brands split nutrition info onto a dedicated asset host (e.g. Whataburger's
# PDF lives on a separate image server) — both are listed where that's real.
RESTAURANT_DOMAINS: dict[str, tuple[str, ...]] = {
    "mcdonalds": ("mcdonalds.com",),
    "burger king": ("bk.com",),
    "wendys": ("wendys.com",),
    "chick-fil-a": ("chick-fil-a.com",),
    "chipotle": ("chipotle.com",),
    "dunkin": ("dunkindonuts.com", "dunkin.com"),
    "starbucks": ("starbucks.com",),
    "taco bell": ("tacobell.com",),
    "subway": ("subway.com",),
    "panera": ("panerabread.com",),
    "popeyes": ("popeyes.com",),
    "raising canes": ("raisingcanes.com",),
    "five guys": ("fiveguys.com",),
    "in-n-out": ("in-n-out.com",),
    "kfc": ("kfc.com",),
    "arbys": ("arbys.com",),
    "sonic": ("sonicdrivein.com",),
    "jimmy johns": ("jimmyjohns.com",),
    "jersey mikes": ("jerseymikes.com", "subs.jerseymikes.com"),
    "culvers": ("culvers.com",),
    "whataburger": ("whataburger.com", "wbimageserver.whataburger.com"),
    "shake shack": ("shakeshack.com",),
    "dominos": ("dominos.com",),
    "pizza hut": ("pizzahut.com",),
    "papa johns": ("papajohns.com",),
    "panda express": ("pandaexpress.com",),
    "dairy queen": ("dairyqueen.com",),
    "wingstop": ("wingstop.com",),
}

# General nutrition databases — trusted fallback for any branded/packaged food,
# whether or not it matched a chain above.
AGGREGATOR_DOMAINS: tuple[str, ...] = (
    "nutritionix.com",
    "fatsecret.com",
    "myfitnesspal.com",
    "eatthismuch.com",
    "fastfoodnutrition.org",
    "usda.gov",
    "fdc.nal.usda.gov",
    "calorieking.com",

    "myfooddiary.com",
    "cronometer.com",
)

_NON_ALNUM_RE = re.compile(r"[^a-z0-9]")


def _normalize(value: str) -> str:
    """Lowercase, alnum-only — so "McDonald's", "mcdonald's", and the dict key
    "mcdonalds" all collapse to the same string regardless of punctuation/case."""
    return _NON_ALNUM_RE.sub("", value.lower())


def domains_for(brand: str | None) -> list[str]:
    """Official domain(s) for `brand` (if matched) + all aggregator domains, deduped.

    Matching is alnum-normalized and substring-based: the brand string collapses to
    letters/digits only, then each dict key (normalized the same way) is checked for
    containment. This catches both an exact brand name ("McDonald's") and a brand
    mentioned inside a longer string ("Dunkin' Donuts iced matcha"). Brand keys are
    specific enough that false-positive substring hits aren't a practical concern for
    this narrow allowlist. Falls back to aggregators only when brand is missing/blank
    or matches no known chain — never an empty list.
    """
    aggregators = list(AGGREGATOR_DOMAINS)
    if not brand:
        return aggregators
    normalized = _normalize(brand)
    if not normalized:
        return aggregators
    for key, domains in RESTAURANT_DOMAINS.items():
        if _normalize(key) in normalized:
            return [*domains, *(d for d in aggregators if d not in domains)]
    return aggregators
