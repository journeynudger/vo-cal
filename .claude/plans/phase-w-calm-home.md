# Phase W: the calm home, the bubbles and the one chat

> Status: Built 2026-11-06 on `rebuild/calm-home` (decision 75; spec `docs/design/calm-home-spec.md`).
> Next: W9 on a device.

Lorenzo, 2026-11-06: "reinvent the entire app"; "the onboarding should have the bubbles";
"the home should say log meal"; "in just a single chat they should be able to see what they
need"; "show the history of meals logged like MyFitnessPal"; "can't scan QRs"; "start
referencing the new logging db" (FatSecret, live on Fly, read for barcodes). The capture
core, the server's composition and the claim ladder are untouched; the surfaces are new.

## Tasks

- [x] W1 The bubbles: `GoalBubblesStep`, `GoalPriorities` (pure derivation), `BubbleCloud`; the intake opens on them, the goal question goes, the mode is offered and confirmed. `IntakeDraft.priorities`, `.focus`; the welcome on the wash.
- [x] W2 The home: `HomeView`, `MealDiary`, `TodaySummaryCard`, `HomeBar`; the greeting, the one line, the diary by slot, the ask row, the pill. `TodayView` becomes Progress.
- [x] W3 Log a meal: `LogSheet` (Speak, Type, Photo, Scan, usuals, water); the shell presents each way with the slot; a usual carries its slot (`TodayViewModel.logUsual(_:mealType:)`).
- [x] W4 The chat: `ChatThreadModel`, `ChatView`, `MealResultCard`, `ReceiptCard`, `ChatAnswerCard`, `FailureCard`; `VoiceLogViewModel` seeded with the thread and read through `currentThread`; `keepsOutcomeOnClose` on the voice sheet; the bar's menu grows "Scan a barcode"; `-StartOnChat`.
- [x] W5 The barcode, server: `GET /foods/barcode/{code}` (`foods/barcode.py`: FatSecret `food.find_id_for_barcode` when configured, Open Food Facts otherwise, cached under `bc:<gtin13>`); `SaveLabelFoodRequest.barcode`/`brand` as provenance; 37 tests.
- [x] W6 The barcode, phone: `BarcodeScannerView` (VisionKit), `ScannedFoodSheet`, `BarcodeService` (live and mock), `APIClient.barcodeFood`; logged as a label food through `logServing`.
- [x] W7 The loops: render tests for the welcome, the bubbles, the home, the log sheet, the chat, the scanned food; the flow tests on the chat; the audit on the home, Progress and the chat; the motion loop on the home. `scripts/check` green, `bin/ios-app-build` zero warnings.
- [x] W8 The goldens re-recorded on iOS 26.2 (the goldens' 26.5 runtime is gone from the Mac; `chore/goldens-ios-26-2` re-pins the rest) and the audit's baselines measured on the same runtime (home 31/28/0, Progress 31/20/4, chat 7/2/1; Settings' contrast moved 6 to 7 with the runtime). Still open: the motion budgets re-measured on the home (`bin/ios-motion`).
- [ ] W9 On a device: a spoken meal from the chat, a scanned package through FatSecret (the barcode method may need a plan or scope the account lacks; Open Food Facts answers meanwhile), a photo from the log sheet, the camera permission's fallback.
- [ ] W10 Build 34 through the publish skill once W8 and W9 pass; the bump lands on main.

## Decisions left to Lorenzo

- D1 The diary's hour boundaries for a slot-less meal (10:30, 14:30, 17:00) are a reading, not the method's; move them if Francesco's clients eat on another clock.
- D2 The chat is kept for the session; a thread that survives a relaunch would need storage decision 71 refused.
- D3 The old Today's capture bar is gone from the home; if voice must be one tap from the home again, the pill could open the capture directly and the sheet move behind a long-press.

## Progress log

| Task | Commit |
|---|---|
| W5 | `eda3eb1` feat(api): a packaged food from its barcode |
| W6 | `c525bf8` feat(ios): the barcode scanner and the scanned food |
| W1, W2, W3, W4 | `b353ee1` feat(ios): the calm home, the bubbles and the one chat |
| W7 | `49b1cdf` test(ios): the loops follow the home and the chat; goldens on iOS 26.2 |
| docs | `13bf676` docs: decision 75, the calm-home spec, phase W, the handoff |
| W8 | (next commit) test(ios): the audit's baselines, measured |
