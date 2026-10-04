# Handoff, 2026-10-04: the personalized tracker, built on `claude/confident-volta-7er84f`

What this session built, what it proved, and what it could not prove from a Linux box with no
Xcode. Read with `.claude/plans/phase-p-personalized-tracker.md` (the plan, ticked) and
`docs/design/personalized-tracker-spec.md` (the Rams review and the corrected design).

## What landed (one commit per task, in order)

| Task | Commit | What it is |
|---|---|---|
| P0 | `c6e1626` | Decisions 56 to 64 taken as recommended; the brief, the master plan, memory. |
| P1, P2 | `ddd63cf` | `tracking_preferences` (append-only, RLS), the tracking domain, `tracking/projection.py` (the one place that says what a mode shows), `meals/dashboard.py` (the server composes Today's `panels`), `mode` on parse and generate, `reveal` on the protocol, the week plan's adjusted day on Today (D6). |
| P5, P6 | `76d7ded` | One nudge engine: the legacy bank's situational moves ported, every nudge naming its modes, the ladder as an invitation card with a permanent decline; the legacy endpoint deleted. |
| P7 | `38e9527` | Recalibration runs the v2.0 titration and revise recomputes the whole protocol. |
| P10 | `0356bed`, `4d166ad` | `GET /account/export` (JSON, CSV for meals); Settings → Export my record. |
| P3 | `9df077d` | Sugar and sodium as optional nutrients on the whole path, shown only on a focus tile. |
| P4 | `354546e` | The iOS half: the first question, the mode-aware intake and reveal, Today drawn from the server's panels, the mode governing every printed number, Settings → How I track, the invitation card's answers. |
| P9 | this commit | Every surface states the same headline. |

## What is proven

- `scripts/check-api`: 903 passed, ruff clean, at every commit.
- `scripts/parser-eval`: SCORES unchanged.
- Every Swift file touched balances; every changed signature's call sites were checked by hand;
  CI's iOS job (compile, render, flow, voice) is green on the head commit.

## What is NOT proven, and what to run first

1. **The iOS app was compiled by CI, not here.** This environment has no Swift toolchain; CI's
   iOS job on `0538dd5` (run 37173632708) compiled it at zero warnings and ran the render tests
   (goldens skipped on that runtime, the blank guard and the pure-function tests ran), the capture
   flow tests and the twelve voice scenarios. Green on the first run. The local loop has not seen it.
2. **The new goldens are not recorded.** `testTodayPerMode`, `testTodayHabitsEmptyAndFocusWrap`,
   `testProtocolRevealPerMode`, `testTrackingModeChooserAndHowITrack`, `testInvitationCard`,
   `testVoiceLogResultHabits` need `RECORD_SNAPSHOTS=1 bin/ios-render-tests` once, on the pinned
   simulator, and a human reading `/tmp/ui/*.png` before the goldens are committed. On CI they
   skip the golden compare (another runtime) and still prove the pages render.
3. **The habits reveal is variant a** (counts shown: "Your habits · Three things, every day.",
   Water 96 oz, Produce 6 a day, Logged today "Every day"). The plan asked for both variants to be
   drawn and judged from the renders. Variant b (counts withheld) is a two-line change in
   `ProtocolRevealView.row(_:_:)`; draw it before deciding, as spec R12 asks.
4. **The accessibility audit baselines** (`AccessibilityAuditTests.baseline`) were counted on the
   five's old layout. The five's panels reproduce it element for element (same fonts, same tiles,
   no support line under a reach tile), so the counts should hold; the nightly `ui-audit` job says.
   Habits, calories and macros have no baseline yet: add a page per mode when the counts exist.
5. **The migration** `20261004000001_tracking_preferences.sql` is applied by Deploy or by
   `make db-migrate`, never by an agent. Until it is applied, `GET /tracking` returns the default
   (the five) and `PUT /tracking` fails; the app's writes are fire-and-forget, so onboarding still
   completes and Today shows the five.
6. **The five's Today looked identical before and after on paper**: the server now sends no
   support line under a reach tile (the tile prints "72 / 96 oz" itself) and the protein line as
   its status ("12 g to optimal", "In your optimal range", "4 g over optimal"), which is what the
   client computed before. Confirm with `testTodayPopulated` against its existing golden.

## Where things live now

- Mode and focus: `services/api/src/api/tracking/` (schemas, store, router, projection);
  `apps/ios/VoCal/Services/TrackingModels.swift`, `Services/Protocols/TrackingService.swift`.
- The composed dashboard: `meals/dashboard.py` (server); `Views/Today/Panels/PanelView.swift`
  (draws a kind), `PanelComposer.swift` (the mock's and the one-deploy-behind fallback's twin).
- The chooser: `Views/Onboarding/TrackingModeChooser.swift`, used by `IntakeFlowView` (first step)
  and `Views/Settings/HowITrackView.swift`.
- Invitations: `nudges/invitations.py`; the card's answers in `NudgeCardView`, the writes in
  `NudgeCenter.acceptInvitation` and `declineInvitation`.
- The sim: `-TrackingMode <habits|calories|five|macros>` composes for one mode; otherwise
  Settings → How I track changes the stored mock preference.

## Open for Lorenzo

- D1 (the name): three tests only Lorenzo and Francesco can run. The method's name goes in one
  place when it settles, `ProtocolSettingsView` (the comment marks the line).
- D5 (the meal plan): P8 is not built; the option is absent from the chooser until it is.
- R12 (the habits reveal): variant a is built; the renders decide.
