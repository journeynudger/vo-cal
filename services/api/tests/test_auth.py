"""Supabase JWT verification (Phase F) — offline, against a fixed test signing key.

Generates an ES256 keypair, publishes the public half as a JWKS the verifier trusts,
and mints tokens to prove the security properties: a good token yields the sub UUID;
expired / wrong-audience / wrong-issuer / wrong-key / non-uuid-sub / unknown-kid are all
rejected. No network — the static JWKS short-circuits the fetch.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from jwt import PyJWKSet
from jwt.algorithms import ECAlgorithm

from api.auth import JWTVerificationError, SupabaseJWTVerifier

ISSUER = "https://proj.supabase.co/auth/v1"
AUDIENCE = "authenticated"
KID = "test-key-1"


def _keypair_and_jwks() -> tuple[ec.EllipticCurvePrivateKey, PyJWKSet]:
    priv = ec.generate_private_key(ec.SECP256R1())
    jwk = ECAlgorithm.to_jwk(priv.public_key(), as_dict=True)
    jwk.update({"kid": KID, "use": "sig", "alg": "ES256"})
    return priv, PyJWKSet.from_dict({"keys": [jwk]})


def _token(
    priv: ec.EllipticCurvePrivateKey,
    *,
    sub: str | None = None,
    aud: str = AUDIENCE,
    iss: str = ISSUER,
    exp_delta: int = 3600,
    kid: str | None = KID,
) -> tuple[str, str]:
    sub = sub or str(uuid4())
    now = datetime.now(UTC)
    payload = {
        "sub": sub,
        "aud": aud,
        "iss": iss,
        "iat": now,
        "exp": now + timedelta(seconds=exp_delta),
    }
    token = jwt.encode(payload, priv, algorithm="ES256", headers={"kid": kid} if kid else {})
    return token, sub


def _verifier(jwks: PyJWKSet) -> SupabaseJWTVerifier:
    return SupabaseJWTVerifier(
        issuer=ISSUER, jwks_url="https://unused.local", audience=AUDIENCE, jwks=jwks
    )


class _CountingClient:
    """Async-context httpx stand-in that counts GETs and serves a fixed JWKS dict."""

    def __init__(self, jwks_dict: dict, counter: list[int]) -> None:
        self._jwks = jwks_dict
        self._counter = counter

    async def __aenter__(self) -> _CountingClient:
        return self

    async def __aexit__(self, *_a: object) -> bool:
        return False

    async def get(self, _url: str) -> _CountingClient:
        self._counter[0] += 1
        return self

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict:
        return self._jwks


def _jwks_dict_with_kid(kid: str) -> dict:
    priv = ec.generate_private_key(ec.SECP256R1())
    jwk = ECAlgorithm.to_jwk(priv.public_key(), as_dict=True)
    jwk.update({"kid": kid, "use": "sig", "alg": "ES256"})
    return {"keys": [jwk]}


async def test_forced_jwks_refetch_is_rate_limited():
    # The unknown-kid path force-refetches the JWKS; a flood of bogus-kid tokens must not amplify
    # 1:1 into outbound fetches (auth-path DoS, RT-05). After one forced refetch, subsequent ones
    # within the cooldown serve the cache (no fetch).
    counter = [0]
    verifier = SupabaseJWTVerifier(
        issuer=ISSUER,
        jwks_url="https://unused.local",
        audience=AUDIENCE,
        forced_refetch_cooldown_seconds=60.0,
        http_client_factory=lambda: _CountingClient(_jwks_dict_with_kid("k"), counter),
    )
    await verifier._jwks_set()  # initial populate (fetch 1)
    await verifier._jwks_set(force=True)  # first forced refetch (fetch 2)
    await verifier._jwks_set(force=True)  # within cooldown → served from cache (no fetch)
    await verifier._jwks_set(force=True)  # still within cooldown → no fetch
    assert counter[0] == 2


async def test_valid_token_returns_sub_uuid():
    priv, jwks = _keypair_and_jwks()
    token, sub = _token(priv)
    assert str(await _verifier(jwks).verify(token)) == sub


async def test_expired_token_rejected():
    priv, jwks = _keypair_and_jwks()
    # Expired well beyond the 60s clock-skew leeway so this proves real expiry enforcement,
    # not the skew tolerance (see test_token_within_clock_skew_leeway_accepted).
    token, _ = _token(priv, exp_delta=-3600)
    with pytest.raises(JWTVerificationError):
        await _verifier(jwks).verify(token)


async def test_token_within_clock_skew_leeway_accepted():
    # A token issued by a slightly-ahead client (or barely expired) within the 60s leeway must
    # still verify — zero leeway spuriously 401s freshly-issued valid tokens (RT-27).
    priv, jwks = _keypair_and_jwks()
    token, _ = _token(priv, exp_delta=-5)  # expired 5s ago, inside the 60s allowance
    claims = await _verifier(jwks).verify(token)
    assert claims is not None


async def test_wrong_audience_rejected():
    priv, jwks = _keypair_and_jwks()
    token, _ = _token(priv, aud="anon")
    with pytest.raises(JWTVerificationError):
        await _verifier(jwks).verify(token)


async def test_wrong_issuer_rejected():
    priv, jwks = _keypair_and_jwks()
    token, _ = _token(priv, iss="https://evil.example/auth/v1")
    with pytest.raises(JWTVerificationError):
        await _verifier(jwks).verify(token)


async def test_signature_from_other_key_rejected():
    _, jwks = _keypair_and_jwks()
    other_priv, _ = _keypair_and_jwks()  # different private key, same advertised kid
    token, _ = _token(other_priv)
    with pytest.raises(JWTVerificationError):
        await _verifier(jwks).verify(token)


async def test_non_uuid_sub_rejected():
    priv, jwks = _keypair_and_jwks()
    token, _ = _token(priv, sub="not-a-uuid")
    with pytest.raises(JWTVerificationError):
        await _verifier(jwks).verify(token)


async def test_unknown_kid_rejected():
    priv, jwks = _keypair_and_jwks()
    token, _ = _token(priv, kid="rotated-away-kid")
    with pytest.raises(JWTVerificationError):
        await _verifier(jwks).verify(token)


async def test_malformed_token_rejected():
    _, jwks = _keypair_and_jwks()
    with pytest.raises(JWTVerificationError):
        await _verifier(jwks).verify("not.a.jwt")


async def test_no_kid_token_rejected():
    priv, jwks = _keypair_and_jwks()
    token, _ = _token(priv, kid=None)
    with pytest.raises(JWTVerificationError):
        await _verifier(jwks).verify(token)
