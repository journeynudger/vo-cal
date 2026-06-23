import SwiftUI

/// The "Enhancing" reveal: the transcript writes itself in letter-by-letter rather than
/// popping in whole, matching the streaming reference (user request 2026-06 — "smooth, every
/// letter, at an ideal speed"). Each glyph feathers in over a short window so the leading edge
/// is soft (not a hard typewriter cut), and freshly-revealed glyphs glow gold then settle to
/// ink as the edge moves past — the on-brand "being enhanced" cue.
///
/// Implementation: a `TimelineView(.animation)` drives a continuous reveal cursor (characters
/// per second). Per-glyph opacity/color is painted onto a single `AttributedString` so the
/// text lays out and wraps once — no per-character HStack, no reflow as it streams. Colors come
/// from VoCalTheme tokens only. `Color.mix` (iOS 18+) interpolates gold -> ink for the hot edge.
struct EnhancingText: View {
    let text: String
    /// Characters revealed per second. ~38 reads as fast-but-legible streaming.
    var charsPerSecond: Double = 38
    /// Glyphs over which the leading edge feathers from clear to fully opaque.
    var feather: Double = 5
    /// Glyphs over which a revealed glyph cools from gold back to ink.
    var settle: Double = 9
    /// Called once when the whole string has finished revealing (optional).
    var onComplete: (() -> Void)?

    @State private var startDate: Date?
    @State private var finished = false

    private var characters: [Character] { Array(text) }

    var body: some View {
        TimelineView(.animation) { timeline in
            let start = startDate ?? timeline.date
            let revealed = timeline.date.timeIntervalSince(start) * charsPerSecond
            Text(attributed(revealed: revealed))
                .font(VoCalTheme.Fonts.primaryLabel)
                .multilineTextAlignment(.center)
                .onAppear { if startDate == nil { startDate = timeline.date } }
                .onChange(of: revealed >= Double(characters.count)) { _, done in
                    guard done, !finished else { return }
                    finished = true
                    onComplete?()
                }
        }
        .accessibilityLabel("Enhancing your log")
    }

    /// Build the per-glyph styled string for the current cursor position. A glyph at index `i`
    /// is `feathered` in by opacity as the cursor passes it, then its color cools gold -> ink.
    private func attributed(revealed: Double) -> AttributedString {
        var out = AttributedString()
        for (i, ch) in characters.enumerated() {
            var run = AttributedString(String(ch))
            let distance = revealed - Double(i)           // how far the cursor is past this glyph
            let opacity = clamp01(distance / feather)     // 0 (unrevealed) -> 1 (fully in)
            let cool = clamp01((distance - feather) / settle)  // 0 (just in, gold) -> 1 (ink)
            run.foregroundColor = VoCalTheme.Colors.gold
                .mix(with: VoCalTheme.Colors.ink, by: cool)
                .opacity(opacity)
            out += run
        }
        return out
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}

#Preview {
    EnhancingText(text: "four ounces of 93/7 beef and two hundred grams of cooked jasmine rice")
        .padding(VoCalTheme.Spacing.xl)
        .background(VoCalTheme.Colors.background)
}
