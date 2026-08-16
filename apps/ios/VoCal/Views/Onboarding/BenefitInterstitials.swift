import SwiftUI

// MARK: - Benefit identity

/// The three education beats woven into the intake (Cal AI-style interstitials, Vo-Cal voice
/// and palette): pace honesty after the goal question, momentum after training, long-term
/// results right before the protocol build. `IntakeFlowView` owns the sequencing; these views
/// are the step bodies rendered inside its `OnboardingStepScaffold`.
enum IntakeBenefit: Equatable {
    case realisticPace
    case momentum
    case longTermResults
}

// MARK: - Shared internals

/// Animatable percent numeral: `animatableData` drives the displayed integer, so a single
/// `withAnimation` counts it up frame-by-frame — no Timer, no Task loop. Gold hero numeral,
/// monospaced digits (no layout shimmer while counting, DESIGN.md).
private struct CountUpPercentText: View, Animatable {
    var value: Double

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))%")
            .font(VoCalTheme.Fonts.numeral(44))
            .monospacedDigit()
            .foregroundStyle(VoCalTheme.Colors.gold)
    }
}

/// Smooth curve through normalized points (x 0→1 leading→trailing, y 0→1 top→bottom),
/// quad-smoothed through segment midpoints. `fillsToBaseline` closes the shape down to the
/// bottom edge for the gradient under-fill variant.
private struct BenefitCurveShape: Shape {
    let points: [CGPoint]
    var fillsToBaseline = false

    nonisolated func path(in rect: CGRect) -> Path {
        let pts = points.map {
            CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
        }
        var path = Path()
        guard let first = pts.first, let last = pts.last, pts.count > 1 else { return path }
        path.move(to: first)
        if pts.count > 2 {
            for i in 1..<(pts.count - 1) {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: pts[i])
            }
            path.addQuadCurve(to: last, control: pts[pts.count - 2])
        } else {
            path.addLine(to: last)
        }
        if fillsToBaseline {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// Subtle horizontal baseline grid behind the charts. Dashed, not solid: hairline
/// dashes read as chart furniture (the reference's look) while solid rules read
/// as table borders.
private struct BaselineGridShape: Shape {
    var lines = 4

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        guard lines > 0 else { return path }
        for i in 0...lines {
            let y = rect.minY + rect.height * CGFloat(i) / CGFloat(lines)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// The dashed-grid stroke every chart shares.
private let gridStroke = StrokeStyle(lineWidth: 1, dash: [3, 5])

/// Open endpoint marker (background fill, colored ring) at a curve's start/end,
/// the reference's signature detail. Pops in after the draw-on finishes.
private struct EndpointDot: View {
    var color: Color
    var shown: Bool
    var size: CGFloat = 13

    var body: some View {
        Circle()
            .fill(VoCalTheme.Colors.background)
            .overlay(Circle().strokeBorder(color, lineWidth: 2.5))
            .frame(width: size, height: size)
            .scaleEffect(shown ? 1 : 0.3)
            .opacity(shown ? 1 : 0)
    }
}

/// Small brand tag pinned to the chart baseline (gold dot, wordmark, dark
/// mini-pill), mirroring the reference's curve tag.
private struct ChartBrandTag: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(VoCalTheme.Colors.gold).frame(width: 7, height: 7)
            Text("Vo-Cal")
                .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text("Weight")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.onCta)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(VoCalTheme.Colors.cta, in: Capsule())
        }
    }
}

/// Reusable animated chart body: normalized points → smoothed Path, stroked with trim-based
/// draw-on (`drawProgress` 0→1), over an optional gradient under-fill the parent fades in via
/// `fillOpacity`. The gradient stays a translucent wash (gold is never a large-surface fill).
private struct ChartCanvas: View {
    let points: [CGPoint]
    var color: Color = VoCalTheme.Colors.gold
    var lineWidth: CGFloat = 3
    var drawProgress: CGFloat
    var fillOpacity: Double = 0

