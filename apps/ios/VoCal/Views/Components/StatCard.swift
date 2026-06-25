import SwiftUI

/// Rounded card surface used across Today, Protocol, and the voice-log result.
struct StatCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VoCalTheme.Spacing.l)
            .background(
                VoCalTheme.Colors.card,
                in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
            )
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
