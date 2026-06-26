"""FastAPI dependencies — auth and database access.

Auth design (Beacon's JWT-dep shape, adapted for offline testability):

- **Test path:** when ``settings.test_mode`` AND ``settings.debug`` are both
  true, the dependency trusts an ``X-Test-User`` header carrying a user UUID.
  Both flags are off by default and only the test conftest flips them, so the
  trusted-header path cannot be reached in a default-configured deployment.
- **Live path:** Supabase JWT validation. Stubbed until Phase F wires real
  auth — see ``_verify_supabase_jwt``. Decoding without signature verification
  is NOT an acceptable interim: an unverified ``sub`` claim would let any
  client impersonate any user, defeating RLS and tenant isolation.
"""

from typing import Annotated
from uuid import UUID

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .auth import JWTVerificationError, SupabaseJWTVerifier
from .config import settings
from .db import SupportsDatabase
from .logging_config import user_id_var
from .storage import SupportsStorage

# auto_error=False so the test-header path works without an Authorization header.
_bearer = HTTPBearer(auto_error=False)

# Built once from settings on first authenticated request; the JWKS inside is fetched
# lazily and cached. Empty until configured (no Supabase URL ⇒ live auth unavailable).
# A 1-slot dict (not a rebindable module global) so the cache mutates without `global`.
_jwt_verifier_cache: dict[str, SupabaseJWTVerifier] = {}


def _get_jwt_verifier() -> SupabaseJWTVerifier | None:
    if not settings.supabase_url:
        return None
    verifier = _jwt_verifier_cache.get("default")
    if verifier is None:
        base = settings.supabase_url.rstrip("/")
        verifier = SupabaseJWTVerifier(
            issuer=f"{base}/auth/v1",
            jwks_url=f"{base}/auth/v1/.well-known/jwks.json",
            audience=settings.supabase_jwt_audience,
        )
        _jwt_verifier_cache["default"] = verifier
    return verifier


def make_test_token(user_id: UUID | str) -> str:
    """Return the value tests pass in the ``X-Test-User`` header.

    Only honored when settings.test_mode and settings.debug are both true.
    """
    return str(user_id)


async def _verify_supabase_jwt(token: str) -> UUID:
    """Validate a Supabase JWT and return the user id (``sub`` claim).

    Verifies the signature against the project JWKS plus issuer/audience/expiry
    (see auth.py). Any failure raises 401 — never a permissive fallback, which
    would be a tenant-isolation hole (AGENTS.md #7). A 503 means the server has no
    Supabase URL configured, so live auth can't run at all (distinct from a bad
    token).
    """
    verifier = _get_jwt_verifier()
    if verifier is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Auth is not configured (no Supabase URL).",
        )
    try:
        return await verifier.verify(token)
    except JWTVerificationError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
        ) from exc


async def get_current_user(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)] = None,
) -> UUID:
    """Resolve the authenticated user's UUID, or 401."""
    user_id = await _resolve_current_user(request, credentials)
    # Record the VERIFIED id for log correlation. The access-log middleware reads this
    # contextvar instead of the unverified token sub, so the audit trail can never carry
    # an attacker-forged id (C3).
    user_id_var.set(str(user_id))
    return user_id


async def _resolve_current_user(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None,
) -> UUID:
    if settings.test_mode and settings.debug:
        test_user = request.headers.get("x-test-user")
        if test_user:
            try:
                return UUID(test_user)
            except ValueError as e:
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="Invalid X-Test-User header",
                ) from e

    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing authentication credentials",
        )

    return await _verify_supabase_jwt(credentials.credentials)


def get_db(request: Request) -> SupportsDatabase:
    """The app-wide database seam, set on app.state by the lifespan."""
    return request.app.state.db


def get_storage(request: Request) -> SupportsStorage:
    """The app-wide object-storage seam, set on app.state by the lifespan."""
    return request.app.state.storage


CurrentUser = Annotated[UUID, Depends(get_current_user)]
Db = Annotated[SupportsDatabase, Depends(get_db)]
Storage = Annotated[SupportsStorage, Depends(get_storage)]


# -- admin gate (Phase H, decisions #21/#25) ---------------------------------
# Admin access = an authenticated user whose email is on the server-side
# allowlist (settings.admin_emails). The service-role key never leaves the API;
# this dependency is the only door to /admin/*. Non-allowlisted users get 403.


async def require_admin(
    request: Request,
    user_id: CurrentUser,
    db: Db,
) -> str:
    """Resolve the caller's admin email, or 403.

    Returns the admin's email (used as the audit-trail ``reviewer`` /
    ``admin_email``). Resolution order:

    - **Test path:** when ``test_mode`` AND ``debug``, trust an ``X-Test-Admin``
      header carrying the email — mirrors the ``X-Test-User`` seam so the gate
      is provable offline. Both flags are off outside the conftest.
    - **Live path:** look up the user's ``profiles.email`` (service-role read).

    The resolved email must be in ``settings.admin_emails`` (case-insensitive),
    which is empty by default — so absent configuration, no one is admin.
    """
    email: str | None = None
    if settings.test_mode and settings.debug:
        header_email = request.headers.get("x-test-admin")
        if header_email:
            email = header_email.strip().lower()

    if email is None:
        rows = await db.select("profiles", {"id": str(user_id)})
        profile_email = rows[0].get("email") if rows else None
        email = profile_email.strip().lower() if profile_email else None

    if not email or email not in settings.admin_emails:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin access required",
        )
    return email


AdminUser = Annotated[str, Depends(require_admin)]
