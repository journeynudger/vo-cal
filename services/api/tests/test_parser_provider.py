"""The parser provider follows the model id (parser/llm.py provider_for).

Why this is pinned: production ran PARSER_PROVIDER=openai when PARSER_MODEL moved to
claude-haiku-4-5 (2026-09-24, Deploy run 36053036184) and every POST /parse answered 500
with OpenAI's model_not_found until the smoke stage caught it. The id names its family, so
the family decides; the provider setting only settles ids without one.
"""

import pytest

from api.config import settings
from api.parser.llm import (
    AnthropicParserClient,
    FakeParserClient,
    OpenAIParserClient,
    provider_for,
)
from api.parser.router import get_parser_client


@pytest.mark.parametrize(
    ("model", "configured", "expected"),
    [
        ("claude-haiku-4-5", "openai", "anthropic"),
        ("claude-sonnet-4-6", "anthropic", "anthropic"),
        ("gpt-4o-mini", "anthropic", "openai"),
        ("o4-mini", "gemini", "openai"),
        ("gemini-2.5-flash", "openai", "gemini"),
        ("my-gateway-alias", "openai", "openai"),
        ("my-gateway-alias", "Anthropic ", "anthropic"),
        ("my-gateway-alias", None, ""),
        ("  Claude-Haiku-4-5 ", "gemini", "anthropic"),
    ],
)
def test_the_model_family_decides_the_provider(model, configured, expected):
    assert provider_for(model, configured) == expected


def _live(monkeypatch, *, provider, model, anthropic="sk-ant", openai="sk-openai"):
    monkeypatch.setattr(settings, "test_mode", False)
    monkeypatch.setattr(settings, "parser_provider", provider)
    monkeypatch.setattr(settings, "parser_model", model)
    monkeypatch.setattr(settings, "anthropic_api_key", anthropic)
    monkeypatch.setattr(settings, "openai_api_key", openai)


def test_a_claude_model_beats_an_openai_provider_setting(monkeypatch):
    _live(monkeypatch, provider="openai", model="claude-haiku-4-5")
    assert isinstance(get_parser_client(), AnthropicParserClient)


def test_an_openai_model_beats_an_anthropic_provider_setting(monkeypatch):
    _live(monkeypatch, provider="anthropic", model="gpt-4o-mini")
    assert isinstance(get_parser_client(), OpenAIParserClient)


def test_a_family_without_its_key_falls_back_to_the_fake(monkeypatch):
    # Fails open, as services/api/fly.toml documents for every missing secret.
    _live(monkeypatch, provider="openai", model="claude-haiku-4-5", anthropic="")
    assert isinstance(get_parser_client(), FakeParserClient)
