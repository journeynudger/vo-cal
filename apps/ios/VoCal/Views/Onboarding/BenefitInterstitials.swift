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

// MARK: - 1. Realistic pace (after the goal question)

/// "A realistic target" beat: one gold curve descending gently and settling flat — the pace
/// story told visually. Draw-on via trim, then the under-fill washes in. All state resets on
/// appear so navigating back and returning replays the sequence; Reduce Motion jumps straight
/// to the composed final frame.
struct RealisticPaceBenefitView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var headerShown = false
    @State private var drawProgress: CGFloat = 0
    @State private var fillShown = false
    @State private var dotsShown = false

    /// Gentle descent that flattens — visible progress, then a hold your life can keep.
    private let curve: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.22),
        CGPoint(x: 0.20, y: 0.30),
        CGPoint(x: 0.40, y: 0.44),
        CGPoint(x: 0.60, y: 0.57),
        CGPoint(x: 0.78, y: 0.63),
        CGPoint(x: 0.90, y: 0.655),
        CGPoint(x: 1.00, y: 0.66),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            BenefitHeader(
                eyebrow: "Why Vo-Cal",
                title: "A realistic target. Not a hard reset.",
                sub: "Fast enough to see it, slow enough to keep it. A pace your real life can actually hold."
            )
            .staggeredReveal(shown: headerShown, rises: !reduceMotion)

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    BaselineGridShape()
                        .stroke(VoCalTheme.Colors.muted.opacity(0.14), style: gridStroke)
                    ChartCanvas(points: curve, drawProgress: drawProgress, fillOpacity: fillShown ? 1 : 0)
                    EndpointDot(color: VoCalTheme.Colors.gold, shown: dotsShown)
                        .position(
                            x: curve[0].x * geo.size.width + 6,
                            y: curve[0].y * geo.size.height
                        )
                    EndpointDot(color: VoCalTheme.Colors.gold, shown: dotsShown)
                        .position(
                            x: curve[curve.count - 1].x * geo.size.width - 6,
                            y: curve[curve.count - 1].y * geo.size.height
                        )
                }
            }
            .frame(height: 200)
            .padding(.vertical, VoCalTheme.Spacing.s)
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier(A11y.Intake.benefitRealisticPace)
        .onAppear(perform: start)
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

    var body: some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
            BenefitHeader(
                eyebrow: "What to expect",
                title: "You have real potential to crush this.",
                sub: "The first week is the hardest. After that, momentum compounds."
            )
            .staggeredReveal(shown: headerShown, rises: !reduceMotion)

            VStack(spacing: VoCalTheme.Spacing.s) {
                chart
                    .frame(height: 210)
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

            VStack(spacing: VoCalTheme.Spacing.s) {
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

#Preview("Realistic pace") {
    OnboardingStepScaffold(progress: 3 / 10, onBack: {}) {
        RealisticPaceBenefitView()
    } footer: {
        PillButton(title: "Continue") {}
    }
}

#Preview("Momentum") {
    OnboardingStepScaffold(progress: 6 / 10, onBack: {}) {
        MomentumBenefitView()
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
