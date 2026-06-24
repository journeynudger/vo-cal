# App Privacy — Vo-Cal

The answers to enter in App Store Connect → App Privacy. **Keep this file, `PrivacyInfo.xcprivacy`,
and the actual code in lockstep** — if one changes, change all three (Beacon's discipline).

## Tracking

- **Used to track you across apps/sites owned by other companies?** No.
- **Third-party advertising / analytics SDKs in the binary?** None.
- `NSPrivacyTracking = false`, `NSPrivacyTrackingDomains = []`.

## Data collected

All collected data is **linked to the user's identity** and used **only for app functionality**;
**none is used for tracking**.

| Data type | What | Why | Linked | Tracking |
|---|---|---|---|---|
| Audio Data | Voice recordings captured while logging a meal (ground-truth audio) | App functionality (transcription, audit, re-transcription) | Yes | No |
| Health | Meals, macros, intake answers (diet/nutrition) | App functionality (the food log + protocol) | Yes | No |
| Fitness | Bodyweight + activity from intake and weekly check-ins | App functionality (protocol targets, recalibration) | Yes | No |
| User ID | Account identifier (Sign in with Apple / anonymous) | App functionality (account, tenant isolation) | Yes | No |
| Email Address | May be provided by Sign in with Apple (often a private relay) | App functionality (account) | Yes | No |

Not collected: precise/coarse location, contacts, browsing history, financial info, advertising data.

## Where it lives & who can see it

- Stored in the project's Supabase (Postgres + Storage); all rows are account-scoped by RLS.
- Audio is retained as immutable ground truth (transcripts/parses are derived from it).
- **During the concierge beta, admins may review user data** to improve the parser/dictionary —
  this is disclosed in the privacy policy.
- No data is sold or shared with third parties for their own use. Transcription (ElevenLabs) and
  parsing (the configured LLM provider) are processors acting on the audio/transcript only.

## Data rights

- **In-app account deletion** (Settings → Delete account → `DELETE /account`): permanently deletes
  the user's rows (cascade from the auth user) and their audio blobs. Re-signup is a clean slate.

## Required-reason APIs (PrivacyInfo.xcprivacy)

- `NSPrivacyAccessedAPICategoryUserDefaults` — reason `CA92.1` (the app's own settings, e.g. the
  onboarding flag via `@AppStorage`).
- `NSPrivacyAccessedAPICategoryFileTimestamp` — reason `C617.1` (timestamps on capture files inside
  the app container, for the outbox/observability — used by the app, not shared).

## Permission strings (Info.plist)

- `NSMicrophoneUsageDescription` — "Vo-Cal records your voice only while you log a meal, to turn
  what you say into your food log." (the only sensitive-permission prompt)
- `ITSAppUsesNonExemptEncryption = false` (standard HTTPS only).

## URLs (App Store Connect)

- Privacy Policy: `https://<host>/privacy.html` (from `services/web/privacy.html`)
- Support: `https://<host>/support.html` (from `services/web/support.html`)
- Both must be live before Beta App Review submission (I5/I6 deploy step).
- TODO(lorenzo): fill `<host>` with the deployed pages host once it is live (runbook step 4).

## Three-way agreement (form ↔ xcprivacy ↔ code)

Beacon's discipline: the App Privacy form, `PrivacyInfo.xcprivacy`, and the code must all say
the same thing. This is the audit table. If any cell changes, change all three columns.

| App Privacy form data type | `PrivacyInfo.xcprivacy` constant | Where the code collects it | Linked / Tracking / Purpose |
|---|---|---|---|
| Audio Data | `NSPrivacyCollectedDataTypeAudioData` | Voice capture during meal logging (uploaded as ground-truth audio to Storage) | Linked: Yes · Tracking: No · App Functionality |
| Health | `NSPrivacyCollectedDataTypeHealth` | Meals/macros + diet intake answers (`meal_logs`, `parses`, `intake_responses`) | Linked: Yes · Tracking: No · App Functionality |
| Fitness | `NSPrivacyCollectedDataTypeFitness` | Bodyweight + activity from intake & weekly check-ins (`checkins`, `profiles`) | Linked: Yes · Tracking: No · App Functionality |
| User ID | `NSPrivacyCollectedDataTypeUserID` | Account id from Sign in with Apple / anonymous session (Supabase auth) | Linked: Yes · Tracking: No · App Functionality |
| Email Address | `NSPrivacyCollectedDataTypeEmailAddress` | Provided by Sign in with Apple (often a private relay) | Linked: Yes · Tracking: No · App Functionality |

**Not collected** (do not add to the form): Phone Number, Precise/Coarse Location, Contacts,
Browsing History, Search History, Purchases/Financial Info, Advertising Data, Diagnostics/Crash
Data sent to our servers, Device IDs, Sensitive Info beyond the health/fitness above.

> **Note on phone number.** An earlier Phase-I planning draft listed "phone number (auth)" as a
> collected type. The shipped auth is **Sign in with Apple + anonymous sessions** — there is no
> phone/SMS/OTP path in the iOS app or the API (verified: no phone field in
> `apps/ios/VoCal/**` or `services/api/src/**`). So phone number is **not** collected and must
> **not** be declared on the form. If a phone-based auth path is ever added, add Phone Number
> here, in `PrivacyInfo.xcprivacy`, and on the form together.

## Reviewer-facing context

The reviewer notes (`docs/app-store/REVIEW_NOTES.md`) restate the voice-logging scope, the
not-medical-advice posture, the disclosed admin beta review, the account-deletion location, and
the anonymous demo path. Keep this file and that one consistent on what data exists and who can
see it.
