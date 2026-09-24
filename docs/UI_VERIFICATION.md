# UI verification

How a screen is proven to look right, in two loops, and how the proof is reported.
Rules are adapted from the iOS UI verification rules Lorenzo shared on 2026-09-24; where a
rule does not fit this product the adaptation and its reason are written down below.

## The fast loop: `bin/ios-render-tests` (seconds)

Every screen and component is rendered to a PNG inside a unit test hosted by the app on the
pinned simulator (`apps/ios/VoCalRenderTests`), written to `/tmp/ui/<name>.png` for reading,
and compared to its committed golden in `apps/ios/VoCalRenderTests/__Snapshots__/RenderTests`.
About 20 s warm, about 60 s after a clean build. Read the PNGs: the loop proves a golden
matched, a human proves the golden is right.

| Test | What it proves |
|---|---|
| `testMealItemCardStateMatrix` | The item card in five states (confirmed, needs attention, counted as, one of your foods, a long name) at Dynamic Type large, xxxLarge and accessibility2 |
| `testVoiceLogResultConfirmed`, `testVoiceLogResultWithChecks` | The result screen with every item confirmed, and with three open checks, the running total and the pinned bar |
| `testLabelFoodSheet`, `testBatchFoodSheet`, `testPersonalFoodsList` | The personal-food sheets and the list (two foods, empty) |
| `testTodayPopulated`, `testTodayEmptyAtAccessibilitySize` | Today with a full day, and empty at accessibility2 |
| `testWeekMiniBarsGeometry` | `WeekMiniBars.geometry(for:)` is a pure function of the budget: floors, goal frames, headroom |
| `testWeekMiniBarsPixelsMatchGeometry` | The bars on screen are the geometry: filled heights read back from pixels equal the numbers |

The harness (`RenderHarness.swift`) is deterministic by construction: 393 pt wide at 3x, an
opaque background from `VoCalTheme` behind any material, animations disabled, light
appearance, an injected Dynamic Type size, fixed dates, standard-range sRGB. Views are hosted
in a real window attached to the app's scene and drawn with `drawHierarchy`; a blank image
throws instead of recording.

### What it took to make the loop honest (2026-09-24)

- **`ImageRenderer` draws nothing inside a `ScrollView`.** The first goldens of Today, the
  result and the sheets were blank pages and the tests passed against them. Fix: window
  hosting plus a blank guard that samples the image and fails when nothing differs from
  the first pixel. A loop that cannot see the content is worse than none.
- **A 2x context does not shrink the goldens, it resamples them.** `drawHierarchy` from a
  3x window into a 2x context made every pixel unique (7.6 MB against 6.4 MB) and the result
  screen stopped matching itself. Goldens are 3x, the simulator's own scale.
- **Liquid Glass is not pixel-stable.** The result screen's glass close button moves
  332 to 709 pixels (0.006 to 0.012 percent) by up to three levels between two renders of
  the same view. Byte identity therefore fails at random.
- **The library's colour compare had a baseline.** With the renderer's default extended
  range, an identical render still showed 0.22 percent of its pixels beyond the colour
  threshold whenever the byte compare did not short-circuit. Standard-range sRGB on the
  renderer removed the baseline (PNG goldens decode to sRGB).
- **Tolerance, measured not guessed:** `precision 0.999` (one pixel in a thousand may
  exceed the colour threshold), `perceptualPrecision 0.98` (a CIE delta E of 2). The proof
  below shows what a real bug moves against that floor.
- **`bin/png-diff a.png b.png`** says where two renders differ, in points, and writes a
  difference image; `PNG_DIFF_THRESHOLD=0` demands identity.

### Goldens are read-only

