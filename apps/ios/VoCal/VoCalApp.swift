import PhotosUI
import SwiftUI
import VoCalCore

@main
struct VoCalApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Lane bookkeeping only — must stay this thin. The voice coordinator bootstraps
        // lazily on scene-active/toggle so nothing (recovery scan, outbox open, telemetry)
        // sits in front of app launch or the mic-hot path (capture-path isolation,
        // Vo-Cal AGENTS.md; Serein paid three production incidents for eager launch work).
        AppRuntimeCoordinator.shared.observeLaunch()

        // C3 self-test entry (launch-argument form). startIfRequested self-gates on
        // `--self-test-run-id` — it is a no-op on every normal launch, so it stays off
        // the capture path entirely (Vo-Cal AGENTS.md capture-path isolation). The flag,
        // not a URL, is the primary mechanism so bin/ios-sim-voice-test needs no
        // CFBundleURLTypes round-trip through SpringBoard. (URL form below is parity with
        // Serein's serein://self-test for manual/interactive runs.)
        VoiceSelfTestRuntime.shared.startIfRequested()

        // Two registrations the system requires before launch completes, both closures stored
        // and no work done (decision 67). The notification delegate: a "Log it" pressed on a
        // notification that launches the app cold is delivered to whatever delegate exists at
        // launch, or dropped; set later (as it was, on the first log) it never arrived. The
        // background refresh: BGTaskScheduler refuses a registration after launch. Neither
        // touches the capture path; the first real work is a plan fetch from Today.
        NudgeNotificationService.shared.attach()
        NudgeBackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            RootRouterView()
                .onOpenURL { url in
                    // vocal://self-test/voice?run_id=…&scenarios=… — manual self-test
                    // trigger. handleOpenURL ignores anything that is not the self-test
                    // host, so registering the scheme costs the capture path nothing.
                    VoiceSelfTestRuntime.shared.handleOpenURL(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            AppRuntimeCoordinator.shared.publish(.scenePhaseChanged(AppScenePhaseValue(newPhase)))
            if AppRuntimeCoordinator.shared.shouldRunForegroundShellTasks() {
                // Scene-active drives the crash-recovery scan (Serein wiring preserved):
                // recovery runs on activation observations, never on the capture start path.
                Task {
                    await VoiceCaptureCoordinator.shared.handleScenePhaseChange(newPhase)
                    if newPhase == .active, !RuntimeMode.usesMockServices {
                        await CaptureUploadWorker.shared.kick("scene_active")
                    }
                }
            }
        }
    }
}

/// Root gate: first launch runs onboarding (Welcome → intake → protocol → account), then the
/// app. `onboarded` persists across launches; UITestMode skips straight to the app so the
/// voice-loop tests reach it with zero network (Phase D acceptance). Real Sign-in-with-Apple
/// replaces the mock auth at provisioning — the gate itself doesn't change.
struct RootRouterView: View {
    @AppStorage("vocal.onboarded") private var onboarded = false

    var body: some View {
        Group {
            if onboarded || RuntimeMode.isUITestMode {
                AppRootView()
            } else {
                OnboardingFlowView(onComplete: {
                    // Stamp first: the grace window (no check-in banner, no nudges
                    // for a few days) must exist before the app shell ever renders.
                    OnboardingGrace.markOnboarded()
                    onboarded = true
                })
            }
        }
        // Lazily boot the auth client so a returning user's persisted Supabase session is
        // restored into AuthTokenStore before the first API call. A view .task (not app
        // init) keeps launch thin and off the capture-path-isolation surface; no-op on the
        // mock path. Touching `.shared` starts its authStateChanges observer.
        .task {
            guard !RuntimeMode.usesMockServices else { return }
            _ = AuthCoordinator.shared
            // Device-tz → profiles.tz sync (no-op when unchanged since the last ack).
            // Needs the restored session for its Bearer token, hence after ensureSession;
            // still fire-and-forget and entirely off the capture path.
            await AuthCoordinator.shared.ensureSession()
            await ProfileTimezoneSync.syncIfNeeded()
            // Crash evidence, after the shell: MetricKit delivers last session's diagnostics
            // to a subscriber; registering costs the capture path nothing (Phase 3.1).
            CrashDiagnosticsRecorder.shared.start()
            // The upload worker: level-triggered passes over committed captures (C4). Live
            // services only; the mock path has no backend. Attached through the commit
            // observer seam so the capture path hands over a receipt and returns.
            if !RuntimeMode.usesMockServices {
                await VoiceCaptureCoordinator.shared.setCommitObserver(CaptureUploadWorker.shared)
                await CaptureUploadWorker.shared.start()
            }
        }
    }
}

