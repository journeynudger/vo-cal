import SwiftUI

/// Shared chrome for an onboarding step — form-fitted from Beacon's `OnboardingStepContainer`
/// (a back-button overlay wrapping content), extended with the two things our flow needs: a
/// thin progress bar and a pinned bottom CTA. One scaffold keeps every step's spacing, back
/// affordance, and footer identical, so individual step views only describe their question.
///
/// - `progress`: 0…1 fraction for the top bar; nil hides it.
/// - `onBack`: shows the back chevron; nil hides it (e.g. the first step).
/// - `content`: the scrollable question body (leading-aligned, standard insets).
/// - `footer`: the pinned action area (typically a `PillButton`).
struct OnboardingStepScaffold<Content: View, Footer: View>: View {
    var progress: Double?
    var onBack: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                if onBack != nil || progress != nil { topBar }
                ScrollView {
                    VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                        content()
                    }
                    .padding(.horizontal, VoCalTheme.Spacing.l)
                    .padding(.top, VoCalTheme.Spacing.l)
                    .padding(.bottom, VoCalTheme.Spacing.l)
                }
                footer()
                    .padding(VoCalTheme.Spacing.l)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .frame(width: 38, height: 38)
                        .background(VoCalTheme.Colors.card, in: Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Back")
            }
            if let progress {
                ProgressView(value: max(0, min(1, progress)))
                    .tint(VoCalTheme.Colors.ink)
            }
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.top, VoCalTheme.Spacing.l)
    }
}

#Preview {
    OnboardingStepScaffold(progress: 0.4, onBack: {}) {
        Text("YOUR GOAL").sectionHeader()
        Text("What are we working toward?")
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(VoCalTheme.Colors.ink)
    } footer: {
        PillButton(title: "Continue") {}
    }
}
