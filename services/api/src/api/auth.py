"""Supabase JWT verification (Phase F auth).

Supabase issues asymmetric access tokens (this project signs ES256; RS256 is also
accepted) using the project's JWT signing keys, published as a JWKS at
``{SUPABASE_URL}/auth/v1/.well-known/jwks.json``. We verify the token signature
against that JWKS — cached, and refetched once on an unknown ``kid`` so key
rotation self-heals — plus issuer, audience, and expiry. The ``sub`` claim is the
user's UUID, which becomes the RLS scope for every store.

Verifying the SIGNATURE is non-negotiable: trusting an unverified ``sub`` would let
any client impersonate any user and defeat tenant isolation (AGENTS.md #7). The
verifier is constructed once from settings; the JWKS HTTP fetch is async (httpx) so
it never blocks the event loop, and is injectable so the offline suite verifies real
tokens against a fixed test key with zero network.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from uuid import UUID

import httpx
import jwt
from jwt import PyJWKSet

logger = logging.getLogger(__name__)


class JWTVerificationError(Exception):
    """A token failed signature/claims verification (maps to 401 at the boundary)."""


class SupabaseJWTVerifier:
    def __init__(
        self,
        *,
        issuer: str,
        jwks_url: str,
        audience: str = "authenticated",
        algorithms: tuple[str, ...] = ("ES256", "RS256"),
        cache_ttl_seconds: float = 600.0,
        jwks: PyJWKSet | None = None,
        http_client_factory: Callable[[], httpx.AsyncClient] | None = None,
    ) -> None:
        self._issuer = issuer
        self._jwks_url = jwks_url
        self._audience = audience
        self._algorithms = list(algorithms)
        self._ttl = cache_ttl_seconds
        # A static set (tests) is authoritative and never fetched. Otherwise we cache the
        # fetched set with a TTL and refetch on an unknown kid (rotation).
        self._static = jwks
        self._cached: PyJWKSet | None = jwks
        self._fetched_at = 0.0
        self._client_factory = http_client_factory or (lambda: httpx.AsyncClient(timeout=5.0))

    async def _jwks_set(self, *, force: bool = False) -> PyJWKSet:
        if self._static is not None:
            return self._static
        now = time.monotonic()
        if not force and self._cached is not None and (now - self._fetched_at) < self._ttl:
            return self._cached
        async with self._client_factory() as client:
            resp = await client.get(self._jwks_url)
            resp.raise_for_status()
            data = resp.json()
        self._cached = PyJWKSet.from_dict(data)
        self._fetched_at = now
        return self._cached

    @staticmethod
    def _key_for(jwks: PyJWKSet, kid: str) -> object | None:
        for key in jwks.keys:
            if key.key_id == kid:
                return key.key
        return None

    async def verify(self, token: str) -> UUID:
        try:
            kid = jwt.get_unverified_header(token).get("kid")
        except jwt.PyJWTError as exc:
            raise JWTVerificationError(f"malformed token header: {exc}") from exc
        # Supabase always stamps a kid; a token without one can't be matched to a specific
        # signing key, so reject rather than guess the first key (avoids a rotation-confusion
        # verification against the wrong key).
        if not kid:
            raise JWTVerificationError("token header has no kid")

        key = self._key_for(await self._jwks_set(), kid)
        if key is None:
            # Unknown kid — keys may have rotated; refetch once before giving up.
            key = self._key_for(await self._jwks_set(force=True), kid)
        if key is None:
            raise JWTVerificationError(f"no signing key for kid={kid!r}")

        try:
            claims = jwt.decode(
                token,
                key,
                algorithms=self._algorithms,
                audience=self._audience,
                issuer=self._issuer,
                # Small clock-skew tolerance so a freshly-issued token from a slightly-ahead
                # client isn't rejected as not-yet-valid (iat/nbf). 60s is the conventional
                # allowance; exp is still enforced (just not to the millisecond).
                leeway=60,
                options={"require": ["exp", "sub"]},
            )
        except jwt.PyJWTError as exc:
            raise JWTVerificationError(f"token rejected: {exc}") from exc

        sub = claims.get("sub")
        try:
            return UUID(str(sub))
        except (ValueError, TypeError) as exc:
            raise JWTVerificationError(f"sub is not a uuid: {sub!r}") from exc
