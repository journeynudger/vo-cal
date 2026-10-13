import SwiftUI

/// One thing to add (decision 74; Francesco, 2026-10-12: "let us do the work for you"): for a
/// person who chose no numbers, the server's one sentence about their week, under the tiles.
/// It names a gap in words and the person's own foods; it never carries a number, a grade or a
/// close button. It is there on the week it applies and gone on the week it does not; nothing
/// replaces it with "all good".
struct GuidanceCard: View {
    let guidance: TodayGuidance

    var body: some View {
        GlassCard(accent: VoCalTheme.Colors.gold) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                Text(guidance.title).sectionHeader()
                Text(guidance.line)
                    .font(.system(size: 15))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11y.Today.guidance)
    }
}

#Preview("Guidance") {
    GuidanceCard(guidance: TodayGuidance(
        kind: "protein",
        title: "Something to add",
        line: "Protein has been on the light side this week. Your Greek yogurt or chicken breast at one more meal a day would round it out."
    ))
    .padding()
}
