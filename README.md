# Vo-Cal

Voice-first calorie/macro tracker. **Not an effortless tracker — the accurate tracker for people willing to do the work.** Photos guess; voice knows: you speak every ingredient ("4oz 93/7 beef, 200g cooked jasmine rice") and Vo-Cal turns the spoken, fully-specified meal into an accurate log faster than typing.

## Stack

| Layer | Tech | Path |
|-------|------|------|
| iOS | Swift 6, SwiftUI, iOS 26+ | `apps/ios/` |
| Voice | `VoCalVoice` SPM (Serein port) | `Sources/VoCalVoice/` |
| Shared types | `VoCalCore` SPM | `Sources/VoCalCore/` |
| API + worker | FastAPI, Python (uv) | `services/api/` |
| DB / Auth / Storage | Supabase (Postgres + RLS) | `supabase/` |
| Admin panel | Next.js (internal) | `services/admin-web/` |

## Commands

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
