# Voice Capture Doctrine

> **Port provenance**
> Source: `/Users/lorenzoscardicchio/Downloads/Projects/Serein/docs/VOICE_CAPTURE.md`, ported near-verbatim with Serein → Vo-Cal renames.
> **Deletions:** the Action Button reference in "Voice First" (Vo-Cal P0 capture is foreground-only); the `AudioRecordingIntent` / Live Activity paragraph in "Mechanical Consequences"; the `live_activity_request_started` / `live_activity_request_done` milestones and their mention in "Startup Observability"; the `background_voice_intent` entry-mode example (only foreground entry modes exist in P0); the closing reference to Serein's `docs/briefs/` archive.
> **Additions:** the "Derived Rungs (Vo-Cal Extension)" section at the end.

This document is the canonical product doctrine for Vo-Cal voice capture.

If a historical brief, old plan, or implementation note conflicts with this file, this file wins.

## Voice First

Voice is Vo-Cal's primary capture modality.

A voice capture often begins as a fleeting moment. The user may be cooking, plating a meal, walking out of a restaurant, or half-distracted with the phone barely unlocked. They are not trying to manage a recorder. They are trying not to lose the meal.

The user presses the button and speaks. Vo-Cal's first duty is to be ready-at-hand for that act: trustworthy listening infrastructure that becomes available as quickly as the platform allows.

The body does not wait for bookkeeping. The mind does not wait for durability claims. If Vo-Cal accepts the start request, it should make the microphone hot and get audio flowing as fast as it honestly can.

The microphone-hot path must not wait on UI work, network state, telemetry refresh, enrichment, or other non-audio truth reconstruction.

## Truth And Claims

Evidence-based truth is essential, but it governs claims, not whether capture is allowed to begin.

Vo-Cal must distinguish these claims:

| Claim | What it means | Proof required |
| --- | --- | --- |
| `accepted` | Your gesture landed. Vo-Cal heard the request and is trying to listen now. | Request accepted by the runtime control path. |
| `mic_active` | The audio path has actually started. | Recorder/audio path activation facts, not just UI intent. |
| `confirmed_listening` | Vo-Cal has proof that listening is real, not merely attempted. | Evidence of real byte flow or equivalent liveness proof. |
| `saved` | The capture is durably committed. | Durable local commit. |

Vo-Cal may acknowledge `accepted` before it has proof of `confirmed_listening`.

Vo-Cal must never claim `confirmed_listening` or `saved` without the corresponding proof.

Optimism is acceptable at the `accepted` layer. False certainty is not.

## Failure Priority

The single most trust-eroding failure is: the user receives an acknowledged start, begins speaking, and Vo-Cal is silently not listening.

That failure is worse than a cautious false alarm.

False alarms should still be rare, but Vo-Cal must be biased against silent dead air.

## Attention Model

Healthy capture should remain calm and peripheral, like a tool that is simply there when needed.

Uncertainty about whether Vo-Cal is actually listening is not a peripheral state. When certainty does not arrive quickly enough, Vo-Cal may escalate from periphery to center and must do so unmistakably.

Calm is the default. Alarm is the exception. Silent ambiguity when the user is already speaking is unacceptable.

## User-Facing Signals

The product should not dump internal startup choreography onto the user.

Implementation phases such as arming, session setup, microphone checks, or liveness polling may exist internally. They are not inherently user-facing product states.

In the common case, the user experience should collapse those internal steps into one calm acknowledgement that means, in effect, "heard you, activating the mic now."

In the common case, the user should not have to parse a rapid sequence of transitional labels such as "arming," "checking microphone," and "starting." That is noisy, janky, and usually not decision-useful.

If certainty fails to arrive quickly enough, the product must switch from calm acknowledgement to unmistakable warning. The warning exists to protect trust, not to narrate internal implementation details.

The happy path should feel immediate. The failure path should be explicit. The ambiguous middle should be as short as possible.

## Design Consequences

Voice capture surfaces should communicate a ladder of certainty, not a single binary state.

The product should separate:

- request acknowledged
- audio path active
- listening confirmed
- durably saved

Those are different user truths and should not be conflated.

## Mechanical Consequences

Docs alone are not enough. Future changes to voice capture should preserve:

- observability for `accepted`, `mic_active`, `confirmed_listening`, and `saved`
- explicit detection of acknowledged start without timely liveness confirmation
- validation that non-audio work is not placed in front of microphone activation
- user-facing copy and haptics that collapse internal startup churn on the healthy path and escalate unmistakably on the failure path

## Startup Observability

Voice startup must emit a stable milestone vocabulary so regressions are mechanically visible and retrospective triage is possible.

The canonical startup milestone names are:

- `accepted`
- `bootstrap_started`
- `bootstrap_done`
- `recovery_scan_started`
- `recovery_scan_done`
- `audio_session_config_started`
- `audio_session_config_done`
- `recorder_create_started`
- `recorder_create_done`
- `record_call_started`
- `record_call_done`
- `mic_active`
- `first_progress`
- `confirmed_listening`
- `start_failed`
- `saved`

These map to the claim ladder as follows:

- `accepted` means the request landed in the control path.
- `mic_active` means the recorder/audio path actually started and the audio file/session is open.
- `confirmed_listening` means liveness evidence arrived.
- `saved` means the final artifact is durably committed to the local outbox.

`bootstrap_*`, `recovery_scan_*`, `audio_session_config_*`, `recorder_create_*`, `record_call_*`, and `first_progress` exist to explain latency between those claims. They do not widen what Vo-Cal is allowed to tell the user.

Startup observability should also distinguish:

- `process_cold`: whether this request arrived in a newly launched app process before the foreground shell was running
- `voice_bootstrap_cold`: whether the voice coordinator itself still needed bootstrap work in this process
- `entry_mode`: the app entry mode that claimed this request (for example `foreground_scene`)
- `lane`: the runtime lane serving the request (`voice_capture`)

`debug-events.jsonl` remains the best-effort runtime log and UI synchronization channel.

`observability.jsonl` is a separate bounded local telemetry artifact for retrospective latency analysis. It is allowed to be lossy, it must stay off the microphone hot path, and it is not a source of truth for user-facing claims.

## Derived Rungs (Vo-Cal Extension)

Vo-Cal extends the ladder with three derived rungs above `saved`:

| Claim | What it means | Proof required |
| --- | --- | --- |
| `transcribed` | A transcript artifact exists for this capture. | Durable `transcripts` record committed server-side. |
| `parsed` | A parse artifact (per `docs/PARSER_CONTRACT.md`) exists for the transcript. | Durable `parses` record committed server-side. |
| `logged` | The user confirmed the parse into their food diary. | Durable `meal_logs` record committed server-side. |

Rules:

- These rungs are derived records layered above `saved`. They may never weaken what `saved` means. `saved` remains "audio durably committed locally" — nothing more, nothing less.
- A transcription or parse failure is never a capture failure. Audio is ground truth; derived records can always be retried or recomputed.
- Derived claims follow the same proofs-not-booleans rule as the base ladder: each rung requires its committed artifact, never an optimistic flag.
- Corrections to a parse are append-only new records referencing the parse. They never mutate the parse, the transcript, or the capture.
