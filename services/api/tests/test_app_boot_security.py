"""Boot-time security guards (tenant isolation, AGENTS.md #7).

The X-Test-User seam (test_mode AND debug) bypasses JWT and lets any caller assert
any user id — fine offline against FakeDatabase, catastrophic against a hosted,
RLS-bypassing service-role Supabase. The app must refuse to boot in that combination
rather than fail open. (.env.example ships DEBUG=true, so this is a real misconfig.)
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from api import main
from api.config import settings


def test_refuses_test_auth_seam_against_hosted_db(monkeypatch):
    # Hosted Supabase + the trusted seam (test_mode+debug are on via the autouse fixture):
    # no injected db, so the lifespan builds the real db and the guard must fire.
    monkeypatch.setattr(settings, "supabase_url", "https://example.supabase.co")
    monkeypatch.setattr(settings, "supabase_service_role_key", "service-role-xxx")

    app = main.create_app()
    with pytest.raises(RuntimeError, match="impersonation"), TestClient(app):
        pass


def test_local_supabase_is_exempt_from_the_seam_guard(monkeypatch):
    # The guard targets HOSTED databases; a local Supabase URL (the supabase-start dev stack)
    # with the seam on is a legitimate local setup and must NOT trip the guard.
    monkeypatch.setattr(settings, "supabase_url", "http://127.0.0.1:54321")
    monkeypatch.setattr(settings, "supabase_service_role_key", "local-service-role")
    # The guard itself is the unit under test (calling it must not raise); we don't build the
    # real client here (that would need a running local Supabase).
    main._refuse_test_auth_against_hosted_db()  # no raise == pass


def test_guard_noop_when_seam_off(monkeypatch):
    # With debug off, the seam is unreachable, so even a hosted URL is fine for the guard.
    monkeypatch.setattr(settings, "supabase_url", "https://example.supabase.co")
    monkeypatch.setattr(settings, "debug", False)
    main._refuse_test_auth_against_hosted_db()  # no raise == pass


def test_refuses_fakedb_in_production_posture(monkeypatch):
    # No Supabase credentials with every dev flag off is a broken deploy (dropped or
    # rotated secret), not an offline dev box. Booting FakeDatabase there passes
    # /health while every write silently evaporates — the fail-open half of the
    # 2026-07 water-lane incident class. The app must crash-loop instead.
    monkeypatch.setattr(settings, "supabase_url", "")
    monkeypatch.setattr(settings, "supabase_service_role_key", "")
    monkeypatch.setattr(settings, "debug", False)
    monkeypatch.setattr(settings, "test_mode", False)
    monkeypatch.setattr(settings, "dev_endpoints", False)

    app = main.create_app()
    with pytest.raises(RuntimeError, match="production posture"), TestClient(app):
        pass


def test_fakedb_allowed_with_a_dev_flag(monkeypatch):
    # Any explicit dev posture keeps the offline FakeDatabase path working (CI, dev box).
    monkeypatch.setattr(settings, "supabase_url", "")
    monkeypatch.setattr(settings, "supabase_service_role_key", "")
    monkeypatch.setattr(settings, "debug", False)
    monkeypatch.setattr(settings, "test_mode", True)
    monkeypatch.setattr(settings, "dev_endpoints", False)

    app = main.create_app()
    with TestClient(app) as client:
        assert client.get("/health").status_code == 200
