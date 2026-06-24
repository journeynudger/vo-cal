# App Review Notes — Vo-Cal

Paste-ready content for **App Store Connect → TestFlight → Test Information → App Review
Information / Notes for Reviewer**, plus the supporting context a reviewer needs. Vo-Cal ships
to **external testers**, so this build goes through **Beta App Review** — these notes are not
optional. Keep them in sync with the in-app copy they reference; if the disclaimer text or the
deletion flow moves, update this file in the same change.

---

## Reviewer notes (copy into the "Notes" field)

> **What Vo-Cal is.** Vo-Cal is a voice-first nutrition tracker. You tap the mic, say what you
> ate in plain language, and the app transcribes it, breaks it into food items, and estimates
> calories and macros. You can edit anything before confirming. Nothing else logs food — there
> is no photo logging, no barcode scanner, no social feed.
>
> **Voice/microphone.** The microphone is used **only while you are actively logging a meal**.
> Tapping the mic starts a recording; the recording stops when you finish. We keep the audio as
> the source of truth so the transcript can be re-checked and corrected. The microphone is
> never used in the background or outside the log-a-meal flow. The permission string
> (Settings) reads: *"Vo-Cal records your voice only while you log a meal, to turn what you say
> into your food log."*
>
> **Not medical advice.** Vo-Cal provides nutrition information for educational purposes and is
> not medical advice. This disclaimer is shown in onboarding and on the protocol/targets
> screen (see *Where the disclaimer appears* below).
>
> **Safe-by-design targets.** Calorie/macro targets are computed by deterministic, rule-based
> code from the user's intake — not by the user, and not by the language model. The engine is
> rail-bounded so extreme or unsafe targets are unreachable through any combination of inputs
> (see *Health posture* below).
>
> **Concierge beta — admin data review (disclosed).** During this early beta our team may
> review submitted meal logs and voice audio to improve transcription/parsing accuracy. This is
> disclosed in the in-app onboarding and in the public privacy policy. All admin access to user
> data is audit-logged.
>
> **Account deletion.** Account deletion is in-app: **Settings → Delete account** (a confirm
> step, then a permanent, irreversible delete of all of the user's data and voice recordings).
>
> **Demo account.** No reviewer credentials are required. On the sign-in screen, tap **"Use a
> test account"** to create an anonymous session and walk the full flow (onboarding → record a
> meal → see the parsed log → targets screen → Settings → Delete account). See *Demo account*
> below.

---

## Where the disclaimer appears (verified in code)

The "not medical advice" posture is surfaced in three first-run / decision surfaces, not buried
in a settings page:

| Surface | File | Copy |
|---|---|---|
| Onboarding | `apps/ios/VoCal/VoCalApp.swift:191` | "Vo-Cal provides nutrition information for educational purposes and is not medical advice." |
| Protocol / targets reveal | `apps/ios/VoCal/Views/Onboarding/ProtocolRevealView.swift:105` | "Not medical advice. These targets are a starting point from your inputs, not a clinical recommendation. Check with a professional for medical concerns." |
| Weekly check-in | `apps/ios/VoCal/Views/CheckIn/CheckInView.swift:158` | "Not medical advice. Recommendations are rule-derived from your inputs and rail-bounded." |
| Settings | `apps/ios/VoCal/VoCalApp.swift:191` (Settings view) | Same educational-purposes line, alongside Delete account. |

---

## Health posture — why extreme targets are unreachable (the F3 rails)

This is the substantive answer to any eating-disorder / extreme-diet concern, and the basis for
the age-rating questionnaire answer (Medical/Treatment = **Infrequent/Mild**).

- **The user does not set their own calorie number.** Targets are computed by a deterministic
  engine (`services/api/src/api/protocols/engine.py`) from a structured intake. The language
  model only phrases the "why" from numbers the engine emits — per the project's hard rule, *the
  LLM extracts; deterministic, tested code calculates.* The model can never invent, round, or
  override a target.
- **Targets are bounded to a fat-loss band.** Calories key off **cal/kg of ideal body weight**,
  clamped to a **24–29 cal/kg** band (`services/api/src/api/checkin/recommend.py`, constants
  `_CAL_PER_KG_MIN = 24.0`, `_CAL_PER_KG_MAX = 29.0`). A request that would fall outside the
  band is clamped to the nearest edge, and **the clamp is always recorded, never hidden**.
