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

/// Tab shell with the voice button centered IN the bottom bar (Home · 🎙 · Profile) — not a
/// floating action that overlaps content. Tapping the mic opens straight into recording (one
/// tap, no meal-type picker): you just talk, and the meal slot is set afterward.
struct AppRootView: View {
    @State private var showVoiceLog = false
    @State private var showSettings = false
    /// A typed text or a photo from the bar, on its way to the result screen.
    @State private var submission: PendingSubmission?
    /// Bumped whenever a meal is logged so Today reloads (the post-log reward beat, E2).
    @State private var logCount = 0
    /// Owned here (not inside TodayView) so the mic can read the SELECTED day: a
    /// capture started while browsing a past day logs to that day (backdated
    /// logging, 2026-08). Same instance flows into TodayView.
    @State private var todayModel = TodayViewModel()
    /// The capture bar's composer and its search over what the person has logged.
    @State private var composer = CaptureComposerModel()
    @State private var search = CaptureSearchModel(provider: ServiceCaptureSearchProvider())
    /// The first-run tour (Beacon's coach marks, ported through Serein), What's New after an
    /// update, and the Action button card once the tour is done.
    @State private var tour = HelpTourModel()
    @State private var showWhatsNew = false
    @State private var showActionButtonCard = false
    /// The bar's attachment menu, owned here (Serein's home owns it) so the catcher under the
    /// bar can close it. The camera and the library are presented from here too, never from
    /// inside the safe-area inset.
    @State private var menuOpen = false
    @State private var cameraPresented = false
    @State private var libraryPresented = false
    @State private var librarySelection: PhotosPickerItem?

    /// One submission at a time, identified so the cover can present it.
    private struct PendingSubmission: Identifiable {
        let id = UUID()
        let submission: CaptureSubmission
    }

    /// Near invisible, full screen, under the bar: while the menu is open a tap closes it and
    /// goes no further (it must not fall through to a card and open it); while the keyboard is
    /// up a tap puts it away. Absent otherwise, so the page keeps every touch.
    @ViewBuilder
    private var catchers: some View {
        if menuOpen {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(CaptureBar.composeMotion) { menuOpen = false }
                }
                .accessibilityHidden(true)
        } else if composer.isFieldFocused {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture {
                    composer.dismissKeyboard()
                }
                .accessibilityHidden(true)
        }
    }

    var body: some View {
        TodayView(
            model: todayModel,
            refreshToken: logCount,
            onLogged: { logCount += 1 },
            tour: tour,
            onProfile: { showSettings = true }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Serein's catchers, under the bar: a tap anywhere else closes the menu, or puts the
        // keyboard away. Without them there was no way out of the composer (the field held
        // focus forever) and the menu stayed open over the page (build 30, Lorenzo 2026-09-24).
        .overlay { catchers }
        // The whole bottom chrome: voice first, typed with search, a photo (decision 52), and
        // once the tour is done the Action button card above it, as Serein places its coach
        // card: on the page, pointing at the real controls, never a card inside a sheet.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if showActionButtonCard {
                    ActionButtonSetupCard { showActionButtonCard = false }
                        .padding(.horizontal, VoCalTheme.Spacing.l)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                CaptureBar(
                    composer: composer,
                    search: search,
                    menuOpen: $menuOpen,
                    onVoice: { showVoiceLog = true },
                    onSend: { submission = PendingSubmission(submission: $0) },
                    // A hit is logged the one way every meal is logged: its name goes through
                    // the parse, and a usual is recognized by name on the result.
                    onPickHit: { hit in submission = PendingSubmission(submission: .text(hit.name)) },
                    onCamera: { cameraPresented = true },
                    onLibrary: { libraryPresented = true },
                    tour: tour
                )
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: showActionButtonCard)
        }
        .overlay { HelpTourOverlay(model: tour) }
        .fullScreenCover(isPresented: $cameraPresented) {
            CaptureCameraView { data in
                Task { composer.stagedPhoto = await StagedPhoto.prepare(data) }
            }
        }
        .photosPicker(isPresented: $libraryPresented, selection: $librarySelection, matching: .images)
        .onChange(of: librarySelection) { _, item in
            guard let item else { return }
            librarySelection = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    composer.notice = "That photo did not load. Try another one."
                    return
                }
                composer.stagedPhoto = await StagedPhoto.prepare(data)
            }
        }
        .fullScreenCover(isPresented: $showVoiceLog, onDismiss: {
            // A sheet closed before "Logged" leaves a saved recording: Today lists it.
            Task { await todayModel.loadUnfinished() }
        }) {
            // Auto-record: open straight into listening, meal slot set on the result.
            // targetDate pins the log to the day the user is looking at on Today.
            VoiceLogView(
                targetDate: todayModel.selectedDate,
                autoStart: true,
                onLogged: { logCount += 1 }
            )
        }
        .fullScreenCover(item: $submission) { pending in
            VoiceLogView(
                targetDate: todayModel.selectedDate,
                submission: pending.submission,
                onLogged: { logCount += 1 }
            )
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(onClose: { showSettings = false })
        }
        .sheet(isPresented: $showWhatsNew, onDismiss: { WhatsNewGate.markSeen() }) {
            WhatsNewSheet(content: .current) { showWhatsNew = false }
        }
        .onChange(of: logCount) { _, _ in
            // A meal just committed — value delivered. NudgeCenter asks for notification
            // permission here (once, never at launch) and re-plans on the fresh context.
            // Off the capture path by construction: this fires after "Logged", not during.
            NudgeCenter.shared.logCompleted()
        }
        .task {
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
            guard pending != nil, !showVoiceLog, submission == nil else { return }
            if PendingLaunchAction.shared.take() == .startVoiceLog { showVoiceLog = true }
        }
    }
}

// Settings lives in Views/Settings/SettingsView.swift (redesigned 2026-08): grouped
// cards, My details / My protocol / Weekly check-in / Notifications subpages, account
// actions. The dead-control rule from the old inline version stands there: every
// row navigates to live data or performs a real action.

#Preview {
    AppRootView()
}
