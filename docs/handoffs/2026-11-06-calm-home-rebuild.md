# Handoff, 2026-11-06: the calm home, the bubbles and the one chat

Lorenzo's ask: reinvent the app around what each person needs; the bubbles in the onboarding;
a home that says "Log a meal" and then offers the mic, the camera, the keyboard and the scanner;
one chat where the person sees what they need; the day as MyFitnessPal reads it (breakfast,
lunch, dinner, snacks); barcodes that work against "the new logging db" (FatSecret, whose
credentials are live on Fly); calm and clean, on the house palette. Built on `rebuild/calm-home`
from main at `1aed38b`, in a worktree, nothing pushed. Decision 75; the design is
`docs/design/calm-home-spec.md`; the plan is `.claude/plans/phase-w-calm-home.md`.

## What was built

| Area | Files | Notes |
|---|---|---|
| The bubbles | `Views/Onboarding/GoalBubblesStep.swift`, `IntakeFlowView.swift`, `IntakeModels.swift`, `OnboardingFlowView.swift`, `WelcomeView.swift` | `GoalPriorities.derived` is pure and pinned by a render test; the mode is offered on "What you'll see" and confirmed there |
| The home | `Views/Home/HomeView.swift`, `MealDiary.swift`, `LogSheet.swift`, `VoCalApp.swift` (the shell, `HomeBar`) | `TodayView` is Progress behind the summary card; the capture bar left the home |
| The chat | `Views/Chat/ChatThreadModel.swift`, `ChatView.swift`; `VoiceLogViewModel` (`thread:` seed, `currentThread`); `VoiceLogView` (`keepsOutcomeOnClose`); `CaptureBar` (the scan row); `RuntimeMode.startsOnChat` | Every turn's engine is the voice-log model; the thread is session memory only |
| The barcode, server | `services/api/src/api/foods/barcode.py`, `foods/router.py`, `foods/schemas.py`, `nutrition/fatsecret_client.py` (`resolve_barcode`), `tests/test_barcode_api.py` | FatSecret's `food.find_id_for_barcode` when configured, Open Food Facts otherwise, cached under `bc:<gtin13>`; 37 tests, `scripts/check-api` 1,234 passed |
| The barcode, phone | `Services/BarcodeModels.swift`, `Services/Protocols/BarcodeService.swift`, `Views/Capture/BarcodeScannerView.swift`, `ScannedFoodSheet.swift`, `APIClient.barcodeFood`, `SaveLabelFoodRequest.barcode/brand` | VisionKit; the simulator opens on the manual door with a sample code in DEBUG |
| The loops | `VoCalRenderTests/RenderTests.swift`, `VoCalUITests/*` | Render tests for every new screen; the flow tests launch on the chat; the audit covers the home, Progress and the chat with first-inventory baselines |

## How it was tested

- `bin/ios-app-build` zero warnings; `scripts/check` green (tidy ratchets, SPM tests, the API).
- A throwaway iPhone 17 Pro on iOS 26.2 ("VoCal Rebuild"), in mock mode, by hand through the
  simulator tool: the welcome, the bubbles grown and the mode offered from them, the home with a
  full day and its diary, the log sheet, the chat (a typed meal to its card and receipt, "Show
  my calories" to the calories card, the mic to the voice sheet and back to a receipt, the plus
  menu to the scanner, a sample barcode to the scanned sheet and its receipt), Progress.
- Not run here: `bin/ios-render-tests` with goldens (see W8), `bin/ios-ui-audit` (the baselines
  are a first inventory to be measured), `bin/ios-motion`, `bin/ios-flow-tests`, a device.

## For the next session

- **W8, the goldens.** The goldens' runtime (iOS 26.5) is gone from this Mac; record on the 26.2
  pin (`IOS_SIM_UDID=AE70CA64-697D-416D-8AE4-2F11334322B5 RECORD_SNAPSHOTS=1 bin/ios-render-tests`)
  and read every PNG in `/tmp/ui`. `chore/goldens-ios-26-2` re-pins the rest of the suite; land
  one of the two first and re-record on the other.
- **The audit's baselines** in `AccessibilityAuditTests.swift` are a first inventory, written
  before a run; measure and lower or raise them in the same commit, said out loud.
- **FatSecret's barcode method** may need a plan or scope the account lacks; one live call
  through `scripts/food-source-eval` settles it, and Open Food Facts answers meanwhile.
- **Existing accounts** skip the bubbles (`vocal.onboarded` stands); their home shows no
  priorities sentence until they grow bubbles, which has no door yet (Settings → How I track
  could hold one).
