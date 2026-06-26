import SwiftUI

/// Rounded card surface used across Today, Protocol, and the voice-log result.
/// When `isComplete` is true the card turns into the "goal met" win state — a soft green fill,
/// a green hairline, and a checkmark badge (the ring-close moment, decision 2026-06).
struct StatCard<Content: View>: View {
    var isComplete: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VoCalTheme.Spacing.l)
            .background(
                isComplete ? VoCalTheme.Colors.optimal.opacity(0.12) : VoCalTheme.Colors.card,
                in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
            )
            .overlay {
                if isComplete {
                    RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                        .strokeBorder(VoCalTheme.Colors.optimal.opacity(0.45), lineWidth: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.optimal)
                        .padding(10)
                }
            }
            .animation(.snappy(duration: 0.25), value: isComplete)
    }
}

#Preview {
    StatCard {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text("Calories left")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Text("2583")
                .font(VoCalTheme.Fonts.numeral())
                .foregroundStyle(VoCalTheme.Colors.ink)
        }
    }
    .padding(VoCalTheme.Spacing.xl)
    .background(VoCalTheme.Colors.background)
}
