#!/usr/bin/env bash
# Environment diagnostics. Read-only; safe to run anytime.
set -uo pipefail
cd "$(dirname "$0")/.."

ok()   { printf "  ✓ %s\n" "$1"; }
bad()  { printf "  ✗ %s\n" "$1"; FAIL=1; }
warn() { printf "  ~ %s\n" "$1"; }
FAIL=0

echo "Toolchain"
command -v swift >/dev/null && ok "swift $(swift --version 2>&1 | head -1 | sed 's/.*version //;s/ .*//')" || bad "swift missing"
command -v xcodebuild >/dev/null && ok "$(xcodebuild -version | head -1)" || bad "xcodebuild missing"
command -v xcodegen >/dev/null && ok "xcodegen" || bad "xcodegen missing (brew bundle)"
command -v uv >/dev/null && ok "uv $(uv --version | awk '{print $2}')" || bad "uv missing (brew bundle)"
command -v supabase >/dev/null && ok "supabase CLI" || warn "supabase CLI missing (needed for db work)"
command -v swiftlint >/dev/null && ok "swiftlint" || warn "swiftlint missing (pre-commit hook will fail)"

echo "Environment"
[ -f .env ] && ok ".env present" || warn ".env missing (cp .env.example .env)"
docker info >/dev/null 2>&1 && ok "docker daemon up (local supabase possible)" || warn "docker daemon down — local supabase unavailable; tests use fakes"

echo "Services"
curl -s -m 2 http://127.0.0.1:8000/health >/dev/null 2>&1 && ok "API responding on :8000" || warn "API not running (make api-dev)"

echo "Project"
[ -d apps/ios/VoCal.xcodeproj ] && ok "Xcode project generated" || warn "run: make ios-generate"
[ -d services/api/.venv ] && ok "API venv synced" || warn "run: cd services/api && uv sync"

exit $FAIL
