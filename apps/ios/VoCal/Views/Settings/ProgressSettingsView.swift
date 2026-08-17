import SwiftUI
import VoCalCore

/// Settings → Progress: the trends the product actually has durable data
/// for, shown honestly. Weight comes from weekly check-ins (self-reported,
/// decision #17 — no HealthKit); consistency and averages come from the stored
/// meal logs re-scored server-side. Sections with no data yet say so and name
/// the action that creates it, never a fabricated chart.
struct ProgressSettingsView: View {
    var api: APIClient = APIClient()

    private struct WeightPoint: Equatable {
        let date: Date
        let lb: Double
    }

    private struct WeekSummary: Equatable {
        let daysLogged: Int
        let avgKcal: Int?
        let avgCertainty: Int?
    }

    private enum ViewState {
        case loading
        case loaded
        case failed
    }

    @State private var state: ViewState = .loading
    @State private var weights: [WeightPoint] = []
    @State private var thisWeek: WeekSummary?
    /// This week against its calorie goal, from the same budget endpoint the
    /// week graph uses — one number, one wording, everywhere.
    @State private var standing: WeekStanding?
    /// Days logged for the last four weeks, oldest first (three weeks back … this week).
    @State private var consistency: [Int] = []

    private static let kgPerLb = 0.45359237

    var body: some View {
        SettingsPageScaffold(title: "Progress") {
            switch state {
            case .loading:
                VoCalLoader(size: 40)
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.xxl)
            case .failed:
                VStack(spacing: VoCalTheme.Spacing.l) {
                    VStack(spacing: VoCalTheme.Spacing.s) {
                        Text("Couldn't load your progress")
                            .font(VoCalTheme.Fonts.primaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        Text("Check your connection and try again.")
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoCalTheme.Spacing.xxl)
                    PillButton(title: "Try again") {
                        state = .loading
                        Task { await load() }
                    }
                    .padding(.horizontal, VoCalTheme.Spacing.xxl)
                }
            case .loaded:
                loaded
            }
        }
        .task { await load() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var loaded: some View {
        SettingsSectionLabel(title: "Weight")
            .padding(.top, VoCalTheme.Spacing.s)
        SettingsCard {
            weightSection
                .padding(VoCalTheme.Spacing.l)
        }

        SettingsSectionLabel(title: "This week")
            .padding(.top, VoCalTheme.Spacing.l)
        SettingsCard {
            thisWeekSection
        }

        SettingsSectionLabel(title: "Consistency")
            .padding(.top, VoCalTheme.Spacing.l)
        SettingsCard {
            consistencySection
                .padding(VoCalTheme.Spacing.l)
        }
    }

    @ViewBuilder
    private var weightSection: some View {
        if weights.count >= 2, let first = weights.first, let last = weights.last {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.s) {
                    Text("\(Int(last.lb.rounded()))")
                        .font(VoCalTheme.Fonts.numeral(40))
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.gold)
                    Text("lb")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Spacer()
                    deltaChip(from: first.lb, to: last.lb)
                }
                WeightTrendChart(points: weights.map(\.lb))
                    .frame(height: 130)
                    .accessibilityHidden(true)
                HStack {
                    Text(first.date.formatted(.dateTime.month(.abbreviated).day()))
                    Spacer()
                    Text(last.date.formatted(.dateTime.month(.abbreviated).day()))
                }
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            }
        } else {
            emptyLine(
                icon: "scalemass",
                text: "Weigh in at your weekly check-ins and your trend builds here."
            )
        }
    }

    @ViewBuilder
    private var thisWeekSection: some View {
        if let week = thisWeek {
            if let standing {
                SettingsDetailRow(label: "Against your goal", value: standing.shortLabel)
                SettingsDetailDivider()
            }
            SettingsDetailRow(label: "Days logged", value: "\(week.daysLogged) of 7")
            if let avg = week.avgKcal {
                SettingsDetailDivider()
                SettingsDetailRow(label: "Average calories", value: avg.formatted(.number.grouping(.automatic)))
            }
            if let certainty = week.avgCertainty {
                SettingsDetailDivider()
                SettingsDetailRow(label: "Capture certainty", value: "\(certainty)%")
            }
        } else {
            emptyLine(icon: "mic", text: "Log a few meals and this week's numbers show up here.")
                .padding(VoCalTheme.Spacing.l)
        }
    }

    @ViewBuilder
    private var consistencySection: some View {
        if consistency.contains(where: { $0 > 0 }) {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                HStack(alignment: .bottom, spacing: VoCalTheme.Spacing.m) {
                    ForEach(Array(consistency.enumerated()), id: \.offset) { index, days in
                        VStack(spacing: VoCalTheme.Spacing.xs) {
                            Text("\(days)")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(VoCalTheme.Colors.ink)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(
                                    index == consistency.count - 1
                                        ? VoCalTheme.Colors.gold
                                        : VoCalTheme.Colors.ink.opacity(0.25)
                                )
                                .frame(height: max(8, CGFloat(days) / 7 * 72))
                                .frame(maxWidth: .infinity)
                            Text(index == consistency.count - 1 ? "Now" : "-\(consistency.count - 1 - index)w")
                                .font(VoCalTheme.Fonts.formLabel)
                                .foregroundStyle(VoCalTheme.Colors.muted)
                        }
                    }
                }
                Text("Days logged per week. Streaks survive on easy days.")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
        } else {
            emptyLine(icon: "calendar", text: "A few logged days and your weekly rhythm shows here.")
        }
    }

    private func deltaChip(from first: Double, to last: Double) -> some View {
        let delta = Int((last - first).rounded())
        let text = delta == 0 ? "steady" : (delta < 0 ? "\(delta) lb" : "+\(delta) lb")
        return Text(text)
            .font(VoCalTheme.Fonts.chipLabel)
            .monospacedDigit()
            .foregroundStyle(VoCalTheme.Colors.ink)
            .padding(.horizontal, VoCalTheme.Spacing.m)
            .padding(.vertical, 5)
            .background(
                delta <= 0 ? VoCalTheme.Colors.gold.opacity(0.16) : VoCalTheme.Colors.ink.opacity(0.05),
                in: Capsule()
            )
    }

    private func emptyLine(icon: String, text: String) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.muted)
            Text(text)
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    private func load() async {
        if RuntimeMode.usesMockServices {
            let calendar = Calendar.current
            weights = (0..<5).reversed().map { weeksAgo in
                WeightPoint(
                    date: calendar.date(byAdding: .day, value: -7 * weeksAgo, to: .now) ?? .now,
                    lb: 176 - Double(4 - weeksAgo) * 1.4
                )
            }
            thisWeek = WeekSummary(daysLogged: 6, avgKcal: 2140, avgCertainty: 74)
            consistency = [4, 5, 6, 6]
            standing = WeekStanding(carryKcal: -480)
            state = .loaded
            return
        }
        await AuthCoordinator.shared.ensureSession()

        // Weight trend: check-ins arrive newest first; chart wants oldest first.
        var loadedWeights: [WeightPoint] = []
        if let rows = try? await api.listCheckins() {
            loadedWeights = rows.reversed().compactMap { row in
                guard let kg = row.weightKg else { return nil }
                return WeightPoint(date: row.createdAt, lb: kg / Self.kgPerLb)
            }
        }

        // Four week-ending summaries (this week and the three before). Any single
        // failed week degrades to zero rather than failing the whole page — but if
        // EVERYTHING failed, that's a connection problem and the page says so.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        var summaries: [WeeklySummaryDTO?] = []
        for weeksAgo in (0..<4).reversed() {
            let end = Calendar.current.date(byAdding: .day, value: -7 * weeksAgo, to: .now) ?? .now
            summaries.append(try? await api.weeklySummary(date: formatter.string(from: end)))
        }

        if loadedWeights.isEmpty, summaries.allSatisfy({ $0 == nil }) {
            state = .failed
            return
        }

        // The week's standing against goal (best-effort: a failed budget read
        // just hides the row rather than failing a page of otherwise-good data).
        if let budget = try? await api.weekBudget(date: formatter.string(from: .now)) {
            standing = budget.standing
        }

        weights = loadedWeights
        if let current = summaries.last ?? nil {
            thisWeek = current.mealsLogged > 0
                ? WeekSummary(
                    daysLogged: current.daysLogged,
                    avgKcal: current.avgKcal,
                    avgCertainty: current.avgCertainty
                )
                : nil
        }
        consistency = summaries.map { $0?.daysLogged ?? 0 }
        state = .loaded
    }
}