/// The shell (2026-11-06, decision 75): the home is the root, the one pill at its foot opens
/// the log sheet, and every way in (the voice capture, the chat, the camera, the scanner,
/// Progress, Settings) is a cover or a sheet the shell presents. The capture path is untouched:
/// the voice sheet is the same sheet, opened with the slot the person chose.
struct AppRootView: View {
    @State private var showSettings = false
    @State private var showProgress = false
    @State private var showChat = false
    /// The log sheet, for the section whose Add was tapped (or the clock's suggestion).
    @State private var logSheetSlot: DiarySlot?
    /// The voice capture, opened with a slot.
    @State private var speaking: SpeakRequest?
    /// A photo from the camera, on its way to the result screen.
    @State private var submission: PendingSubmission?
    @State private var cameraSlot: DiarySlot?
    @State private var scanSlot: DiarySlot?
    @State private var scannedFood: ScannedFood?
    @State private var scannedLogging: ScannedLog?
    @State private var isLoggingScanned = false
    @State private var scanError: String?
    @State private var showAddWater = false
    @State private var waterAddError: String?
    @State private var usualLogError: String?
    /// Bumped whenever a meal is logged so the home reloads (the post-log reward beat, E2).
    @State private var logCount = 0
    /// Owned here (not inside the home) so every way in reads the SELECTED day: a capture
    /// started while browsing a past day logs to that day (backdated logging, 2026-08).
    @State private var todayModel = TodayViewModel()
    /// The one chat, kept for the session (decision 75).
    @State private var chat = ChatThreadModel()
    /// The first-run tour (Beacon's coach marks, ported through Serein), What's New after an
    /// update, and the Action button card once the tour is done.
    @State private var tour = HelpTourModel()
    @State private var showWhatsNew = false
    @State private var showActionButtonCard = false
    /// What the preference changes on this page (decision 66): the bar's hint, the usual
    /// toggle's default. Read on appear and again when Settings closes; until then, today's.
    @State private var experience = Experience.composed(level: nil, frictions: [])
    /// When the person said they will log (decision 69), for the Action button card's sentence.
    @State private var logAnchor: LogAnchor?

    private struct SpeakRequest: Identifiable {
        let id = UUID()
        let slot: DiarySlot
    }

    private struct PendingSubmission: Identifiable {
        let id = UUID()
        let submission: CaptureSubmission
        let slot: DiarySlot
    }

    private struct ScannedFood: Identifiable {
        let id = UUID()
        let food: BarcodeFood
        let slot: DiarySlot
    }

    private struct ScannedLog: Identifiable {
        let id = UUID()
        let model: VoiceLogViewModel
    }

    private var barcode: any BarcodeService {
        RuntimeMode.usesMockServices ? MockBarcodeService.shared : LiveBarcodeService(api: APIClient())
    }

    private var personalFoods: any PersonalFoodsService {
        RuntimeMode.usesMockServices ? MockPersonalFoodsService.shared : LivePersonalFoodsService(api: APIClient())
    }

    /// A cover presented while a sheet is still leaving is dropped by UIKit; the sheet goes
    /// first, then the cover, a beat later.
    private static let afterSheet: Duration = .milliseconds(420)

