# Vo-Cal

Voice-first nutrition tracker. **Follow your nutrition your way.** The person says how they want to follow their nutrition (habits, calories, the method's five, or macros) and the app shows only that: the intake, the dashboard, the result screen and the nudges obey the choice. Voice is the way in: say what you ate in one breath ("4oz 93/7 beef, 200g cooked jasmine rice") and Vo-Cal turns it into an accurate log faster than typing.

## Stack

| Layer | Tech | Path |
|-------|------|------|
| iOS | Swift 6, SwiftUI, iOS 26+ | `apps/ios/` |
| Voice | `VoCalVoice` SPM (Serein port) | `Sources/VoCalVoice/` |
| Shared types | `VoCalCore` SPM | `Sources/VoCalCore/` |
| API + worker | FastAPI, Python (uv) | `services/api/` |
| DB / Auth / Storage | Supabase (Postgres + RLS) | `supabase/` |
| Admin review | FastAPI admin router (allowlist-gated, audit-logged) + review CLI | `services/api/src/api/admin/`, `scripts/review` |

## Commands

Every change that reaches GitHub runs `.github/workflows/ci.yml`: the API suite and the
parser corpus ratchet, the library tests with the ratchet tables, the zero-warning app
compile and the voice runtime scenarios on a simulator. The local gate is the push hook,
installed once per clone (`make setup` does it):

```
git config core.hooksPath .githooks
```


```bash
make setup        # Install dependencies (Homebrew + uv)
make dev          # Prepare local environment
make api-dev      # Start API on :8000
make ios-sim      # Build & run iOS simulator
make check        # SPM tests + API lint/tests
make doctor       # Check environment
```

## Where to start

Agent sessions: read `CLAUDE.md` → `.claude/memory/INDEX.md` → `.claude/plans/MASTER-PLAN.md`.
Humans: same order, honestly.

## Agents / headless dev

One paved path, no guessing: `scripts/setup-dev.sh` → `scripts/ensure-dev-server.sh` →
`curl :8000/__dev/preflight` → `POST /__dev/capture` (text-in, meal-out — no microphone).
Full quickstart in `AGENTS.md`; per-directory notes in `services/api/`, `supabase/`,
`apps/ios/`, `scripts/`.
