import SwiftUI

/// Elevated "glass" card — form-fitted from Beacon's `GlassCard` (`.ultraThinMaterial` +
/// rounded corners). In our light theme, "glass" reads as a **frosted, lifted** surface: a
/// material fill, a soft shadow, and a hairline highlight — distinct from the flat `StatCard`
/// (cream `vcCard`) used for list rows. Use it for the moments that should feel like results
/// floating above the page: the voice-log calories card, per-ingredient checks, the check-in
/// recommendation.
///
/// Pass `accent` to draw an accent border instead of the neutral highlight (e.g. gold for an
/// open per-ingredient check). Radius is the standard card radius.
struct GlassCard<Content: View>: View {
    var accent: Color?
    @ViewBuilder var content: () -> Content

    init(accent: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.accent = accent
        self.content = content
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
    }

    var body: some View {
        content()
            .padding(VoCalTheme.Spacing.l)
            .background(.regularMaterial, in: shape)
            .overlay(
                shape.strokeBorder(
                    accent ?? Color.white.opacity(0.6),
                    lineWidth: accent == nil ? 0.5 : 1.5
                )
            )
            .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
    }
}

#Preview {
    ZStack {
        VoCalTheme.Colors.background.ignoresSafeArea()
        VStack(spacing: VoCalTheme.Spacing.l) {
            GlassCard {
                HStack {
                    Image(systemName: "flame.fill").foregroundStyle(VoCalTheme.Colors.gold)
                    Text("520").font(VoCalTheme.Fonts.numeral(40)).foregroundStyle(VoCalTheme.Colors.ink)
                    Spacer()
                }
            }
            GlassCard(accent: VoCalTheme.Colors.gold) {
                Text("Was the cheddar whole, reduced-fat, or fat-free?")
                    .foregroundStyle(VoCalTheme.Colors.ink)
            }
        }
        .padding(VoCalTheme.Spacing.xl)
    }
}
