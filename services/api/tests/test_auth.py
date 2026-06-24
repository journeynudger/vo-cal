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


async def test_valid_token_returns_sub_uuid():
    priv, jwks = _keypair_and_jwks()
    token, sub = _token(priv)
    assert str(await _verifier(jwks).verify(token)) == sub


async def test_expired_token_rejected():
    priv, jwks = _keypair_and_jwks()
    token, _ = _token(priv, exp_delta=-10)
    with pytest.raises(JWTVerificationError):
        await _verifier(jwks).verify(token)


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
