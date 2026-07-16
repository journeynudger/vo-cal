"""Web-search grounding domain allowlist — brand matching + aggregator fallback."""

from __future__ import annotations

from api.nutrition.sources import AGGREGATOR_DOMAINS, RESTAURANT_DOMAINS, domains_for


def test_mcdonalds_apostrophe_and_lowercase_both_match():
    expected = [*RESTAURANT_DOMAINS["mcdonalds"], *AGGREGATOR_DOMAINS]
    assert domains_for("McDonald's") == expected
    assert domains_for("mcdonald's") == expected


def test_dunkin_resolves_to_its_own_domains():
    result = domains_for("Dunkin")
    assert result[: len(RESTAURANT_DOMAINS["dunkin"])] == list(RESTAURANT_DOMAINS["dunkin"])
    for domain in AGGREGATOR_DOMAINS:
        assert domain in result


def test_unknown_brand_returns_only_aggregators():
    assert domains_for("Some Random Diner Nobody Has Heard Of") == list(AGGREGATOR_DOMAINS)


def test_none_returns_only_aggregators():
    assert domains_for(None) == list(AGGREGATOR_DOMAINS)
