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
                OnboardingFlowView(onComplete: { onboarded = true })
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
        }
    }
}

/// Tab shell with the voice button centered IN the bottom bar (Home · 🎙 · Settings) — not a
/// floating action that overlaps content. Tapping the mic opens straight into recording (one
/// tap, no meal-type picker): you just talk, and the meal slot is set afterward.
struct AppRootView: View {
    private enum Tab { case today, settings }
    @State private var tab: Tab = .today
    @State private var showVoiceLog = false
    /// Bumped whenever a meal is logged so Today reloads (the post-log reward beat, E2).
    @State private var logCount = 0

    var body: some View {
        Group {
            switch tab {
            case .today:
                TodayView(refreshToken: logCount).accessibilityIdentifier(A11y.Root.todayTab)
            case .settings:
                SettingsView().accessibilityIdentifier(A11y.Root.settingsTab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .fullScreenCover(isPresented: $showVoiceLog) {
            // Auto-record: open straight into listening, meal slot set on the result.
            VoiceLogView(autoStart: true, onLogged: { logCount += 1 })
        }
        .onChange(of: logCount) { _, _ in
            // A meal just committed — value delivered. NudgeCenter asks for notification
            // permission here (once, never at launch) and re-plans on the fresh context.
            // Off the capture path by construction: this fires after "Logged", not during.
            NudgeCenter.shared.logCompleted()
        }
    }

    /// Floating Liquid-Glass menu: a light-refracting capsule holding Home · mic · Settings,
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
                tabButton(.today, glyph: "house.fill", label: "Home")
                Spacer(minLength: 0)
                micButton
                Spacer(minLength: 0)
                tabButton(.settings, glyph: "gearshape.fill", label: "Settings")
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
                .liquidGlass(
                    in: Circle(),
                    tint: VoCalTheme.Colors.gold.opacity(0.18),
                    interactive: true,
                    rim: VoCalTheme.Colors.goldBorderStrong,
                    rimWidth: 1.5
                )
        }
        .accessibilityIdentifier(A11y.Root.micButton)
        .accessibilityLabel("Log a meal by voice")
    }

    @ViewBuilder
    private func tabButton(_ target: Tab, glyph: String, label: String) -> some View {
        let selected = tab == target
        Button { tab = target } label: {
            VStack(spacing: 3) {
                Image(systemName: glyph).font(.system(size: 19, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? VoCalTheme.Colors.gold : VoCalTheme.Colors.muted)
            .frame(width: 64)
        }
        .accessibilityLabel(label)
    }
}

/// Settings (I2): sign out + the App-Review-required in-app account deletion. Deletion calls
/// DELETE /account (purges all server data + identity), then signs out and returns to
/// onboarding. The "not medical advice" line is the I3 health-posture disclaimer.
struct SettingsView: View {
    @AppStorage("vocal.onboarded") private var onboarded = false
    var api: any APIClientProtocol = APIClient()

    @State private var confirmingDelete = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var nudgesEnabled = NudgeCenter.shared.isEnabled

    var body: some View {
        NavigationStack {
            List {
                // NOTE: a "Meals per day" stepper lived here but only wrote @AppStorage — it was
                // never sent to the server and no endpoint re-derives the protocol from it, so
                // changing it after onboarding did nothing (a dead control; audit 2026-07).
                // Meal structure is set at onboarding and moved only by the weekly check-in's
                // recalibration. Removed rather than shown as an interactive setting that lies.
                Section {
                    Toggle("Smart nudges", isOn: $nudgesEnabled)
                        .onChange(of: nudgesEnabled) { _, enabled in
                            NudgeCenter.shared.isEnabled = enabled
                        }
                        .accessibilityIdentifier("settings.smart-nudges")
                } footer: {
                    Text("Timely, supportive tips based on your own logging — a gentle reminder if you go quiet, a heads-up when there's room for a treat. Never more than two a day.")
                }
                Section {
                    Button("Sign out") { Task { await signOut() } }
                        .foregroundStyle(VoCalTheme.Colors.ink)
                }
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Text("Delete account")
                    }
                    .accessibilityIdentifier("settings.delete-account")
                } footer: {
                    Text("Deleting your account permanently removes your voice logs, meals, and protocol. This cannot be undone.")
                }
                Section {
                    Text("Vo-Cal provides nutrition information for educational purposes and is not medical advice.")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
            }
            .navigationTitle("Settings")
            .disabled(working)
            .overlay {
                // Full-page BLOCKING overlay for sign-out / delete (bug 4): a scrim dims and
                // covers the settings list and swallows touches, instead of a spinner floating
                // over still-visible, greyed content. Applies to both `working` flows (sign out
                // + delete account) since they share the flag.
                if working {
                    ZStack {
                        VoCalTheme.Colors.ink.opacity(0.45).ignoresSafeArea()
                        VoCalLoader(size: 40)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: working)
            .alert("Delete account?", isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { Task { await deleteAccount() } }
            } message: {
                Text("This permanently deletes your account and all your data. This cannot be undone.")
            }
            .alert(
                "Couldn't delete account",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func signOut() async {
        working = true
        if !RuntimeMode.usesMockServices { await AuthCoordinator.shared.signOut() }
        working = false
        onboarded = false
    }

    private func deleteAccount() async {
        working = true
        do {
            // Mock/sim path has no live account to delete — just reset local state.
            if !RuntimeMode.usesMockServices {
                try await api.deleteAccount()
                await AuthCoordinator.shared.signOut()
            }
            working = false
            onboarded = false
        } catch {
            working = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Please try again."
        }
    }
}

#Preview {
    AppRootView()
}
