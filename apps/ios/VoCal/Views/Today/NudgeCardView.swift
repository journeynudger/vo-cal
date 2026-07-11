import SwiftUI

/// The one in-app smart nudge on Today: coaching copy + an expandable pro tip.
/// Empathy-first by construction — the copy ships from the deterministic server
/// catalog; this view never rewrites or re-ranks it. Dismissing records the
/// shown-ledger entry so the server's cooldown holds.
struct NudgeCardView: View {
    let card: NudgeCard
    var onDismiss: () -> Void

    @State private var showTip = false

    var body: some View {
        GlassCard(accent: VoCalTheme.Colors.gold) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                HStack(alignment: .top, spacing: VoCalTheme.Spacing.s) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.gold)
                        .padding(.top, 2)
                    Text(card.message)
                        .font(.system(size: 15))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.muted)
                            .padding(6)
                    }
                    .accessibilityLabel("Dismiss nudge")
                }

                if showTip {
                    Text(card.proTip)
                        .font(.system(size: 13))
                        .foregroundStyle(VoCalTheme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showTip = true }
                    } label: {
                        Text("Pro tip")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.gold)
                    }
                    .accessibilityLabel("Show pro tip")
                }
            }
        }
        .accessibilityIdentifier("today.nudge-card")
    }
}

#Preview {
    NudgeCardView(
        card: NudgeCard(
            id: "fiber_boost",
            category: "fiber",
            message: "Feeling snacky? Boost your fiber! Foods like oats, beans, or an apple can help curb cravings while keeping you full longer.",
            proTip: "Think of fiber as your hunger helper. Pre-portion some trail mix or grab pre-washed fruits and veggies for busy days.",
            priority: 34,
            cooldownDays: 3
        ),
        onDismiss: {}
    )
    .padding()
}
