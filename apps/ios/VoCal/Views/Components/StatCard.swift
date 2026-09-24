import SwiftUI

/// Rounded card surface used across Today, Protocol, and the voice-log result: one fill
/// (`Colors.card`), one radius, one padding. `isComplete` draws a green hairline; the tick
/// belongs to the card's header (`CardHeader`), never to a corner badge, and the fill never
/// tints (the tinted cards read as four different components on one page, critic 2026-09-24).
struct StatCard<Content: View>: View {
    var isComplete: Bool = false
    var radius: CGFloat = VoCalTheme.Radius.card
    var padding: CGFloat = VoCalTheme.Spacing.l
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(
                VoCalTheme.Colors.card,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                if isComplete {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(VoCalTheme.Colors.optimal.opacity(0.45), lineWidth: 1)
                }
            }
            .animation(.snappy(duration: 0.25), value: isComplete)
    }
}

#Preview {
    StatCard {
        CardHeader(title: "Calories left", support: "of 2,040 today") {
            Text("2583")
                .font(VoCalTheme.Fonts.numeral())
                .foregroundStyle(VoCalTheme.Colors.ink)
        }
    }
    .padding(VoCalTheme.Spacing.xl)
    .background(VoCalTheme.Colors.background)
}
