import SwiftUI

/// The one in-app smart nudge on Today: coaching copy + an expandable pro tip. Empathy-first
/// by construction — the copy ships from the deterministic server catalog; this view never
/// rewrites or re-ranks it. Dismissing records the shown-ledger entry so the server's cooldown
/// holds. An invitation (decision 62) is the same card with three answers in words instead of
/// the close: Yes moves the preference, Not now is the dismiss, and "Don't offer this again"
/// is a durable decline the person can reverse in Settings → How I track. Decision 67 gave the
/// card Serein's gestures: a swipe either way is the quiet dismiss, a long-press says "This
/// wasn't right" with three reasons (`NudgeReasonsSheet`), and nothing vibrates when the card
/// appears (it is available, not insistent).
struct NudgeCardView: View {
    let card: NudgeCard
    var onDismiss: () -> Void
    var onAccept: (() -> Void)? = nil
    var onDeclineForever: (() -> Void)? = nil
    /// The long-press's answer; nil leaves the card without the menu (renders, invitations).
    var onReport: ((NudgeReaction) -> Void)? = nil

    @State private var showTip = false
    @State private var showReasons = false
    @State private var dragX: CGFloat = 0

    /// A swipe this far, either way, dismisses; shorter snaps back.
    static let dismissDistance: CGFloat = 80

    var body: some View {
        content
            .offset(x: dragX)
            .gesture(swipe)
            .contextMenu {
                if !card.isInvitation, onReport != nil {
                    Button {
                        showReasons = true
                    } label: {
                        Label("This wasn't right", systemImage: "hand.raised")
                    }
                }
            }
            .sheet(isPresented: $showReasons) {
                NudgeReasonsSheet { kind in
                    showReasons = false
                    onReport?(kind)
                }
                .presentationDetents([.medium])
            }
    }

    /// The quiet dismiss: the card follows the finger sideways and leaves past the distance,
    /// with the one `select` tick. A mostly vertical drag is the page's scroll, not ours.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                let dismiss = abs(value.translation.width) > Self.dismissDistance
                    && abs(value.translation.width) > abs(value.translation.height)
                withAnimation(.snappy(duration: 0.25)) { dragX = 0 }
                if dismiss {
                    VoCalHaptics.select()
                    onDismiss()
                }
            }
    }

    private var content: some View {
        GlassCard(accent: VoCalTheme.Colors.gold) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                HStack(alignment: .top, spacing: VoCalTheme.Spacing.s) {
                    // No sparkle: the gold hairline already says this is the tip (critic).
                    Text(card.message)
                        .font(.system(size: 15))
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !card.isInvitation {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(VoCalTheme.Colors.muted)
                                // A 44 pt target drawn small: the glyph stays quiet, the thumb finds it.
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableButtonStyle())
                        .offset(x: VoCalTheme.Spacing.m, y: -VoCalTheme.Spacing.m)
                        .accessibilityLabel("Dismiss tip")
                    }
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
                        Text(card.isInvitation ? "What changes" : "Pro tip")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.gold)
                    }
                    .accessibilityLabel(card.isInvitation ? "Show what changes" : "Show pro tip")
                }

                if card.isInvitation {
                    answers
                }
            }
        }
        .accessibilityIdentifier("today.nudge-card")
    }

    /// Three answers, in words (spec R6: a proactive guest asks once, accepts no, and can be
    /// told never). No badge, no level, no celebration.
    private var answers: some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            VoCalButton(title: "Yes", kind: .secondary) { onAccept?() }
                .frame(width: 88)
                .accessibilityIdentifier(A11y.Today.inviteYes)
            VoCalButton(title: "Not now", kind: .tertiary, action: onDismiss)
                .accessibilityIdentifier(A11y.Today.inviteNotNow)
            Spacer(minLength: 0)
            VoCalButton(title: "Don't offer this again", kind: .tertiary) { onDeclineForever?() }
                .accessibilityIdentifier(A11y.Today.inviteNever)
        }
        .padding(.top, VoCalTheme.Spacing.xs)
    }
}

#Preview("Nudge") {
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

#Preview("Invitation") {
    NudgeCardView(
        card: NudgeCard(
            id: "invite:calories",
            category: "invitation",
            message: "You've logged 14 of the last 21 days. Want to see your calories too?",
            proTip: "Your habits stay where they are. Calories would sit above them.",
            priority: 10,
            cooldownDays: 14,
            kind: "invitation",
            offerMode: "calories",
            declineKey: "calories"
        ),
        onDismiss: {},
        onAccept: {},
        onDeclineForever: {}
    )
    .padding()
}