    var body: some View {
        ZStack {
            BenefitCurveShape(points: points, fillsToBaseline: true)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.22), color.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(fillOpacity)
            BenefitCurveShape(points: points)
                .trim(from: 0, to: drawProgress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Staggered fade + rise reveal. Under Reduce Motion (`rises == false`) the offset is pinned
/// so only opacity remains — and the parents skip the animation entirely (final state on
/// appear), so nothing moves.
private extension View {
    func staggeredReveal(shown: Bool, rises: Bool) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .offset(y: shown || !rises ? 0 : 10)
    }
}

/// Shared eyebrow / title / sub header, matching the intake question header exactly so the
/// interstitials read as steps of the same flow.
private struct BenefitHeader: View {
    let eyebrow: String
    let title: String
    var sub: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text(eyebrow).sectionHeader()
            Text(title)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
            if let sub {
                Text(sub)
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
        }
        .padding(.bottom, VoCalTheme.Spacing.s)
    }
}

// MARK: - 1. Realistic target (after the goal question)

/// "A realistic target" beat, PERSONALIZED: the chart is titled "Your weight" and runs
/// from the user's current weight to the desired weight they just picked, with both
/// values labeled at the endpoints — a specific promise, not an abstract slope (user
/// feedback 2026-08: "the graph says nothing, be specific about what you're
/// communicating"). Copy follows the reference's plain consumer voice. All state
/// resets on appear so navigating back replays; Reduce Motion jumps to the final frame.
struct RealisticPaceBenefitView: View {
    var currentLb: Double
    var desiredLb: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var headerShown = false
    @State private var drawProgress: CGFloat = 0
    @State private var fillShown = false
    @State private var dotsShown = false

    private var deltaLb: Int { Int((currentLb - desiredLb).rounded()) }

