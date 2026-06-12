# Decisions

**Frozen decisions live in `.claude/memory/decisions.md` (23 numbered, dated, with rationale).** This file exists for Beacon-convention compatibility; it is an index, not a source of truth. New cross-phase decisions go to memory + the master plan Amendments log — never here.

## Index (titles only)

1. Single backend: FastAPI + Supabase (Beacon shape)
2. Foreground-only capture for P0
3. Claim ladder extended, never weakened
4. Audio is ground truth; meal log is derived
5. Voice-only logging
6. Design: Cal AI reference layout, black/gold palette
7. Auth: phone OTP via Supabase, ported from Beacon
8. Transcription: server-side ElevenLabs Scribe
9. Parser: Claude tool-forced structured output
10. LLM extracts, deterministic code calculates
11. Clarifying question: exactly one, threshold-gated
12. Dictionary-first nutrition resolution, USDA FDC second
13. App group `group.com.vocal.shared` kept despite no P0 extensions
14. Offline-capable capture path
15. Result delivery by polling, not WebSockets
16. No push notifications, no third-party analytics SDKs in P0
17. No HealthKit in P0
18. Protocol safety rails live in the engine, not the prompt
19. Protocol versions are immutable rows
20. External-tester TestFlight track
21. Admin access = Supabase auth + server-side email allowlist; all admin reads audit-logged
22. The fixture corpus is binding
23. Never edit, delete, or restructure Beacon or Serein
