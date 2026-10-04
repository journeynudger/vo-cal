# App Review Notes — Vo-Cal

Paste-ready content for **App Store Connect → TestFlight → Test Information → App Review
Information / Notes for Reviewer**, plus the supporting context a reviewer needs. Vo-Cal ships
to **external testers**, so this build goes through **Beta App Review** — these notes are not
optional. Keep them in sync with the in-app copy they reference; if the disclaimer text or the
deletion flow moves, update this file in the same change.

---

## Reviewer notes (copy into the "Notes" field)

> **What Vo-Cal is.** Vo-Cal is a voice-first nutrition tracker. At first launch you say how you
> want to follow your nutrition (habits only, calories, the five things the method tracks, or
> macros), and the app shows only that; a habits user sees no calorie anywhere, and the choice
> can be changed in Settings → How I track. You tap the mic, say what you ate in plain language,
> and the app transcribes it, breaks it into food items, and estimates what your choice shows.
> You can edit anything before confirming. Two secondary ways in share
> the same confirm step: typing what you ate (with search over what you logged before), and
> photographing a meal, which the app identifies and then asks about what a photo cannot show
> (oil, dressing, hidden layers). There is no barcode scanner and no social feed.
>
> **Voice/microphone.** The microphone is used **only while you are actively logging a meal**.
> Tapping the mic starts a recording; the recording stops when you finish. We keep the audio as
> the source of truth so the transcript can be re-checked and corrected. The microphone is
> never used in the background or outside the log-a-meal flow. The permission string
> (Settings) reads: *"Vo-Cal records your voice only while you log a meal, to turn what you say
> into your food log."*
>
> **Camera and photo library.** Used only when you choose to log a meal from a photo: the
> camera opens from the plus button in the capture bar, or you pick an existing photo. The
> photo is uploaded to the account's private storage as the record the log was made from.
> Permission strings: *"Vo-Cal uses the camera only when you take a photo of a meal to log
> it."* and *"Vo-Cal opens your photos only when you choose a meal photo to log."*
>
> **Apple Health (read only).** With permission, the app reads active energy burned today and
> shows it next to what you ate on the Today screen. The value stays on the phone; it is never
> sent to our servers, and the app never writes to Health. Permission strings: *"Vo-Cal reads
> your active energy to show what you burned today next to what you ate, and it stays on your
> phone."* / *"Vo-Cal only reads from Apple Health and never writes anything to it."*
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
- **Targets are bounded.** Maintenance calories key off **kcal per kg of ideal body weight**
  at one of four activity factors (25 to 32 kcal/kg, `protocols/engine.py` `ProtocolTunables`),
  and a fat-loss deficit is clamped to **10–20%** at generation: the app never picks a harsher
  cut than the coach default, whatever the inputs. Recalibration moves the deficit **one five
  percent step at a time** toward a 0.5 to 1.0 percent of bodyweight per week rate, clamped to
  0–25% (`checkin/recommend.py`), and a week that was not executed gets diagnostics, never a
  cut; **every clamp is recorded, never hidden**.
- **There is an absolute calorie floor.** Neither generation nor recalibration may set a
  target below a sex-derived floor (**1,500 kcal men / 1,200 kcal women**, engine tunables
  `calorie_floor_male` / `calorie_floor_female`, shared by `build_recal_inputs`), even when the
  arithmetic would land lower for a small body.
- **Tested, not asserted.** The rails are covered by golden tests:
  `services/api/tests/test_recommend.py` (the deficit clamps to the IP's range and the floor
  holds, both reported) and `services/api/tests/test_protocol_engine.py` (the floors, the
  deficit cap, every persona). These run on every push and are referenced here so a reviewer
  (or a future engineer) can confirm the claim is enforced, not just stated.

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

- No tracking, no third-party ad/analytics SDKs, no remote push notifications (coaching
  reminders are local notifications the app schedules on the device from a plan the server
  returns).
- Data collected (all linked to the account, none used for tracking, all for app
  functionality): voice audio, meal photos the person chooses to log, health/nutrition (meals,
  macros, intake), fitness (bodyweight, activity), account identifier, and an email address if
  provided via Sign in with Apple. Apple Health active energy is read on the device and never
  sent, so it is not a collected data type.
- Full mapping in `docs/app-store/APP_PRIVACY.md`; it is kept in lockstep with
  `apps/ios/VoCal/PrivacyInfo.xcprivacy` and the App Privacy form.
- Privacy policy and support pages: see `TESTFLIGHT_RUNBOOK.md` step 4 for the live URLs.

---

## "What to Test" (for the external Concierge Beta group)

> First build — please: (1) complete onboarding, (2) log three meals by voice, (3) tell us
> about any moment where the app's claim felt like a lie — anywhere it said it heard you,
> saved, or logged something and you weren't sure it actually did.
