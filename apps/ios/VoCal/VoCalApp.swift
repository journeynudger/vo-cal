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
                SettingsPlaceholderView().accessibilityIdentifier(A11y.Root.settingsTab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .fullScreenCover(isPresented: $showVoiceLog) {
            // Auto-record: open straight into listening, meal slot set on the result.
            VoiceLogView(autoStart: true, onLogged: { logCount += 1 })
        }
    }

    /// Floating Liquid-Glass menu (iOS 26 `.glassEffect`, not flat material): a translucent,
    /// light-refracting capsule holding Home · mic · Settings, lifted off the content. The mic
    /// and bar share a `GlassEffectContainer` so they read as one liquid-glass surface and morph
    /// together; the mic itself is `.interactive` so it responds to touch (the press/ripple the
    /// regularMaterial version had lost when the palette went gold).
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
            .glassEffect(.regular, in: Capsule())
        }
        .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        .padding(.horizontal, VoCalTheme.Spacing.xl)
        .padding(.bottom, VoCalTheme.Spacing.s)
    }

    /// The mic — the focal action — as interactive Liquid Glass: a gold-tinted glass circle with a
    /// gold icon + hairline. `.interactive()` gives the touch-down glass response on tap.
    private var micButton: some View {
        Button { showVoiceLog = true } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
                .frame(width: 56, height: 56)
                .glassEffect(.regular.tint(VoCalTheme.Colors.gold.opacity(0.18)).interactive(), in: Circle())
                .overlay(Circle().strokeBorder(VoCalTheme.Colors.goldBorderStrong, lineWidth: 1.5))
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
struct SettingsPlaceholderView: View {
    @AppStorage("vocal.onboarded") private var onboarded = false
    /// Meals/day preference, set in onboarding and adjustable here (2–6).
    @AppStorage("vocal.mealsPerDay") private var mealsPerDay = 4
    var api: any APIClientProtocol = APIClient()

    @State private var confirmingDelete = false
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Preferences") {
                    Stepper(value: $mealsPerDay, in: 2...6) {
                        HStack {
                            Text("Meals per day")
                            Spacer()
                            Text("\(mealsPerDay)")
                                .foregroundStyle(VoCalTheme.Colors.muted)
                                .monospacedDigit()
                        }
                    }
                    .accessibilityIdentifier("settings.meals-per-day")
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
            .overlay { if working { VoCalLoader(size: 32) } }
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
