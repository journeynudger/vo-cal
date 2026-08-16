import SwiftUI

/// Intake step: desired bodyweight, right after the basics screen. A horizontal
/// ruler in POUNDS (the app's unit everywhere else) with tick haptics, a live
/// numeral, and a realistic-target line that rewrites itself as the value moves.
/// The value persists with the intake for coaching context; the protocol engine
/// deliberately never reads it (targets derive from current stats + goal), so
/// no number chosen here can distort the math.
struct DesiredWeightStep: View {
    @Binding var draft: IntakeDraft

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                Text("Your target").sectionHeader()
                Text("What is your desired weight?")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
            }
            .padding(.bottom, VoCalTheme.Spacing.s)

            VStack(spacing: VoCalTheme.Spacing.m) {
                Text(directionLabel)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(draft.desiredWeightLb.rounded()))")
                        .font(VoCalTheme.Fonts.numeral(48))
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.ink)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.15), value: draft.desiredWeightLb)
                    Text("lb")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                PoundsRuler(
                    valueLb: Binding(
                        get: { Int(draft.desiredWeightLb.rounded()) },
                        set: { newValue in
                            draft.desiredWeightLb = Double(newValue)
                            draft.desiredWeightTouched = true
                        }
                    )
                )
                .frame(height: 72)
                .accessibilityIdentifier(A11y.Intake.desiredWeight)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, VoCalTheme.Spacing.xl)

            realisticTarget
                .frame(maxWidth: .infinity)
                .padding(.top, VoCalTheme.Spacing.l)
        }
        .onAppear {
            // Follow the basics screen's weight until the user touches the ruler,
            // so going back to fix current weight keeps the target sensible.
            if !draft.desiredWeightTouched {
                draft.desiredWeightLb = draft.weightLb
            }
        }
    }

    private var deltaLb: Int {
        Int((draft.weightLb - draft.desiredWeightLb).rounded())
    }

    private var directionLabel: String {
        if deltaLb > 0 { return "Lose weight" }
        if deltaLb < 0 { return "Gain weight" }
        return "Maintain"
    }

    /// The highlighted delta inside the realistic-target line (gold, like the
    /// reference's accent numeral). Nested-Text interpolation, not `+`
    /// concatenation (deprecated in iOS 26).
    private func goldAmount(_ pounds: Int) -> Text {
        Text("\(pounds) lb").foregroundStyle(VoCalTheme.Colors.gold)
    }

    /// The reference's encouragement beat, honestly worded and live: the delta is
    /// highlighted in gold and the line rewrites as the ruler moves.
    @ViewBuilder
    private var realisticTarget: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            Group {
                if deltaLb > 0 {
                    Text("Losing \(goldAmount(deltaLb)) is a realistic target. You can absolutely do this.")
                } else if deltaLb < 0 {
                    Text("Gaining \(goldAmount(-deltaLb)) is a realistic target. We'll build it meal by meal.")
                } else {
                    Text("Holding steady is a great goal. We'll keep you right here.")
                }
            }
            .foregroundStyle(VoCalTheme.Colors.ink)
            .font(.system(size: 20, weight: .semibold))
            .multilineTextAlignment(.center)
            .animation(.snappy(duration: 0.2), value: deltaLb)

            Text("86% of Vo-Cal users say the change is obvious and it sticks, even six months later.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, VoCalTheme.Spacing.m)
    }
}

/// Horizontal tick ruler with native scroll physics: 1-lb ticks, taller marks at
/// 5s and 10s, a fixed gold center indicator, faded edges, and a selection
/// haptic per pound while scrolling (the tick-tick feel of a physical wheel).
private struct PoundsRuler: View {
    @Binding var valueLb: Int
    var range: ClosedRange<Int> = 70...500

    @State private var position: Int?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(range), id: \.self) { lb in
                        tick(lb)
                            .id(lb)
                    }
                }
                .scrollTargetLayout()
                .frame(height: geo.size.height)
            }
            .contentMargins(.horizontal, geo.size.width / 2 - Self.tickWidth / 2, for: .scrollContent)
            .scrollPosition(id: $position, anchor: .center)
            .scrollTargetBehavior(.viewAligned)
            .overlay {
                // Fixed center indicator the ticks pass under.
                Capsule()
                    .fill(VoCalTheme.Colors.gold)
                    .frame(width: 3, height: geo.size.height)
            }
            .overlay {
                // Edge fades so the ruler reads as a strip, not a wall of ticks.
                HStack {
                    LinearGradient(
                        colors: [VoCalTheme.Colors.background, VoCalTheme.Colors.background.opacity(0)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 44)
                    Spacer()
                    LinearGradient(
                        colors: [VoCalTheme.Colors.background.opacity(0), VoCalTheme.Colors.background],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 44)
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear { position = valueLb }
        .onChange(of: position) { _, newValue in
            if let newValue, newValue != valueLb { valueLb = newValue }
        }
        // One selection tick per pound crossed, including during deceleration.
        .sensoryFeedback(.selection, trigger: position)
        .accessibilityElement()
        .accessibilityValue("\(valueLb) pounds")
        .accessibilityAdjustableAction { direction in
            let next = valueLb + (direction == .increment ? 1 : -1)
            let clamped = min(max(next, range.lowerBound), range.upperBound)
            valueLb = clamped
            position = clamped
        }
    }

    private static let tickWidth: CGFloat = 7

    private func tick(_ lb: Int) -> some View {
        let isMajor = lb % 10 == 0
        let isMedium = lb % 5 == 0 && !isMajor
        return Rectangle()
            .fill(VoCalTheme.Colors.ink.opacity(isMajor ? 0.75 : 0.35))
            .frame(width: 1.5, height: isMajor ? 44 : (isMedium ? 32 : 20))
            .frame(width: Self.tickWidth, height: 44, alignment: .bottom)
    }
}

#Preview {
    struct Host: View {
        @State private var draft = IntakeDraft()
        var body: some View {
            ZStack {
                VoCalTheme.Colors.background.ignoresSafeArea()
                DesiredWeightStep(draft: $draft).padding()
            }
        }
    }
    return Host()
}
