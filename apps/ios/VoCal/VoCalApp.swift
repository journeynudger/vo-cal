import SwiftUI

@main
struct VoCalApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Lane bookkeeping only — must stay this thin. The voice coordinator bootstraps
        // lazily on scene-active/toggle so nothing (recovery scan, outbox open, telemetry)
        // sits in front of app launch or the mic-hot path (capture-path isolation,
        // Vo-Cal AGENTS.md; Serein paid three production incidents for eager launch work).
        AppRuntimeCoordinator.shared.observeLaunch()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
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

/// Tab shell + floating mic button (reference layout: Home / Settings tabs with
/// a black circular + action bottom-right). Placeholders are replaced by their
/// phases: Today (E1), Voice log (D0), Settings (I2).
struct AppRootView: View {
    @State private var showVoiceLog = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView {
                Tab("Today", systemImage: "house") {
                    TodayPlaceholderView()
                        .accessibilityIdentifier(A11y.Root.todayTab)
                }
                Tab("Settings", systemImage: "gearshape") {
                    SettingsPlaceholderView()
                        .accessibilityIdentifier(A11y.Root.settingsTab)
                }
            }
            .tint(VoCalTheme.Colors.ink)

            Button {
                showVoiceLog = true
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.onCta)
                    .frame(width: 56, height: 56)
                    .background(VoCalTheme.Colors.cta, in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
            .accessibilityIdentifier(A11y.Root.micButton)
            .accessibilityLabel("Log a meal by voice")
            .padding(.trailing, VoCalTheme.Spacing.xl)
            .padding(.bottom, 64)
        }
        .fullScreenCover(isPresented: $showVoiceLog) {
            VoiceLogPlaceholderView()
        }
    }
}

struct TodayPlaceholderView: View {
    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(spacing: VoCalTheme.Spacing.l) {
                StatCard {
                    VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                        Text("Calories left")
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                        Text("—")
                            .font(VoCalTheme.Fonts.numeral())
                            .foregroundStyle(VoCalTheme.Colors.ink)
                            .accessibilityIdentifier(A11y.Today.caloriesLeft)
                    }
                }
                Text("Today dashboard lands in Phase E.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(VoCalTheme.Spacing.l)
        }
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            Text("Settings lands in Phases F (sign out) and I (account deletion).")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .padding(VoCalTheme.Spacing.xl)
        }
    }
}

struct VoiceLogPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @State private var debugStatus = ""
    #endif

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(spacing: VoCalTheme.Spacing.xl) {
                Text("Voice log lands in Phase D.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                PillButton(title: "Close") { dismiss() }
                    .padding(.horizontal, VoCalTheme.Spacing.xxl)
                #if DEBUG
                // Debug-only smoke surface: lets a human toggle a real capture before the
                // Phase D UI exists. Status text is a raw toggle echo, deliberately NOT a
                // claim — "Listening"/"Saved" wording stays banned until D builds the
                // claim-ladder UI against byte-flow proof and the commit receipt
                // (Vo-Cal AGENTS.md MUST NOT rule 6).
                debugVoiceSmokeControls
                #endif
            }
        }
    }

    #if DEBUG
    private var debugVoiceSmokeControls: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            PillButton(title: "Debug: toggle recording") {
                Task {
                    guard await VoiceCaptureCoordinator.shared.requestMicrophonePermission() else {
                        debugStatus = "mic permission denied"
                        return
                    }
                    do {
                        let result = try await VoiceCaptureCoordinator.shared.toggle(
                            reason: "debug_smoke",
                            executionMode: .foregroundApp
                        )
                        debugStatus = "toggle: \(result.action)"
                    } catch {
                        debugStatus = "toggle failed: \(error.localizedDescription)"
                    }
                }
            }
            .padding(.horizontal, VoCalTheme.Spacing.xxl)
            .accessibilityIdentifier(A11y.VoiceLog.micButton)

            if !debugStatus.isEmpty {
                Text(debugStatus)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .accessibilityIdentifier(A11y.VoiceLog.stateLabel)
            }
        }
    }
    #endif
}

#Preview {
    AppRootView()
}
