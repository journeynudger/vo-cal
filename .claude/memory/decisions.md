# Frozen Decisions

Numbered, dated, with rationale. Don't re-litigate mid-phase — amend here + master plan Amendments log if something must change. Sub-plan-local decisions live in each sub-plan's "Decisions locked" block; this file holds the cross-phase ones.

## 2026-06-12 — Planning session (approved first pass)

1. **Single backend: FastAPI + Supabase (Beacon shape).** Serein's Go/Fly/Tigris side not carried; its enrichment-worker design re-implemented in Python. One stack for one developer.
2. **Foreground-only capture for P0.** No `VoiceCaptureIntent` / `VoiceLiveActivity` port. `UIBackgroundModes: audio` keeps in-progress recordings alive across app-switch/lock. Reversible post-beta.
3. **Claim ladder extended, never weakened:** `accepted → mic_active → confirmed_listening → saved` (Serein semantics verbatim) + derived `transcribed → parsed → logged`. "Saved" = audio durably committed locally, nothing more.
4. **Audio is ground truth; meal log is derived.** Corrections are append-only records referencing the parse — simultaneously training data and admin-audit trail. Never patch artifacts in place.
5. **Voice-only logging.** No text-search food entry (out of scope). Manual *editing* of parsed items pre-confirm is in scope. No add-item by text on the result screen.
6. **Design: Cal AI reference layout, black/gold palette.** `#FAF9F6` bg, `#F4F2EE` cards r24, `#1A1A1A`/`#8A8A8E` text, `#111111` pill CTAs, `#C4A35A` gold accent. Macro chips keep semantic colors (protein red / carbs amber / fats blue). SF Pro; 40–64pt semibold numerals. Light mode only in P0 (locked via `UIUserInterfaceStyle`).
7. **Auth: phone OTP via Supabase, ported from Beacon.** No social login ⇒ Sign in with Apple not required by App Review.
8. **Transcription: server-side ElevenLabs Scribe** from the FastAPI worker. Keeps audio auditable against the transcript; Serein-proven provider.
9. **Parser: Claude tool-forced structured output.** `PARSER_MODEL` env, default `claude-sonnet-4-6`; Haiku 4.5 evaluated in B7 (verdict pending — record here).
10. **LLM extracts, deterministic code calculates.** All macro math, conversions, thresholds, protocol targets, and check-in adjustments are tested Python. AI writes prose ("why", recommendations phrasing) from structured rule output it cannot override.
11. **Clarifying question: exactly one, threshold-gated.** Fires only when a missing detail could shift the meal >75 kcal or >10g of a macro; highest-impact candidate wins; skippable. Threshold defined once in `docs/PARSER_CONTRACT.md`.
12. **Dictionary-first nutrition resolution, USDA FDC second.** Curated internal dictionary (with raw/cooked + unit conversions, modifier math) answers high-frequency foods; FDC covers the long tail through a read-through cache.
13. **App group `group.com.vocal.shared` kept despite no P0 extensions.** Minimizes Serein port diffs; future-proofs share/widget surfaces.
14. **Offline-capable capture path** (inverts Beacon's "no offline mode" for capture only). Capture commits locally without signal; transcription/parse catch up. Server is authoritative for everything else.
15. **Result delivery by polling, not WebSockets** (~1.5s with backoff). Beacon convention; revisit only if the 30s log target is threatened by measured latency.
16. **No push notifications, no third-party analytics SDKs in P0.** Check-in nudges via concierge text message. Keeps the privacy form small and the binary clean.
17. **No HealthKit in P0.** Weight is self-reported in check-ins. Avoids entitlement + privacy-form scope before the beta gate justifies it.
18. **Protocol safety rails live in the engine, not the prompt:** deficit/surplus caps (~0.5–1% BW/week), calorie floors, protein bounds. Doubles as App Review health posture.
19. **Protocol versions are immutable rows** with `supersedes` FK; check-in acceptance creates v(n+1) via the engine. Tombstone deletes for meal logs.
20. **External-tester TestFlight track** ⇒ Beta App Review ⇒ privacy policy URL, account deletion, review notes are planned work (Phase I), not surprises.
21. **Admin access = Supabase auth + server-side email allowlist; all admin reads audit-logged.** Voice recordings and food diaries are sensitive; access must be explainable. Beta users are told about admin review in the privacy policy.
22. **The fixture corpus is binding** (doccure pattern): `scripts/parser-eval` SCORES regression does not merge.
23. **Never edit, delete, or restructure Beacon or Serein.** Copy out only; ported files carry a header naming source + deletions.

## 2026-06-18 — Right-sizing pass (keep it lean for a 5–10 user concierge beta)

Three simplifications adopted after a stack-complexity review. Each cuts a provider/dependency/build with no loss to the thesis; none waste work already done. Supersede the earlier decisions noted.

24. **Transcription is on-device (Apple, iOS 26 `SpeechTranscriber`/`SpeechAnalyzer`), not server-side ElevenLabs.** Supersedes #8. Removes a provider, an API key, and the server transcription hop; transcript is ready immediately (no upload-then-transcribe latency, helps the <30s gate) and audio never has to leave the device just to be read. Audio still uploads in the background as the immutable ground-truth/audit artifact. The parser is unaffected — it takes a transcript string regardless of origin. The C5 worker shrinks to "parse only" (the app posts the transcript to `/parse`); server-side re-transcription remains possible later for audit if on-device quality disappoints in the beta.
25. **Admin review (P0 #10) is a `scripts/review` CLI + Supabase Studio, not a Next.js web app.** Refines #21. One reviewer auditing ten users does not need a hosted web app with its own auth. `scripts/review <meal_id>` prints the signed audio URL + transcript + parse JSON + corrections; `scripts/beta-metrics` covers the gate numbers + confidence calibration. Supabase Studio gives table browsing free. Phase H collapses to these scripts. The admin allowlist/audit-log posture (#21) still applies to the signed-URL endpoint the CLI calls.
26. **Auth is Sign in with Apple, not phone OTP.** Supersedes #7. One tap on TestFlight, no SMS provider to integrate or pay for, and no phone-number PII — which shrinks the App Privacy form and Beta App Review surface. (The earlier worry that offering social login forces a Sign-in-with-Apple option is moot when SiwA *is* the login.)
27. **No Prometheus/Grafana stack stood up for the beta.** The observability code ported from Beacon stays dormant; the six beta-gate numbers come from `scripts/beta-metrics` (plain SQL). Operational call — costs nothing, removes a moving part.
