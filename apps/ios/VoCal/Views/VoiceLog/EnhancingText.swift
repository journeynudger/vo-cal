import SwiftUI

/// The "Enhancing" multi-color gradient sweep over the raw transcript words. Mirrors the
/// prototype's `background-clip:text` animated gradient: a wide multi-stop gradient
/// (protein red -> carbs amber -> green -> fats blue -> gold) is painted into the glyphs
/// and slid horizontally on a loop, so color appears to flow across the words while the
/// parse computes.
///
/// SwiftUI implementation: a `LinearGradient` 3x the text width is used as the text's
/// `foregroundStyle`, offset by an animated phase via `.offset` on a masked copy. We use
/// the mask form (gradient rectangle masked by the text) because `foregroundStyle` cannot
/// be animated by an offset directly — masking lets the gradient layer move under static
/// glyph shapes. Colors come from VoCalTheme tokens only (no inline hex); the extra green
/// matches the prototype's "cleaned up" accent and is derived from the carbs/fats tokens'
/// sibling — here we reuse the semantic tokens plus gold to stay on-palette.
struct EnhancingText: View {
    let text: String

    @State private var phase: CGFloat = 0

    private var sweepColors: [Color] {
        [
            VoCalTheme.Colors.protein,
            VoCalTheme.Colors.carbs,
            VoCalTheme.Colors.fats,
            VoCalTheme.Colors.gold,
            VoCalTheme.Colors.protein,
        ]
    }

    var body: some View {
        Text(text)
            .font(VoCalTheme.Fonts.primaryLabel)
            .multilineTextAlignment(.center)
            .overlay {
                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    LinearGradient(
                        colors: sweepColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width * 3)
                    .offset(x: -width * 2 * phase)
                    .mask(
                        Text(text)
                            .font(VoCalTheme.Fonts.primaryLabel)
                            .multilineTextAlignment(.center)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    )
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .accessibilityLabel("Enhancing your log")
    }
}

#Preview {
    EnhancingText(text: "four ounces of 93/7 beef and two hundred grams of cooked jasmine rice")
        .padding(VoCalTheme.Spacing.xl)
        .background(VoCalTheme.Colors.background)
}
