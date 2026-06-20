import SwiftUI

/// Primary CTA: black capsule, white label ("Log meal" / "Continue" style). Thin alias over
/// the shared `VoCalButton` system (Beacon-style primary), so it inherits the uniform
/// pressed/disabled/loading states. Kept as its own name because it's the most-used button and
/// reads clearly at call sites; reach for `VoCalButton(kind:)` for secondary/tertiary actions.
struct PillButton: View {
    let title: String
    var isEnabled: Bool = true
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        VoCalButton(title: title, kind: .primary, isEnabled: isEnabled, isLoading: isLoading, action: action)
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