    /// Gentle move toward the goal that flattens into a hold: descending for a cut,
    /// rising for a gain, near-flat for maintain. Same x rhythm in all three.
    private var curve: [CGPoint] {
        let xs: [CGFloat] = [0.00, 0.20, 0.40, 0.60, 0.78, 0.90, 1.00]
        let downYs: [CGFloat] = [0.22, 0.30, 0.44, 0.57, 0.63, 0.655, 0.66]
        let ys: [CGFloat]
        if deltaLb > 0 {
            ys = downYs
        } else if deltaLb < 0 {
            ys = downYs.map { 0.88 - $0 } // mirrored: climbs and settles high
        } else {
            ys = [0.45, 0.43, 0.46, 0.44, 0.45, 0.44, 0.44] // steady hold
        }
        return zip(xs, ys).map { CGPoint(x: $0, y: $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                Text("Why Vo-Cal").sectionHeader()
                titleText
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("86% of users say that the change is obvious after using Vo-Cal and it is not easy to rebound.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(.bottom, VoCalTheme.Spacing.s)
            .staggeredReveal(shown: headerShown, rises: !reduceMotion)

            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                Text("Your weight")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .staggeredReveal(shown: headerShown, rises: !reduceMotion)
                chart
                    .frame(height: 190)
                HStack {
                    Text("Today")
                    Spacer()
                    Text("Your goal")
                }
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(.vertical, VoCalTheme.Spacing.s)
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier(A11y.Intake.benefitRealisticPace)
        .onAppear(perform: start)
    }

    /// Reference-voice title with the delta highlighted in gold; nested-Text
    /// interpolation (`+` concatenation is deprecated on iOS 26).
    private var titleText: Text {
        if deltaLb > 0 {
            return Text("Losing \(goldSpan("\(deltaLb) lb")) is a realistic target. It's not hard at all!")
        }
        if deltaLb < 0 {
            return Text("Gaining \(goldSpan("\(-deltaLb) lb")) is a realistic target. It's not hard at all!")
        }
        return Text("Maintaining your weight is a realistic target. It's not hard at all!")
    }

    private func goldSpan(_ value: String) -> Text {
        Text(value).foregroundStyle(VoCalTheme.Colors.gold)
    }

    private var chart: some View {
        GeometryReader { geo in
            let start = curve[0]
            let end = curve[curve.count - 1]
            ZStack(alignment: .topLeading) {
                BaselineGridShape()
                    .stroke(VoCalTheme.Colors.muted.opacity(0.14), style: gridStroke)
                ChartCanvas(points: curve, drawProgress: drawProgress, fillOpacity: fillShown ? 1 : 0)
                EndpointDot(color: VoCalTheme.Colors.ink, shown: dotsShown)
                    .position(x: start.x * geo.size.width + 6, y: start.y * geo.size.height)
                EndpointDot(color: VoCalTheme.Colors.gold, shown: dotsShown)
                    .position(x: end.x * geo.size.width - 6, y: end.y * geo.size.height)
                // The two numbers that make the chart mean something: where you are,
                // where you're headed.
                Text("\(Int(currentLb.rounded())) lb")
                    .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .opacity(dotsShown ? 1 : 0)
                    .position(
                        x: max(28, start.x * geo.size.width + 26),
                        y: max(12, start.y * geo.size.height - 18)
                    )
                Text("\(Int(desiredLb.rounded())) lb")
                    .font(VoCalTheme.Fonts.formLabel.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(VoCalTheme.Colors.gold)
                    .opacity(dotsShown ? 1 : 0)
                    .position(
                        x: min(geo.size.width - 28, end.x * geo.size.width - 26),
                        y: max(12, end.y * geo.size.height - 18)
                    )
            }
        }
    }

    private func start() {
        headerShown = false
        drawProgress = 0
        fillShown = false
        dotsShown = false
        guard !reduceMotion else {
            headerShown = true
            drawProgress = 1
            fillShown = true
            dotsShown = true
            return
        }
        withAnimation(.easeOut(duration: 0.45)) { headerShown = true }
        withAnimation(.easeOut(duration: 1.2).delay(0.25)) { drawProgress = 1 }
        withAnimation(.easeOut(duration: 0.6).delay(1.0)) { fillShown = true }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65).delay(1.4)) { dotsShown = true }
    }
}

// MARK: - 2. Momentum (after the training question)

/// "Momentum compounds" beat: a rising curve draws on, milestone dots pop in staggered at
/// 3 / 7 / 30 days, and a gold trophy lands at the end of the curve last.
struct MomentumBenefitView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var headerShown = false
    @State private var drawProgress: CGFloat = 0
    @State private var fillShown = false
    @State private var dotsShown = [false, false, false]
    @State private var trophyShown = false

    /// Slow first week, then compounding — the story the copy tells.
    private let curve: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.86),
        CGPoint(x: 0.10, y: 0.82),
        CGPoint(x: 0.30, y: 0.73),
        CGPoint(x: 0.50, y: 0.58),
        CGPoint(x: 0.70, y: 0.40),
        CGPoint(x: 0.90, y: 0.20),
        CGPoint(x: 1.00, y: 0.13),
    ]
    /// Indices into `curve` for the 3 / 7 / 30 day milestone dots.
    private let milestones = [1, 3, 5]