- **There is an absolute calorie floor.** Recalibration may never cut a user below a
  sex-derived floor even if cal/kg is in-band but ideal body weight is small
  (`recommend.py`, `calorie_floor`, default 1600). Monthly recalibration moves **one step at a
  time**, never a leap.
- **Tested, not asserted.** The rails are covered by golden tests:
  `services/api/tests/test_recommend.py` (clamps to floor/ceiling and reports them;
  in-band requests produce no clamp) and `services/api/tests/test_protocol_engine.py`
  (persona personas clamp to the band top). These are re-run as part of the I3 acceptance and
  referenced here so a reviewer (or a future engineer) can confirm the claim is enforced, not
  just stated.

Net: there is **no input combination** — through intake, check-in, or correction — that
produces a starvation-level or otherwise unsafe target. The system fails safe (toward the
floor/ceiling) and reports any clamp.

---

## Account deletion (App Review 5.1.1(v))

Account creation exists (Sign in with Apple / anonymous), so in-app deletion is required and
implemented.

- **UI:** Settings → **Delete account** → confirmation alert → permanent delete, then the app
  signs out and returns to onboarding. (`apps/ios/VoCal/VoCalApp.swift`, Settings view:
  `confirmingDelete` alert → `deleteAccount()` → `api.deleteAccount()` → sign out.)
- **Backend:** `DELETE /account` (`services/api/src/api/account/router.py`) is total and
  irreversible, in a deliberate order so a mid-delete failure leaves no orphaned identity:
  1. Purge the user's capture-audio blobs from Storage (the `"{user_id}/"` prefix).
  2. Delete every user-owned row, owner-scoped (profiles, intake, protocols, captures, parses,
     meal logs, corrections, transcripts, check-ins, saved meals, water logs, client metrics).
  3. Delete the Supabase auth user last (which cascades any remainder).
- **Result:** re-signup with the same provider gets a clean slate. Verified by
  `services/api/tests/test_account_api.py` (post-deletion: 401 without auth, 204 on delete,
  zero rows readable).

---

## Demo account (no credentials needed)

Reviewers do not need a username/password. The build exposes an **anonymous test-account** path
so the full flow is reachable without Sign in with Apple:

- On the sign-in screen, the **"Use a test account"** button creates a real anonymous Supabase
  session (`apps/ios/VoCal/Views/Onboarding/AuthGateView.swift` → `signInAnonymously()`).
- This is the same path the internal **VoCal-Live** scheme uses for live testing against the
  production backend (`RuntimeMode.forcesLiveServices`). It is a genuine session, not a mock —
  it hits the real API and creates real (deletable) rows.
- From there a reviewer can complete onboarding, record and log a meal by voice, view the
  parsed result and the targets screen, and exercise **Settings → Delete account**.

> TODO(lorenzo): confirm the production TestFlight build keeps the anonymous "Use a test
> account" button visible for reviewers (it is gated on the live-services runtime mode). If the
> production sign-in screen hides it, either (a) leave Sign in with Apple as the demo path and
> note that no credentials are required because Apple handles auth, or (b) provide a dedicated
> demo Apple ID in the Notes field.

---

## Privacy & data-use summary for the reviewer

- No tracking, no third-party ad/analytics SDKs, no push notifications.
- Data collected (all linked to the account, none used for tracking, all for app
  functionality): voice audio, health/nutrition (meals, macros, intake), fitness (bodyweight,
  activity), account identifier, and an email address if provided via Sign in with Apple.
- Full mapping in `docs/app-store/APP_PRIVACY.md`; it is kept in lockstep with
  `apps/ios/VoCal/PrivacyInfo.xcprivacy` and the App Privacy form.
- Privacy policy and support pages: see `TESTFLIGHT_RUNBOOK.md` step 4 for the live URLs.

---

## "What to Test" (for the external Concierge Beta group)

> First build — please: (1) complete onboarding, (2) log three meals by voice, (3) tell us
> about any moment where the app's claim felt like a lie — anywhere it said it heard you,
> saved, or logged something and you weren't sure it actually did.
