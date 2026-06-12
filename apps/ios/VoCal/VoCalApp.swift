import SwiftUI

@main
struct VoCalApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
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

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(spacing: VoCalTheme.Spacing.xl) {
                Text("Voice log lands in Phase D.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                PillButton(title: "Close") { dismiss() }
                    .padding(.horizontal, VoCalTheme.Spacing.xxl)
            }
        }
    }
}

#Preview {
    AppRootView()
}