    /// The user's goal ("cut" | "maintain" | "gain") — picks the sub line's wording.
    var goal: String = "cut"

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            BenefitHeader(
                eyebrow: "What to expect",
                title: "You have great potential to crush your goal",
                sub: goal == "cut"
                    ? "Based on Vo-Cal's historical data, weight loss is usually delayed at first, but after 7 days, you can burn fat like crazy!"
                    : "Based on Vo-Cal's historical data, progress is usually delayed at first, but after 7 days, it really starts to move!"
            )
            .staggeredReveal(shown: headerShown, rises: !reduceMotion)

            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                Text("Your weight transition")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .staggeredReveal(shown: headerShown, rises: !reduceMotion)
                chart
                    .frame(height: 200)
                HStack {
                    Text("3 days")
                    Spacer()
                    Text("7 days")
                    Spacer()
                    Text("30 days")
                }
                .font(VoCalTheme.Fonts.formLabel)
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(.vertical, VoCalTheme.Spacing.s)
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier(A11y.Intake.benefitMomentum)
        .onAppear(perform: start)
    }

    private var chart: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                BaselineGridShape()
                    .stroke(VoCalTheme.Colors.muted.opacity(0.14), style: gridStroke)
                ChartCanvas(points: curve, drawProgress: drawProgress, fillOpacity: fillShown ? 1 : 0)
                ForEach(Array(milestones.enumerated()), id: \.offset) { slot, pointIndex in
                    // Open circles (background fill, gold ring): the reference's
                    // marker language, not solid dots.
                    EndpointDot(color: VoCalTheme.Colors.gold, shown: dotsShown[slot])
                        .position(
                            x: curve[pointIndex].x * geo.size.width,
                            y: curve[pointIndex].y * geo.size.height
                        )
                }
                Image(systemName: "trophy.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                    .scaleEffect(trophyShown ? 1 : 0.4)
                    .opacity(trophyShown ? 1 : 0)
                    .position(
                        x: geo.size.width - 16,
                        y: max(12, curve[curve.count - 1].y * geo.size.height - 26)
                    )
            }
        }
    }

    private func start() {
        headerShown = false
        drawProgress = 0
        fillShown = false
        dotsShown = [false, false, false]
        trophyShown = false
        guard !reduceMotion else {
            headerShown = true
            drawProgress = 1
            fillShown = true
            dotsShown = [true, true, true]
            trophyShown = true
            return
        }
        withAnimation(.easeOut(duration: 0.45)) { headerShown = true }
        withAnimation(.easeOut(duration: 1.2).delay(0.25)) { drawProgress = 1 }
        withAnimation(.easeOut(duration: 0.6).delay(0.9)) { fillShown = true }
        for slot in dotsShown.indices {
            withAnimation(
                .spring(response: 0.35, dampingFraction: 0.6).delay(0.5 + Double(slot) * 0.35)
            ) {
                dotsShown[slot] = true
            }
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(1.55)) { trophyShown = true }
    }
}

// MARK: - 3. Long-term results (before the protocol build)

