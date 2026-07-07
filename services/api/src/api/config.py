"""Application settings (pydantic-settings).

All fields have safe empty defaults so the app boots — and the test suite runs —
with no environment at all (offline edit loop). Real values come from the repo-root
`.env` in local dev and from deployment secrets in production.
"""

import logging
from pathlib import Path

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_logger = logging.getLogger(__name__)

# Repo-root .env for LOCAL dev (services/api/src/api/config.py → 4 levels up). In the Docker
# image the package lives at /app/src/api (shallower), so parents[4] is out of range — guard it
# and fall back to None, which is correct in prod anyway: there is no .env, config comes from real
# env vars / Fly secrets. (A bare parents[4] crashed the container on boot with IndexError.)
_parents = Path(__file__).resolve().parents
_ENV_FILE = _parents[4] / ".env" if len(_parents) > 4 else None


class Settings(BaseSettings):
    # Supabase
    supabase_url: str = ""
    supabase_anon_key: str = ""
    supabase_service_role_key: str = ""
    # Supabase access-token audience (the standard GoTrue value). auth.py verifies it
    # against the project JWKS; rarely changed.
    supabase_jwt_audience: str = "authenticated"

    # LLM (parser + why layer). Provider-pluggable: "gemini" (free tier, default for
    # the beta), "anthropic", or "openai". The deterministic engine still owns every
    # number; the model only extracts structured items (AGENTS.md #6), so the provider
    # is swappable. PARSER_MODEL picks the model within whichever provider is selected.
    parser_provider: str = "anthropic"
    parser_model: str = "claude-sonnet-4-6"
    anthropic_api_key: str = ""
    gemini_api_key: str = ""
    openai_api_key: str = ""

    # Transcription
    elevenlabs_api_key: str = ""

    # Nutrition
    usda_fdc_api_key: str = ""

    # API
    debug: bool = False
    cors_origins: list[str] = ["http://localhost:3000"]

    # Test seam: when True (and debug), the auth dependency trusts the
    # X-Test-User header instead of validating a JWT. Never set in production;
    # the conftest flips it explicitly. See dependencies.get_current_user.
    test_mode: bool = False

    # Agent skeleton keys: mounts the /__dev router (dev/router.py) — log-me-in,
    # mic-less capture, preflight, db summary. LOCAL ONLY: main.py refuses to boot
    # with this set against a hosted database, and the router is simply absent
    # (404s) when unset. Set via env DEV_ENDPOINTS=true (ensure-dev-server.sh does).
    dev_endpoints: bool = False

    # Force the in-memory fakes (FakeDatabase/FakeStorage) even when real Supabase creds
    # exist in .env. Needed because env_ignore_empty=True means a dev script CANNOT blank
    # the hosted URL via empty env vars — the .env value wins and the dev-seam boot guards
    # (correctly) refuse to start. FORCE_OFFLINE=true is the explicit, greppable way to run
    # the API with zero external state (nothing persists; /__dev/preflight says so).
    force_offline: bool = False

    # Admin allowlist (Phase H, decisions #21/#25): emails permitted to call
    # /admin/* routes. Empty by default so no one is admin unless explicitly
    # configured. Set via the CSV env var ADMIN_EMAILS=a@x.com,b@y.com; the
    # validator below also tolerates a JSON list. Enforced server-side only —
    # the service-role key never leaves the API (dependencies.require_admin).
    admin_emails: list[str] = []

    @field_validator("admin_emails", mode="before")
    @classmethod
    def _split_admin_emails(cls, value: object) -> object:
        # Accept a plain CSV string (ADMIN_EMAILS=a@x.com,b@y.com) in addition
        # to pydantic-settings' default JSON-list parsing. Emails are lowercased
        # and trimmed so the comparison in require_admin is case-insensitive.
        if isinstance(value, str) and not value.strip().startswith("["):
            return [e.strip().lower() for e in value.split(",") if e.strip()]
        if isinstance(value, list):
            return [str(e).strip().lower() for e in value if str(e).strip()]
        return value

    model_config = SettingsConfigDict(
        env_file=_ENV_FILE if (_ENV_FILE and _ENV_FILE.exists()) else None,
        env_ignore_empty=True,
        extra="ignore",
    )

    def model_post_init(self, __context) -> None:
        if self.supabase_url and not self.supabase_url.startswith("http://127.0.0.1"):
            _logger.warning("Using non-local Supabase: %s", self.supabase_url)


settings = Settings()
