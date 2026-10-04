# Decisions

**Frozen decisions live in `.claude/memory/decisions.md` (55 numbered, dated, with rationale).** This file exists for Beacon-convention compatibility; it is an index, not a source of truth. New cross-phase decisions go to memory + the master plan Amendments log — never here.

## Index (titles only)

1. Single backend: FastAPI + Supabase (Beacon shape)
2. Foreground-only capture for P0
3. Claim ladder extended, never weakened
4. Audio is ground truth; meal log is derived
5. Voice-only logging (relaxed by 33 and 52)
6. Design: Cal AI reference layout, black/gold palette
7. Auth: phone OTP via Supabase, ported from Beacon (superseded by 26)
8. Transcription: server-side ElevenLabs Scribe (24 planned on-device; never built, 8 is what ships)
9. Parser: Claude tool-forced structured output
10. LLM extracts, deterministic code calculates
11. Clarifying question: exactly one, threshold-gated (cap lifted by 29)
12. Dictionary-first nutrition resolution, USDA FDC second
13. App group `group.com.vocal.shared` kept despite no P0 extensions
14. Offline-capable capture path
15. Result delivery by polling, not WebSockets
16. No push notifications, no third-party analytics SDKs in P0
17. No HealthKit in P0 (reversed 2026-09-24: active energy read on the phone)
18. Protocol safety rails live in the engine, not the prompt
19. Protocol versions are immutable rows
20. External-tester TestFlight track
21. Admin access = Supabase auth + server-side email allowlist; all admin reads audit-logged
22. The fixture corpus is binding
23. Never edit, delete, or restructure Beacon or Serein
24. Transcription is on-device (Apple, iOS 26 `SpeechTranscriber`/`SpeechAnalyzer`), not server-side ElevenLabs
25. Admin review (P0 #10) is a `scripts/review` CLI + Supabase Studio, not a Next.js web app
26. Auth is Sign in with Apple, not phone OTP
27. No Prometheus/Grafana stack stood up for the beta
28. Carbs & fat are OFF the home dashboard
29. Clarifying checks are per-material-ingredient, not one-per-meal
30. Micro-tracking is opt-in
31. Three pillars are the whole product
32. Mid-week situational nudging is promoted to a core pillar
33. Text logging is the MVP fallback
34. MVP voice does not talk back
35. Protocol model = calories per kg of IDEAL body weight
36. Activity level is inferred, never asked
37. Monthly recalibration is decision-tree, not judgment
38. The conversational AI is a "guide," not a coach
39. RESOLVED 2026-06-18 → NATIVE iOS / TestFlight
40. UI reference (future builds):
41. Tab bar = Home · [center Log] · Progress (the tab bar was removed 2026-09-25, Phase U)
42. Logging is meal-type-first
43. Progress tab
44. Variant ("which product?") checks fire on a lower bar
45. Weekly-bar status colors: gold = under/on the way, green = met, red = over
46. Voice append: a new capture chain joining a derived row, never an edit of an artifact
47. Failure surfaces are outcomes, not alarms; diagnostic codes never render
48. FatSecret is the long-tail food source, ahead of the curated suffix head, the estimator and USDA; USDA FDC stays last
49. UI is proven by two loops, and claims are graded
50. Every meal is named after what was eaten; the person's name wins and makes a usual
51. A repeat is recognized against usuals only, by name or by items, and asked, never assumed
52. Typed logs and photo logs are in scope (MUST-NOT 4 amended); voice stays the default
53. The estimator has a clock
54. The week carries overages only
55. The parser provider follows the model id
