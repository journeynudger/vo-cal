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