    var body: some View {
        HomeView(
            model: todayModel,
            refreshToken: logCount,
            tour: tour,
            onProfile: { showSettings = true },
            onLog: { slot in logSheetSlot = slot ?? DiarySlot.suggested() },
            onAsk: { openChat(slot: nil) },
            onProgress: { showProgress = true },
            onLogged: { logCount += 1 }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if showActionButtonCard {
                    ActionButtonSetupCard(anchor: logAnchor) { showActionButtonCard = false }
                        .padding(.horizontal, VoCalTheme.Spacing.l)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                HomeBar(onLog: { logSheetSlot = DiarySlot.suggested() })
                    .helpTourTarget(HelpTourStep.Home.log, in: tour)
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: showActionButtonCard)
        }
        .overlay { HelpTourOverlay(model: tour) }
        .sheet(item: $logSheetSlot) { slot in
            LogSheet(
                slot: slot,
                usuals: todayModel.usuals,
                loggingUsualID: todayModel.loggingUsualID,
                printsNumbers: todayModel.dashboard?.printsNumbers ?? true,
                onSpeak: { chosen in after { speaking = SpeakRequest(slot: chosen) } },
                onType: { chosen in after { openChat(slot: chosen) } },
                onPhoto: { chosen in after { cameraSlot = chosen } },
                onScan: { chosen in after { scanSlot = chosen } },
                onUsual: { usual, chosen in logUsual(usual, slot: chosen) },
                onWater: { after { showAddWater = true } }
            )
            .presentationDetents([.fraction(0.68), .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $speaking) { request in
            VoiceLogView(
                mealType: request.slot.mealType,
                targetDate: todayModel.selectedDate,
                autoStart: true,
                onLogged: { logCount += 1 },
                saveAsUsualDefault: seedsUsuals,
                onOpen: { surface in open(surface) }
            )
        }
        .fullScreenCover(item: $submission) { pending in
            VoiceLogView(
                mealType: pending.slot.mealType,
                targetDate: todayModel.selectedDate,
                submission: pending.submission,
                onLogged: { logCount += 1 },
                saveAsUsualDefault: seedsUsuals,
                onOpen: { surface in open(surface) }
            )
        }
        .fullScreenCover(item: $cameraSlot) { slot in
            CaptureCameraView { data in
                Task {
                    let upload = await CapturePhotoEncoding.uploadJPEG(from: data)
                    submission = PendingSubmission(submission: .photo(upload, note: nil), slot: slot)
                }
            }
        }
        .fullScreenCover(item: $scanSlot) { slot in
            BarcodeScannerView(
                onFound: { code in
                    scanSlot = nil
                    Task { await lookUp(code, slot: slot) }
                },
                onClose: { scanSlot = nil }
            )
        }
        .sheet(item: $scannedFood) { found in
            ScannedFoodSheet(
                food: found.food,
                printsNumbers: todayModel.dashboard?.printsNumbers ?? true,
                onLog: { servings in Task { await logScanned(found, servings: servings) } },
                onClose: { scannedFood = nil },
                isLogging: isLoggingScanned
            )
            .presentationDetents([.fraction(0.8), .large])
        }
        .fullScreenCover(item: $scannedLogging) { logging in
            VoiceLogView(model: logging.model, onLogged: { logCount += 1 })
        }
        .fullScreenCover(isPresented: $showChat, onDismiss: {
            Task { await todayModel.load() }
        }) {
            ChatView(
                model: chat,
                printsNumbers: todayModel.dashboard?.printsNumbers ?? true,
                saveAsUsualDefault: seedsUsuals,
                photoHint: experience.showsPhotoHint,
                onClose: { showChat = false },
                onOpen: { surface in open(surface) }
            )
        }
        .fullScreenCover(isPresented: $showProgress) {
            TodayView(model: todayModel, refreshToken: logCount, onClose: { showProgress = false })
        }
        .fullScreenCover(isPresented: $showSettings, onDismiss: {
            // Settings may have changed what the home shows (How I track) or rebuilt the
            // protocol (My details): reload the day so the page never shows a mode or a
            // target the person just left behind. The usual default follows the preference too.
            Task {
                await todayModel.load()
                await loadExperience()
            }
        }) {
            SettingsView(onClose: { showSettings = false })
        }
        .sheet(isPresented: $showAddWater) {
            AddWaterSheet { oz in
                Task {
                    if let failure = await todayModel.addWater(oz: oz) {
                        waterAddError = failure
                    } else {
                        NudgeCenter.shared.logCompleted()
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showWhatsNew, onDismiss: { WhatsNewGate.markSeen() }) {
            WhatsNewSheet(content: .current) { showWhatsNew = false }
        }
        .alert("Water not logged", isPresented: Binding(get: { waterAddError != nil }, set: { if !$0 { waterAddError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(waterAddError ?? "")
        }
        .alert("Meal not logged", isPresented: Binding(get: { usualLogError != nil }, set: { if !$0 { usualLogError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(usualLogError ?? "")
        }
        .alert("Nothing found", isPresented: Binding(get: { scanError != nil }, set: { if !$0 { scanError = nil } })) {
            Button("Type it instead") { openChat(slot: nil) }
            Button("OK", role: .cancel) {}
        } message: {
            Text(scanError ?? "")
        }
        .onChange(of: logCount) { _, _ in
            // A meal just committed — value delivered. NudgeCenter asks for notification
            // permission here (once, never at launch) and re-plans on the fresh context.
            // Off the capture path by construction: this fires after "Logged", not during.
            NudgeCenter.shared.logCompleted()
        }
        .task {
            // What the preference asks of this page, before the tour decides its order.
            await loadExperience()
            chat.onLogged = { logCount += 1 }
            if RuntimeMode.startsOnChat {
                showChat = true
                return
            }
            // First run: the tour, once the targets have reported their frames. An update:
            // What's New, once per version. Never both, never on a harness launch.
            if HelpTourFlags.shouldAutoStart {
                await tour.startWhenReady()
                if tour.isActive {
                    HelpTourFlags.markHomeTourSeen()
                    WhatsNewGate.markSeen()
                }
            } else if WhatsNewGate.shouldShow() {
                showWhatsNew = true
            }
        }
        .onChange(of: tour.isActive) { was, now in
            if was, !now, ActionButtonCoachStore.shouldPrompt { showActionButtonCard = true }
        }
        // Siri and the Action button (Intents/VoCalIntents.swift) only set a flag; the shell
        // reads it here, in the foreground, and opens a live capture if none is running.
        .onChange(of: PendingLaunchAction.shared.pending, initial: true) { _, pending in
            guard pending != nil, speaking == nil, submission == nil, !showChat else { return }
            if PendingLaunchAction.shared.take() == .startVoiceLog {
                speaking = SpeakRequest(slot: DiarySlot.suggested())
            }
        }
    }

    /// Close the log sheet, then do the thing a beat later (a cover over a leaving sheet is dropped).
    private func after(_ action: @escaping @MainActor () -> Void) {
        logSheetSlot = nil
        Task {
            try? await Task.sleep(for: Self.afterSheet)
            action()
        }
    }

    private func openChat(slot: DiarySlot?) {
        chat.targetDate = todayModel.selectedDate
        chat.mealType = slot?.mealType ?? .unspecified
        showChat = true
    }

    private func logUsual(_ usual: SavedMeal, slot: DiarySlot) {
        Task {
            if let failure = await todayModel.logUsual(usual, mealType: slot.mealType) {
                usualLogError = failure
            } else {
                logSheetSlot = nil
                logCount += 1
            }
        }
    }

    /// The scanned code, looked up; the sheet shows what was found, or the alert says nothing was.
    private func lookUp(_ code: String, slot: DiarySlot) async {
        try? await Task.sleep(for: Self.afterSheet)
        do {
            let food = try await barcode.lookup(code: code)
            scannedFood = ScannedFood(food: food, slot: slot)
        } catch BarcodeLookupError.notFound {
            scanError = "No food found for that barcode. Say it or type it instead."
        } catch BarcodeLookupError.invalidCode {
            scanError = "That did not read as a barcode. Try again, or type the number."
        } catch {
            scanError = "Couldn't look that up. Check your connection and try again."
        }
    }

    /// A scanned food is one of the person's foods from then on (the label, read by the
    /// camera instead of typed), logged as a serving through the one confirm path a usual
    /// takes; the voice sheet draws the receipt from the model's own "logged" state.
    private func logScanned(_ found: ScannedFood, servings: Double) async {
        guard !isLoggingScanned else { return }
        isLoggingScanned = true
        defer { isLoggingScanned = false }
        do {
            let saved = try await personalFoods.saveLabel(SaveLabelFoodRequest.from(found.food))
            let model = VoiceLogViewModel(mealType: found.slot.mealType, targetDate: todayModel.selectedDate)
            scannedFood = nil
            try? await Task.sleep(for: Self.afterSheet)
            scannedLogging = ScannedLog(model: model)
            model.logServing(of: saved, servings: servings) { logCount += 1 }
        } catch {
            scanError = "Couldn't save that food. Check your connection and try again."
        }
    }
}

/// The home's one piece of bottom chrome: the pill, on the bar's own fade so the diary passes
/// beneath it instead of ending at it.
struct HomeBar: View {
    var onLog: () -> Void

    var body: some View {
        PillButton(title: "Log a meal", action: onLog)
            .accessibilityIdentifier(A11y.Home.logButton)
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.vertical, VoCalTheme.Spacing.s)
            .frame(maxWidth: .infinity)
            .background(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: VoCalTheme.Colors.background.opacity(0), location: 0),
                        .init(color: VoCalTheme.Colors.background.opacity(0.7), location: 0.45),
                        .init(color: VoCalTheme.Colors.background.opacity(0.88), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .padding(.top, -CaptureBar.fadeRise)
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

extension AppRootView {
    /// A pointer from the bar's answer (decision 71). Settings holds how you track, the
    /// reminders, My protocol, My details and the meal plan; Today and the week are Progress.
    /// The cover opens after the sheet's own dismissal has finished: a cover presented while
    /// another is still dismissing is dropped.
    fileprivate func open(_ surface: AssistPointer.Surface) {
        switch surface {
        case .today, .week:
            showChat = false
            Task {
                try? await Task.sleep(for: Self.afterSheet)
                showProgress = true
            }
        case .settings, .notifications, .protocolPage, .profile, .plan:
            showChat = false
            Task {
                try? await Task.sleep(for: Self.afterSheet)
                showSettings = true
            }
        }
    }

    /// "It takes too long": the usual toggle starts on until three usuals exist (the chips are
    /// then the reason it stops).
    fileprivate var seedsUsuals: Bool {
        experience.seedUsuals && todayModel.usuals.count < 3
    }

    /// One owner-scoped read of the preference; a failed read keeps today's defaults. Off the
    /// capture path: the pill works the same with this read never returning.
    fileprivate func loadExperience() async {
        let service: any TrackingService = RuntimeMode.usesMockServices ? MockTrackingService() : LiveTrackingService()
        guard let preference = try? await service.preference() else { return }
        experience = preference.effectiveExperience
        logAnchor = preference.logAnchor
    }
}

// Settings lives in Views/Settings/SettingsView.swift (redesigned 2026-08): grouped
// cards, My details / My protocol / Weekly check-in / Notifications subpages, account
// actions. The dead-control rule from the old inline version stands there: every
// row navigates to live data or performs a real action.

#Preview {
    AppRootView()
}