/// "The payoff" beat: two curves draw on together over Month 1 → Month 6 — a muted
/// traditional-diet curve that dips then rebounds above its start, and the gold Vo-Cal curve
/// that descends and stays down. The 86% stat counts up after the curves finish.
struct LongTermResultsBenefitView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var headerShown = false
    @State private var drawProgress: CGFloat = 0
    @State private var fillShown = false
    @State private var endLabelsShown = false
    @State private var statShown = false
    @State private var statValue: Double = 0

    /// Dips early, then rebounds ABOVE where it started — the yo-yo shape.
    private let traditional: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.34),
        CGPoint(x: 0.12, y: 0.45),
        CGPoint(x: 0.28, y: 0.55),
        CGPoint(x: 0.45, y: 0.50),
        CGPoint(x: 0.62, y: 0.36),
        CGPoint(x: 0.80, y: 0.24),
        CGPoint(x: 1.00, y: 0.14),
    ]
    /// Descends steadily and STAYS down.
    private let vocal: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.34),
        CGPoint(x: 0.20, y: 0.46),
        CGPoint(x: 0.45, y: 0.61),
        CGPoint(x: 0.70, y: 0.72),
        CGPoint(x: 1.00, y: 0.77),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            BenefitHeader(
                eyebrow: "The payoff",
                title: "Vo-Cal creates long-term results."
            )
            .staggeredReveal(shown: headerShown, rises: !reduceMotion)

            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                Text("Your weight")
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .staggeredReveal(shown: headerShown, rises: !reduceMotion)
                chart
                    .frame(height: 200)
                HStack {
                    Text("Month 1")
                    Spacer()
                    Text("Month 6")
                }
                .font(VoCalTheme.Fonts.formLabel)
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(.vertical, VoCalTheme.Spacing.s)
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.m) {
                CountUpPercentText(value: statValue)
                Text("of Vo-Cal users maintain their weight loss even 6 months later.")
                    .font(VoCalTheme.Fonts.secondaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .staggeredReveal(shown: statShown, rises: !reduceMotion)
        }
        .accessibilityIdentifier(A11y.Intake.benefitLongTermResults)
        .onAppear(perform: start)
    }

    private var chart: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                BaselineGridShape()
                    .stroke(VoCalTheme.Colors.muted.opacity(0.14), style: gridStroke)
                ChartCanvas(
                    points: traditional,
                    color: VoCalTheme.Colors.muted,
                    lineWidth: 2.5,
                    drawProgress: drawProgress
                )
                ChartCanvas(
                    points: vocal,
                    drawProgress: drawProgress,
                    fillOpacity: fillShown ? 1 : 0
                )
                // Open endpoint circles: shared start, then one per curve end.
                EndpointDot(color: VoCalTheme.Colors.ink, shown: endLabelsShown)
                    .position(
                        x: vocal[0].x * geo.size.width + 6,
                        y: vocal[0].y * geo.size.height
                    )
                EndpointDot(color: VoCalTheme.Colors.muted, shown: endLabelsShown, size: 12)
                    .position(
                        x: geo.size.width - 6,
                        y: traditional[traditional.count - 1].y * geo.size.height
                    )
                EndpointDot(color: VoCalTheme.Colors.gold, shown: endLabelsShown)
                    .position(
                        x: geo.size.width - 6,
                        y: vocal[vocal.count - 1].y * geo.size.height
                    )
                Text("Traditional diet")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .opacity(endLabelsShown ? 1 : 0)
                    .position(
                        x: geo.size.width - 72,
                        y: max(10, traditional[traditional.count - 1].y * geo.size.height - 20)
                    )
                ChartBrandTag()
                    .opacity(endLabelsShown ? 1 : 0)
                    .position(x: 74, y: geo.size.height - 16)
            }
        }
    }

    private func start() {
        headerShown = false
        drawProgress = 0
        fillShown = false
        endLabelsShown = false
        statShown = false
        statValue = 0
        guard !reduceMotion else {
            headerShown = true
            drawProgress = 1
            fillShown = true
            endLabelsShown = true
            statShown = true
            statValue = 86
            return
        }
        withAnimation(.easeOut(duration: 0.45)) { headerShown = true }
        withAnimation(.easeOut(duration: 1.6).delay(0.25)) { drawProgress = 1 }
        withAnimation(.easeOut(duration: 0.6).delay(1.3)) { fillShown = true }
        withAnimation(.easeOut(duration: 0.4).delay(1.6)) { endLabelsShown = true }
        withAnimation(.easeOut(duration: 0.45).delay(1.75)) { statShown = true }
        // The count-up starts once the curves have finished drawing.
        withAnimation(.easeOut(duration: 0.9).delay(1.9)) { statValue = 86 }
    }
}

// MARK: - Previews

#Preview("Realistic target") {
    OnboardingStepScaffold(progress: 3 / 11, onBack: {}) {
        RealisticPaceBenefitView(currentLb: 172, desiredLb: 155)
    } footer: {
        PillButton(title: "Continue") {}
    }
}

#Preview("Momentum") {
    OnboardingStepScaffold(progress: 6 / 11, onBack: {}) {
        MomentumBenefitView(goal: "cut")
    } footer: {
        PillButton(title: "Continue") {}
    }
}

#Preview("Long-term results") {
    OnboardingStepScaffold(progress: 10 / 10, onBack: {}) {
        LongTermResultsBenefitView()
    } footer: {
        PillButton(title: "Build my protocol") {}
    }
}
