# scripts/ + bin/ — the paved paths

Run everything from the repo root. All idempotent unless marked.

| Script | What it proves / does |
|---|---|
| `scripts/setup-dev.sh` | Fresh-machine bootstrap: brew + uv deps, `.env`, LOCAL Supabase start + migrate + seed (refuses non-local DBs), iOS project gen. Safe twice. |
| `scripts/ensure-dev-server.sh` | Known-good-state FastAPI button: reuse healthy / restart wedged / start fresh. Sets `DEV_ENDPOINTS`+`TEST_MODE`+`DEBUG` (local-only; boot guards enforce). Logs → `.logs/server.log`; ports → `.agents/dev-ports.json`. |
| `scripts/ios-log-stream.sh` | Simulator os_log → `.logs/server.log` tagged `[ios]` (needs a booted sim — honest limitation). |
| `scripts/check-api` | ruff + pytest for services/api (~2s). The API edit loop. |
| `scripts/check` | SPM tests + check-api. Blind to the iOS app target. |
| `scripts/parser-eval` | Parser fixture corpus SCORES — regression = no merge. |
| `scripts/doctor.sh` | Environment diagnostics. |
| `scripts/smoke-prod` | Prod smoke (health + authed round-trip). |
| `bin/ios-app-build` | iOS compile check, zero warnings, no simulator. |
| `bin/ios-sim-voice-test` | 9 voice runtime scenarios on the pinned simulator (~45s). |
| `bin/voice-dst` | Kernel property fuzzer (`--smoke` = 200 seeds). |

Agent quickstart: `setup-dev.sh` → `ensure-dev-server.sh` → `curl :8000/__dev/preflight`
→ `curl -X POST :8000/__dev/capture -d '{"text":"4oz 93/7 beef"}' -H 'content-type: application/json'`
→ `grep -E '\[(audio|transcript|parse|store|nudge|ios)\]' .logs/server.log`.