The record mode is `.never` (`SnapshotPolicy.swift`); `RECORD_SNAPSHOTS=1 bin/ios-render-tests`
re-records, and the commit says why. Never re-record or loosen a tolerance to make a test
pass; a drift is either a bug or an intended change, and the PNG in `/tmp/ui` says which.
The goldens carry the runtime that drew them (`__Snapshots__/RUNTIME.txt`, "iOS 26.5 ·
iPhone 17 Pro · 3x"); on any other runtime the golden assertions skip out loud (`XCTSkip`)
and the geometry, pixel round trip and blank guard still run. That is what CI does today:
the runner's Xcode 26.2 carries another iOS, so CI proves the non-golden tests and the local
loop proves the goldens. The eleven goldens weigh 6.4 MB; move them to git LFS if they pass
about 30 MB.

## The slow loop: `bin/ios-ui-audit` (minutes)

The real app in mock mode (`-UITestMode`) on the simulator, driven by
`apps/ios/VoCalUITests`: Xcode's `performAccessibilityAudit()` on Today and on the Settings
pages (My foods, Learned names, Recently deleted), and the Home and Profile tab buttons
proven to exist, be hittable and be on screen. Nightly in CI (`ui-audit` job) and on
demand; by hand before a build ships. Its result bundle is uploaded when it fails.

The audit is a ratchet, like the tidy tables: every issue prints as
`AUDIT <page> <type>: <issue> [<element>]`, the counts per page and type are compared to
the baseline committed in `AccessibilityAuditTests.swift`, a count above its baseline
fails, a count below it prints "lower the baseline". Categories with no baseline (clipped
text, missing descriptions, traits, element detection) fail on the first occurrence.
First inventory (2026-09-24, build 29), on Today: 36 labels flagged for Dynamic Type (every
theme font is a fixed point size), 31 contrast issues (the muted ink on cream), 6 hit areas
under 44 pt (the water card and its numbers, the pro-tip toggle, the selected day chip, the
protein card); the four settings pages add 38, 23 and 5. The fonts and the contrast are decisions 12 and 13 in
`docs/restructure/05-questions.md`; the hit areas are finding 29 in `04-findings.md`.

## Motion and latency: `bin/ios-motion` (minutes, local)

A still frame cannot show a stutter, an abrupt transition or a late response, and those were
most of what read as janky (Lorenzo, 2026-09-24). `apps/ios/VoCalUITests/MotionTests.swift`
drives the real app in mock mode through three scenarios and measures them with XCTest's own
metrics: scrolling Today (hitches per second of scroll and deceleration, `XCTOSSignpostMetric`),
opening and closing the voice capture (tap to first response, `XCTClockMetric`, and the
transition's hitches), typing into the bar (the keyboard's transition and the results panel).
Each scenario keeps a baseline in the test plan; a run 10 percent worse fails. While the
tests run, `bin/ios-motion` records the simulator and tiles the recording into filmstrips
(`.tmp/motion/<stamp>/filmstrip-*.png`, ten frames a second, six by four) for the outside
critic below. Local and on demand, before a build ships; not on every push (the metrics
need a real GPU and a quiet machine, and a flaky motion gate would be ignored).

First run (2026-09-25, build 30, the pinned simulator): scroll deceleration 1.02 s, drag
and deceleration 1.24 s, tap to the capture sheet 2.16 s, tap to the typed results 2.33 s
(the clock includes XCUITest's own polling, so the budget is a regression guard, not a
latency claim). Budgets in `apps/ios/VoCalUITests/motion-budget.txt`: 1.4, 1.7, 3.0, 3.0.

## The flows: `bin/ios-flow-tests` (a minute, in CI)

Build 30 went to the phone with the keyboard holding the page hostage, the plus's menu
unreachable behind a near miss, and the mic jumping as a capture started, and every render
and every metric was green: none of them drives the bar. `apps/ios/VoCalUITests/CaptureFlowTests.swift`
does, on the real app in mock mode, and asks only objective questions: does a tap on the
page put the keyboard away; does the mark with nothing to send; does the plus open Camera
and Photos and a tap on the page close them; does a tap fourteen points above the plus open
nothing; and, sampling the big mic's frame forty times through "Starting" and "Listening",
does its centre move less than a point (the app is launched with `-SlowMockCapture`, so the
mock's rungs last long enough to sample: six seconds arming, a word every two). It runs in
CI's iOS job after the render tests
(Lorenzo, 2026-09-24: automate what is objective, important and likely to break again; each
of these has). A flow that needs a real camera, a real photo library or a real mic stays
with NEEDS HUMAN EYES.

The flow tests tap by synthesized touch (`XCUICoordinate.tap()`), never by an accessibility
activation, and this is the whole point: the simulator tool's tap and a VoiceOver double-tap
activate a control through accessibility, so a control that takes no touch at all passes
every hand check. The plus did, for a build (finding 44). Where a touch lands can be mapped
with a `SpatialTapGesture` marker on the page beneath the control, which is how the plus was
caught, and a launch-argument variant switch bisects a control's recipe in one run.

## The outside critic: `bin/ui-critic` (bounded)

The agent that just built a screen should not grade its own screenshots: images are
token-heavy and a builder is inclined to call it done. `bin/ui-critic` sends renders or
filmstrips with a written spec to a vision model from another family (OpenAI; the key comes
from the environment or `.env`) and writes the critique to a file the agent reads as text:
defects in order of severity with the point sizes it would change, the motion judged from a
filmstrip, what the spec asks for that the render does not deliver, and a verdict (SHIP, SHIP
WITH FIXES, NOT YET). It runs a bounded number of times per pass (three rounds), never in a
loop that ends only when the critic is silent; what the third round still flags is recorded
with the pass, not chased.

### The critic's rounds on the overhaul (2026-09-25)

Round one (NOT YET / SHIP WITH FIXES) found, and the pass fixed: "547+" and "35g+" plus
signs; a flame beside the calories number; "Tap a flagged item ... reach 100%" copy; a
floating "?" on check cards; option chips under 44 pt; the Save-as-usual toggle crowding
the pinned bar; the tip card's sparkle and its tiny close; a mic glyph in the empty state;
the Usuals title in a different face from "Logged today"; chips clipped at the margin;
search calories in ink rather than muted; a 76 pt staged photo; the Action button card's
five-line body; the Health step's three-line body. Round two (SHIP WITH FIXES) found the
usuals row clipping, row spacing and the row calories' weight; fixed.

Round three (the last, NOT YET) repeated the standing notes below and the harness's own
artifacts (a bar drawn on its own scene, a canvas taller than a screen), and left two notes
for the next pass: the tip card's gold border reads as an alert at accessibility sizes, and
the three small tiles want 8 to 12 pt more height. Neither blocks a build.

What the critic still flags and why it stays (recorded, not chased):

- The week strip's chevrons: they are the visible twin of the page-a-week pull and the way
  back to today; the strip alone gives no sign that history exists.
- "avg 95% sure" beside "Logged today": Lorenzo asked for it (2026-08); confidence is the
  product's thesis, not noise.
- The macro colours (protein red, carbs amber, fats blue): a locked design rule
  (docs/DESIGN.md), and the result's macro chips are how a person checks the split.
- The protein band's marker: the optimal range is a range, and the marker is where you are
  in it; a plain bar would say less.
- The glass circles reading "flat white with a shadow": a render has no content behind the
  glass to refract; on the phone the same circle is glass.
- Type "too large" and the pill "88 pt": the critic reads a 3x render at about twice its
  point size; the faces are 13, 15, 17 and 30 pt and the pill 52 pt (docs/DESIGN.md).
- The header and week strip not scaling at accessibility sizes: decision 12 in
  docs/restructure/05-questions.md, still open.

## The filmstrip: `bin/ios-filmstrip` (needs ffmpeg)

Records the simulator with a clean status bar and tiles the frames into one image with
ffmpeg (`brew bundle` installs it). Exits 2 with the brew hint when ffmpeg is absent.

## Adapted, and why

- **Light only.** Vo-Cal ships light mode only (DESIGN.md), so there is no dark matrix.
- **No waveform.** The mic surface is a timer and a transcript; the data-driven round trip
  (rule 6) is applied to the week mini bars instead: pure geometry, then pixels read back.
- **No RTL or long-locale sheet.** The product is English only in P0; add the matrix with
  the first localisation.
- **`-UITestAudioFile` deferred.** The capture path is protected (AGENTS.md, capture-path
  isolation) and `bin/ios-sim-voice-test` already runs twelve scenarios through the real
  runtime; a file-fed recorder would add a second path into the mic-hot code for a proof
  the scenarios already give. Revisit if a transcript-shape bug ever escapes them.
- **Dynamic Type matrix** is large, xxxLarge and accessibility2 (plus Today at accessibility2),
  not every step: those three are where layout breaks, and the state matrix stays readable.

## Proof of the loop (2026-09-24)

Three bugs were planted in `MealItemCard` behind `DEBUG` and `VOCAL_UI_SABOTAGE=1`: the
name row moved 4 pt down, the name limited to one line (the long-name variant truncates),
and the macro line zeroed ("0P  0C  0F"). Then `TEST_RUNNER_VOCAL_UI_SABOTAGE=1
bin/ios-render-tests`:

| Golden | Pixels matching (floor 0.999) | Lowest colour precision (floor 0.98) | Result |
|---|---|---|---|
| state matrix, large | 0.9095 | 0.40 | failed |
| state matrix, xxxLarge | 0.9380 | 0.40 | failed |
| state matrix, accessibility2 | 0.9317 | 0.40 | failed |
| result, confirmed | 0.9962 | 0.40 | failed |
| result, with checks | 0.9982 | 0.40 | failed |
| Today, sheets, list, bars | unchanged | | passed |

Five failures, five passes, exactly the screens that show the card. The planted code was
then removed (`git checkout` of the file; zero mentions left) and the loop ran green again.
Five verify runs before the proof were green with zero mismatches each.

What the numbers say about resolution: the same three bugs move 6 to 9 percent of the
state matrix but only 0.18 percent of the result screen with checks, where a single
confirmed card shows. A bug confined to one card on the tallest screen sits close to the
floor; the state matrix is where a card bug is loud, so every card state has a place there.
Add a state to the matrix before trusting the tall screens to catch it.

## Reporting UI work

Every UI claim in a report carries one of three grades:

- **VERIFIED**: a loop proved it; name the loop and the golden or test.
- **INFERRED**: reasoned from code or from a neighbouring render, not rendered itself.
- **NEEDS HUMAN EYES (DEVICE)**: only a phone can tell (haptics, glass over real content,
  the mic, Dynamic Type with the system setting, notch and home-indicator insets).

Never claim a state above its proof (AGENTS.md MUST-NOT 6 applies to reports as much as to
screens).
