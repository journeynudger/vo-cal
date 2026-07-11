import SwiftUI

/// True iOS 26 Liquid Glass chrome, form-fit to the light/gold palette (Serein's shipped
/// bottom-bar recipe). The reusable treatment behind the floating menu and its action buttons.
///
/// Why a component (not an inline `.glassEffect`): the raw `.glassEffect(.regular, in:)` the
/// menu used before rendered as a FLAT bar on the near-white background — no tint, no rim, no
/// Reduce-Transparency fallback (user report 2026-07: "convert to a true liquid-glass menu").
/// Three things make glass read as glass on a light theme, and all three live here:
///   1. a frosted brightening TINT so `.regular` separates from the #FAF9F6 background,
///   2. a bright hairline RIM — the edge highlight the eye reads as a glass lip,
///   3. a soft LIFT shadow so the surface floats above the scrolling content.
/// Plus the accessibility contract the inline version lacked: when Reduce Transparency is on,
/// glass is swapped for a solid on-brand fill (a translucent refractor is exactly what that
/// setting asks us to drop).
struct LiquidGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color = VoCalTheme.Glass.barTint
    var interactive: Bool = false
    var rim: Color = VoCalTheme.Glass.rim
    var rimWidth: CGFloat = 0.75

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(VoCalTheme.Glass.reduceTransparencyFill))
                .overlay(shape.strokeBorder(rim.opacity(0.4), lineWidth: rimWidth))
        } else {
            content
                .glassEffect(glass, in: shape)
                .overlay(shape.strokeBorder(rim, lineWidth: rimWidth))
        }
    }

    /// Build the Glass value: `.regular`, brightened by the tint, made `.interactive()` for
    /// touch-responsive surfaces (the mic). Matches the SDK's chaining API exactly.
    private var glass: Glass {
        let tinted = Glass.regular.tint(tint)
        return interactive ? tinted.interactive() : tinted
    }
}

extension View {
    /// Apply Liquid-Glass chrome in the given shape. `interactive: true` adds the touch-down
    /// glass response (use for buttons); `tint`/`rim` override the palette defaults.
    func liquidGlass(
        in shape: some InsettableShape,
        tint: Color = VoCalTheme.Glass.barTint,
        interactive: Bool = false,
        rim: Color = VoCalTheme.Glass.rim,
        rimWidth: CGFloat = 0.75
    ) -> some View {
        modifier(
            LiquidGlass(shape: shape, tint: tint, interactive: interactive, rim: rim, rimWidth: rimWidth)
        )
    }
}
