import SwiftUI

// MARK: - Benefit identity

/// The three education beats woven into the intake (Cal AI-style interstitials, Vo-Cal voice
/// and palette): pace honesty after the goal question, momentum after training, long-term
/// results right before the protocol build. `IntakeFlowView` owns the sequencing; these views
/// are the step bodies rendered inside its `OnboardingStepScaffold`.
enum IntakeBenefit: Equatable {
    /// The one benefit screen (decision 68 took S6): the outcome in the person's own numbers,
    /// which mental contrasting needs before the obstacle is asked. "Momentum" (a trophy) and
    /// "Long-term results" (a curve against a "traditional diet" with no data behind it) were
    /// the maker's claims about people in general and went (the Rams review, B7).
    case realisticPace
}

// MARK: - Shared internals


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
                // No survey exists behind a number here; a claim the product can keep instead.
                Text("Small daily deficits are the kind people keep. Nothing here is extreme, so nothing has to be undone.")
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

            Text(paceSupport)
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .staggeredReveal(shown: headerShown, rises: !reduceMotion)
        }
        .accessibilityIdentifier(A11y.Intake.benefitRealisticPace)
        .onAppear(perform: start)
    }

    /// Reference-voice title with the delta highlighted in gold; nested-Text
    /// interpolation (`+` concatenation is deprecated on iOS 26).
    private var titleText: Text {
        if deltaLb > 0 {
            return Text("Losing \(goldSpan("\(deltaLb) lb")) is a realistic target.")
        }
        if deltaLb < 0 {
            return Text("Gaining \(goldSpan("\(-deltaLb) lb")) is a realistic target.")
        }
        return Text("Maintaining your weight is a realistic target.")
    }

    /// The one true sentence the Momentum screen carried, now the support line here: what the
    /// first week does and when the line moves. No exclamation (the Rams review, B7).
    private var paceSupport: String {
        deltaLb > 0
            ? "The first week is mostly water and adjustment. Fat loss usually shows from the second week on."
            : "The first week is adjustment. Real change usually shows from the second week on."
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

// MARK: - Previews

#Preview("Realistic target") {
    OnboardingStepScaffold(progress: 3 / 11, onBack: {}) {
        RealisticPaceBenefitView(currentLb: 172, desiredLb: 155)
    } footer: {
        PillButton(title: "Continue") {}
    }
}
