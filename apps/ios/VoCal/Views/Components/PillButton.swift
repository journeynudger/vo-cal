import SwiftUI

/// Primary CTA: black capsule, white label ("Create Meal" / "Continue" style).
struct PillButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.onCta)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(VoCalTheme.Colors.cta, in: Capsule())
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

#Preview {
    VStack(spacing: VoCalTheme.Spacing.l) {
        PillButton(title: "Create Meal") {}
        PillButton(title: "Continue", isEnabled: false) {}
    }
    .padding(VoCalTheme.Spacing.xl)
    .background(VoCalTheme.Colors.background)
}
