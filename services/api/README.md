# vocal-api

Vo-Cal backend — FastAPI + Supabase, scaffolded from Beacon's proven API shape.

```bash
uv sync                 # install deps
uv run uvicorn api.main:app --reload   # serve on :8000 (or: make api-dev)
uv run ruff check . && uv run pytest -q  # edit loop (or: scripts/check-api)
```

Schema and RLS posture: `docs/DATABASE.md`. Live RLS probes: `uv run pytest -m live_db`.
