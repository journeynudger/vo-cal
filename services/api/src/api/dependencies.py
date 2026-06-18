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

from .config import settings
from .db import SupportsDatabase
from .storage import SupportsStorage

# auto_error=False so the test-header path works without an Authorization header.
_bearer = HTTPBearer(auto_error=False)


def make_test_token(user_id: UUID | str) -> str:
    """Return the value tests pass in the ``X-Test-User`` header.

    Only honored when settings.test_mode and settings.debug are both true.
    """
    return str(user_id)


async def _verify_supabase_jwt(token: str) -> UUID:
    """Validate a Supabase JWT and return the user id (``sub`` claim).

    Phase F wires the real implementation: either ``client.auth.get_user(token)``
    against Supabase, or PyJWT verification with the project's JWKS/JWT secret.
    Until then this is a deliberate hard failure — a silently-permissive stub
    here would be a tenant-isolation hole that tests can't catch.
    """
    del token
    msg = "Supabase JWT verification lands in Phase F (auth). See docs/ARCHITECTURE.md."
    raise NotImplementedError(msg)


async def get_current_user(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)] = None,
) -> UUID:
    """Resolve the authenticated user's UUID, or 401."""
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
