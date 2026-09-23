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
    private enum Tab { case today, settings }
    @State private var tab: Tab = RuntimeMode.startsOnSettingsTab ? .settings : .today
    @State private var showVoiceLog = false
    /// Bumped whenever a meal is logged so Today reloads (the post-log reward beat, E2).
    @State private var logCount = 0
    /// Owned here (not inside TodayView) so the mic can read the SELECTED day: a
    /// capture started while browsing a past day logs to that day (backdated
    /// logging, 2026-08). Same instance flows into TodayView.
    @State private var todayModel = TodayViewModel()

    var body: some View {
        Group {
            switch tab {
            case .today:
                TodayView(model: todayModel, refreshToken: logCount)
                    .accessibilityIdentifier(A11y.Root.todayTab)
            case .settings:
                SettingsView().accessibilityIdentifier(A11y.Root.settingsTab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .fullScreenCover(isPresented: $showVoiceLog) {
            // Auto-record: open straight into listening, meal slot set on the result.
            // targetDate pins the log to the day the user is looking at on Today.
            VoiceLogView(
                targetDate: todayModel.selectedDate,
                autoStart: true,
                onLogged: { logCount += 1 }
            )
        }
        .onChange(of: logCount) { _, _ in
            // A meal just committed — value delivered. NudgeCenter asks for notification
            // permission here (once, never at launch) and re-plans on the fresh context.
            // Off the capture path by construction: this fires after "Logged", not during.
            NudgeCenter.shared.logCompleted()
        }
    }

    /// Floating Liquid-Glass menu: a light-refracting capsule holding Home · mic · Profile,
    /// lifted off the content. The chrome now goes through `.liquidGlass(...)` (the shared
    /// `LiquidGlass` treatment) rather than a bare `.glassEffect(.regular)` — the earlier bare
    /// call rendered FLAT on the cream background because it had no tint, no rim highlight, and
    /// no Reduce-Transparency fallback (user report 2026-07: "make it a true liquid-glass menu").
    /// The tint + hairline rim are what make glass read as glass on a light theme. The mic and
    /// bar share a `GlassEffectContainer` so the two glass shapes morph together as one liquid
    /// surface; the mic is `.interactive` so it responds to touch.
    private var bottomBar: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(alignment: .center, spacing: 0) {
                tabButton(.today, label: "Home") {
                    HomeGlyphIcon()
                }
                Spacer(minLength: 0)
                micButton
                Spacer(minLength: 0)
                tabButton(.settings, label: "Profile") {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 21, weight: .semibold))
                }
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.vertical, VoCalTheme.Spacing.s)
            .liquidGlass(in: Capsule())
        }
        .shadow(color: VoCalTheme.Glass.lift, radius: 16, y: 6)
        .padding(.horizontal, VoCalTheme.Spacing.xl)
        .padding(.bottom, VoCalTheme.Spacing.s)
    }

    /// The mic — the focal action — as interactive Liquid Glass: a gold-tinted glass circle with
    /// a gold icon + gold hairline rim. `interactive` gives the touch-down glass response; the
    /// gold rim is carried through the shared treatment (same component as the bar → consistent
    /// glass, plus the Reduce-Transparency fallback the inline version lacked).
    private var micButton: some View {
        Button { showVoiceLog = true } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
                .frame(width: 56, height: 56)
                // Bright near-white tint, not a gold wash: on the tan glass bar a
                // gold-tinted circle blended into its own chrome (Lorenzo, 2026-08-23);
                // the lighter face separates the mic while the gold icon + rim keep it
                // branded.
                .liquidGlass(
                    in: Circle(),
                    tint: VoCalTheme.Colors.white.opacity(0.85),
                    interactive: true,
                    rim: VoCalTheme.Colors.goldBorderStrong,
                    rimWidth: 1.5
                )
        }
        .accessibilityIdentifier(A11y.Root.micButton)
        .accessibilityLabel("Log a meal by voice")
    }

    /// Tab item: icon only, no text label (the glyphs are unambiguous; VoiceOver keeps
    /// the name through accessibilityLabel). Home is Lorenzo's own glyph, a rounded
    /// house with an arched doorway drawn as a Path (HomeGlyph.swift, 2026-08-23), so
    /// it inherits the gold/muted selection like an SF Symbol.
    private func tabButton(
        _ target: Tab, label: String, @ViewBuilder icon: () -> some View
    ) -> some View {
        let selected = tab == target
        return Button { tab = target } label: {
            icon()
                .foregroundStyle(selected ? VoCalTheme.Colors.gold : VoCalTheme.Colors.muted)
                .frame(width: 26, height: 26)
                .frame(width: 64, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

// Settings lives in Views/Settings/SettingsView.swift (redesigned 2026-08): grouped
// cards, My details / My protocol / Weekly check-in / Notifications subpages, account
// actions. The dead-control rule from the old inline version stands there: every
// row navigates to live data or performs a real action.

#Preview {
    AppRootView()
}
