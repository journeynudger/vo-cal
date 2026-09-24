import SwiftUI

// Port provenance: Serein apps/ios/SereinApp/Sources/HealthAskView.swift (the one ask; the
// system sheet comes only from the person's tap; Not now is remembered as an answer) in
// Beacon's priming shape (apps/ios/Beacon/Views/Onboarding/NotificationsPermissionView.swift:
// a large hierarchical symbol, a title, one sentence, a primary pill, a quiet skip), on
// Vo-Cal's cream. Serein's dark ground, glow and three paragraphs are not ported.

/// The priming step before the system's Health sheet. Either answer marks Health asked and
/// calls `onDone`; HealthKit never says whether reading was allowed, so the step moves on the
/// same way after Connect, and a refusal simply leaves the burned figure off Today.
struct HealthPermissionStep: View {
    let onDone: () -> Void

    @State private var isAsking = false

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()

            VStack(spacing: VoCalTheme.Spacing.xxl) {
                Spacer()

                VStack(spacing: VoCalTheme.Spacing.xl) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 64))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(VoCalTheme.Colors.gold)
                        .accessibilityHidden(true)

                    VStack(spacing: VoCalTheme.Spacing.m) {
                        Text("Connect Apple Health")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.ink)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)

                        Text("Vo-Cal shows what you burned today next to what you ate. Read only, and it stays on your phone.")
                            .font(VoCalTheme.Fonts.body)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, VoCalTheme.Spacing.xl)

                Spacer()

                VStack(spacing: VoCalTheme.Spacing.m) {
                    PillButton(title: "Connect Apple Health", isLoading: isAsking) {
                        connect()
                    }
                    .accessibilityIdentifier(A11y.HealthPermission.connectButton)

                    VoCalButton(title: "Not now", kind: .tertiary, isEnabled: !isAsking) {
                        notNow()
                    }
                    .accessibilityIdentifier(A11y.HealthPermission.notNowButton)
                }
                .padding(.horizontal, VoCalTheme.Spacing.xl)
                .padding(.bottom, VoCalTheme.Spacing.xl)
            }
        }
        .interactiveDismissDisabled(isAsking)
    }

    /// The system's sheet comes from this tap, never on its own (Serein HealthAskView).
    private func connect() {
        guard !isAsking else {
            return
        }
        isAsking = true
        Task {
            _ = await HealthKitService.shared.requestAuthorization()
            isAsking = false
            onDone()
        }
    }

    private func notNow() {
        HealthKitService.shared.markAsked()
        onDone()
    }
}

// MARK: - Accessibility identifiers

extension A11y {
    enum HealthPermission {
        static let connectButton = "health.connect-button"
        static let notNowButton = "health.not-now-button"
    }
}

#Preview("Health permission") {
    HealthPermissionStep {}
}