/// Line chart in the app's chart language (dashed grid, smoothed gold line, open
/// endpoint dots), sized for the card. Values normalize into a padded band so a
/// flat trend still reads as a line, not an edge.
private struct WeightTrendChart: View {
    let points: [Double]

    var body: some View {
        GeometryReader { geo in
            let normalized = normalizedPoints()
            ZStack(alignment: .topLeading) {
                ProgressGridShape()
                    .stroke(
                        VoCalTheme.Colors.muted.opacity(0.14),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 5])
                    )
                ProgressCurveShape(points: normalized)
                    .stroke(
                        VoCalTheme.Colors.gold,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                if let first = normalized.first, let last = normalized.last {
                    endpointDot(color: VoCalTheme.Colors.ink)
                        .position(x: first.x * geo.size.width + 6, y: first.y * geo.size.height)
                    endpointDot(color: VoCalTheme.Colors.gold)
                        .position(x: last.x * geo.size.width - 6, y: last.y * geo.size.height)
                }
            }
        }
    }

    private func endpointDot(color: Color) -> some View {
        Circle()
            .fill(VoCalTheme.Colors.background)
            .overlay(Circle().strokeBorder(color, lineWidth: 2.5))
            .frame(width: 12, height: 12)
    }

    private func normalizedPoints() -> [CGPoint] {
        guard points.count >= 2, let low = points.min(), let high = points.max() else { return [] }
        let span = max(high - low, 1)
        return points.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) / CGFloat(points.count - 1),
                y: 0.15 + 0.7 * CGFloat((high - value) / span)
            )
        }
    }
}

private struct ProgressGridShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0...3 {
            let y = rect.minY + rect.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

private struct ProgressCurveShape: Shape {
    let points: [CGPoint]

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
        return path
    }
}

#Preview {
    NavigationStack {
        ProgressSettingsView()
    }
}
