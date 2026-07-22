#!/usr/bin/env bash
# Known-good-state button for the FastAPI dev server. IDEMPOTENT.
#
#   healthy server on the port  -> reuse it (no restart)
#   wedged server (listening but /health not answering) -> kill + restart
#   nothing running             -> start fresh
#
# Logs: unified pipeline log at .logs/server.log (stage tags [audio] [transcript]
# [parse] [store] [nudge]; scripts/ios-log-stream.sh appends [ios] lines to the SAME file).
# Ports: written to .agents/dev-ports.json so nothing downstream hardcodes localhost:8000.

set -euo pipefail
cd "$(dirname "$0")/.."

[ -d "services/api" ] || { echo "[ensure-dev-server] ERROR: run from the vo-cal repo root"; exit 1; }

API_PORT="${VOCAL_API_PORT:-8000}"
LOG_FILE=".logs/server.log"
mkdir -p .logs .agents

healthy() { curl -s -m 2 "http://127.0.0.1:${API_PORT}/health" | grep -q '"ok"'; }
listening() { lsof -nP -iTCP:"${API_PORT}" -sTCP:LISTEN >/dev/null 2>&1; }

if listening; then
  if healthy; then
    echo "[ensure-dev-server] healthy server already on :${API_PORT} — reusing (no restart)"
  else
    echo "[ensure-dev-server] port ${API_PORT} is LISTENING but /health is not answering — restarting wedged server"
    lsof -nP -tiTCP:"${API_PORT}" -sTCP:LISTEN | xargs kill -9 2>/dev/null || true
    sleep 1
  fi
fi

if ! healthy; then
  # The dev server must NEVER inherit a hosted Supabase from the repo .env — the app
  # (correctly) refuses to boot dev seams against one. Point it at the LOCAL stack when
  # docker/supabase is up; otherwise run fully offline on FakeDatabase (nothing persists —
  # /__dev/preflight says so).
  SUPA_URL="" SUPA_SERVICE_KEY="" SUPA_ANON="" FORCE_OFFLINE_FLAG="false"
  if docker info >/dev/null 2>&1; then
    eval "$(supabase status --output env 2>/dev/null | grep -E '^(API_URL|SERVICE_ROLE_KEY|ANON_KEY)=' || true)"
    if [ -n "${API_URL:-}" ]; then
      SUPA_URL="$API_URL"; SUPA_SERVICE_KEY="${SERVICE_ROLE_KEY:-}"; SUPA_ANON="${ANON_KEY:-}"
      echo "[ensure-dev-server] local Supabase detected at ${SUPA_URL}"
    fi
  fi
  if [ -z "$SUPA_URL" ]; then
    # env_ignore_empty=True means we cannot blank the .env's hosted creds via empty env
    # vars — FORCE_OFFLINE is the explicit switch that makes the app use fakes instead
    # (and satisfies the local-only boot guards, since fakes touch no database).
    FORCE_OFFLINE_FLAG="true"
    echo "[ensure-dev-server] no local Supabase — running OFFLINE on FakeDatabase (nothing persists)"
  fi

  echo "[ensure-dev-server] starting FastAPI on :${API_PORT} (logs -> ${LOG_FILE})"
  (
    cd services/api
    # DEV_ENDPOINTS enables the /__dev router; TEST_MODE+DEBUG enable the X-Test-User auth
    # seam. All three are LOCAL-ONLY: the app REFUSES TO BOOT with these set against a
    # hosted database (main.py guards) — so this cannot leak into staging/prod.
    env ${SUPA_URL:+SUPABASE_URL="$SUPA_URL"} \
        ${SUPA_SERVICE_KEY:+SUPABASE_SERVICE_ROLE_KEY="$SUPA_SERVICE_KEY"} \
        ${SUPA_ANON:+SUPABASE_ANON_KEY="$SUPA_ANON"} \
        FORCE_OFFLINE="$FORCE_OFFLINE_FLAG" \
        DEV_ENDPOINTS=true TEST_MODE=true DEBUG=true \
      nohup uv run uvicorn api.main:app --host 127.0.0.1 --port "${API_PORT}" \
      >> "../../${LOG_FILE}" 2>&1 &
  )
  for _ in $(seq 1 30); do healthy && break; sleep 0.5; done
  healthy || { echo "[ensure-dev-server] ERROR: server failed to become healthy — tail ${LOG_FILE}:"; tail -20 "${LOG_FILE}"; exit 1; }
  echo "[ensure-dev-server] up."
fi

# Discoverable ports for everything downstream (agents: read this, never hardcode).
SUPA_API_PORT="$(supabase status --output json 2>/dev/null | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin); print(d.get("API_URL","").rsplit(":",1)[-1] or "")
except Exception: print("")' || true)"
python3 - "$API_PORT" "$SUPA_API_PORT" <<'EOF'
import json, sys
api, supa = sys.argv[1], sys.argv[2]
ports = {"api": int(api), "log_file": ".logs/server.log"}
if supa.isdigit():
    ports["supabase_api"] = int(supa)
    ports["supabase_db"] = 54322  # supabase-cli local default
json.dump(ports, open(".agents/dev-ports.json", "w"), indent=2)
print("[ensure-dev-server] wrote .agents/dev-ports.json:", json.dumps(ports))
EOF
