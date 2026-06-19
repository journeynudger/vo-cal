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

# Repo root .env (services/api/src/api/config.py → four levels up).
_ENV_FILE = Path(__file__).resolve().parents[4] / ".env"


class Settings(BaseSettings):
    # Supabase
    supabase_url: str = ""
    supabase_anon_key: str = ""
    supabase_service_role_key: str = ""

    # LLM (parser + why layer)
    anthropic_api_key: str = ""
    parser_model: str = "claude-sonnet-4-6"

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
        env_file=_ENV_FILE if _ENV_FILE.exists() else None,
        env_ignore_empty=True,
        extra="ignore",
    )

    def model_post_init(self, __context) -> None:
        if self.supabase_url and not self.supabase_url.startswith("http://127.0.0.1"):
            _logger.warning("Using non-local Supabase: %s", self.supabase_url)


settings = Settings()
