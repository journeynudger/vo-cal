import SwiftUI
import VoCalCore

/// The weekly budget screen: a Monday..Sunday bar graph of the week against the
/// daily goal, a remaining-this-week hero, and a drag-to-replan editor.
///
/// Two modes, deliberately distinct so the numbers stay honest:
/// - VIEW shows ADJUSTED targets — what to eat each remaining day after the
///   engine spread this week's over/under across the days left.
/// - EDIT shows the PLAN — the budget you're moving between days. Dragging one
///   day makes the others absorb the change so the weekly total never moves
///   (the same invariant the server enforces on save).
struct WeekBudgetView: View {
    @Bindable var model: WeekBudgetViewModel
    @Environment(\.dismiss) private var dismiss

    /// In-flight drag: which day, and the draft value when the drag began.
    @State private var dragging: (date: String, startValue: Int)?

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            content
        }
        .accessibilityIdentifier(A11y.Week.screen)
        .task { await model.load() }
        .alert(
            "Plan not saved",
            isPresented: Binding(
                get: { model.saveError != nil },
                set: { if !$0 { model.saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.saveError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VoCalLoader(size: 44)
        case let .failed(message):
            VStack(spacing: VoCalTheme.Spacing.l) {
                Text(message)
                    .font(VoCalTheme.Fonts.primaryLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
                PillButton(title: "Try again") { Task { await model.load() } }
                    .padding(.horizontal, VoCalTheme.Spacing.xxl)
            }
            .padding(VoCalTheme.Spacing.xl)
        case .loaded:
            if let budget = model.budget {
                loaded(budget)
            }
        }
    }

    private func loaded(_ budget: WeekBudget) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(budget)
            ScrollView {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                    hero(budget)
                    WeekBarGraph(model: model, budget: budget, dragging: $dragging)
                        .frame(height: 300)
                        .padding(.top, VoCalTheme.Spacing.s)
                    if !model.isEditing {
                        HStack(spacing: VoCalTheme.Spacing.l) {
                            WeekStatusLegend()
                            Spacer(minLength: 0)
                        }
                        goalLineCaption(budget)
                    }
                    notes(budget)
                }
                .padding(.horizontal, VoCalTheme.Spacing.l)
                .padding(.bottom, VoCalTheme.Spacing.xxl)
            }
            footer
        }
    }

    private func header(_ budget: WeekBudget) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isEditing ? "Adjust your week" : "This week")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text(weekRangeLabel(budget))
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Spacer()
            if !model.isEditing {
                Button("Done") { dismiss() }
                    .font(VoCalTheme.Fonts.buttonLabel)
                    .foregroundStyle(VoCalTheme.Colors.ink)
            }
        }
        .padding(.horizontal, VoCalTheme.Spacing.l)
        .padding(.top, VoCalTheme.Spacing.xl)
        .padding(.bottom, VoCalTheme.Spacing.m)
    }

    private func hero(_ budget: WeekBudget) -> some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
            Text(model.isEditing ? "Weekly budget" : "Left this week")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            HStack(alignment: .firstTextBaseline, spacing: VoCalTheme.Spacing.m) {
                Text(heroNumber(budget))
                    .font(VoCalTheme.Fonts.numeral(44))
                    .monospacedDigit()
                    .foregroundStyle(VoCalTheme.Colors.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !model.isEditing {
                    carryChip(budget)
                }
            }
        }
    }

    private func heroNumber(_ budget: WeekBudget) -> String {
        let value = model.isEditing ? budget.weeklyTargetKcal : budget.remainingKcal
        return Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    /// The week's running total, said plainly: "480 over", "220 under", "on plan"
    /// (user feedback 2026-08: no jargon, just the number and the direction).
    /// Alert marks an overage, gold marks under, optimal marks on plan —
    /// matching the bar colours (decision #45).
    @ViewBuilder
    private func carryChip(_ budget: WeekBudget) -> some View {
        let standing = budget.standing
        Text(standing.shortLabel)
            .font(VoCalTheme.Fonts.chipLabel)
            .monospacedDigit()
            .foregroundStyle(VoCalTheme.Colors.ink)
            .padding(.horizontal, VoCalTheme.Spacing.m)
            .padding(.vertical, 5)
            .background(
                standing.isOver
                    ? VoCalTheme.Colors.alert.opacity(0.20)
                    : standing.isUnder
                        ? VoCalTheme.Colors.gold.opacity(0.20)
                        : VoCalTheme.Colors.optimal.opacity(0.20),
                in: Capsule()
            )
            .accessibilityLabel(standing.sentence)
    }

    /// Names the dashed line so the reference is never a mystery mark.
    private func goalLineCaption(_ budget: WeekBudget) -> some View {
        HStack(spacing: 6) {
            GoalReferenceLine(fraction: 0.5)
                .stroke(VoCalTheme.Colors.ink.opacity(0.45), style: goalLineStroke)
                .frame(width: 22, height: 10)
            Text("Daily goal, \(Int(budget.baselineDailyKcal.rounded()).formatted(.number.grouping(.automatic))) cal")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
    }

    @ViewBuilder
    private func notes(_ budget: WeekBudget) -> some View {
        if model.isEditing {
            Text("Drag a day up or down. The other days move to match, so your weekly total stays the same. Past days are locked.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        } else {
            Text("Go over or under on a day and Vo-Cal adjusts the days you have left, so the week still lands.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
        if !budget.fullyRebalanced {
            // Honest limit note (facts-first): the engine could not place this much.
            Text("\(Int(abs(budget.leftoverKcal).rounded())) cal won't fit in the days you have left, so the week will land \(budget.leftoverKcal < 0 ? "over" : "under").")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .padding(VoCalTheme.Spacing.m)
                .background(
                    VoCalTheme.Colors.gold.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                )
        }
        if budget.targetsAreStub {
            Text("Using starter targets. Finish onboarding to budget around your own protocol.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            if model.isEditing {
                PillButton(title: model.saving ? "Saving…" : "Save plan") {
                    Task { await model.savePlan() }
                }
                .disabled(model.saving || !model.isDirty)
                .opacity(model.isDirty ? 1 : 0.5)
                .accessibilityIdentifier(A11y.Week.saveButton)
                Button("Discard changes") { model.discardEdits() }
                    .font(VoCalTheme.Fonts.buttonLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .disabled(model.saving)
            } else {
                PillButton(title: "Adjust my week") { model.beginEditing() }
                    .accessibilityIdentifier(A11y.Week.editButton)
            }
        }
        .padding(VoCalTheme.Spacing.l)
    }

    private func weekRangeLabel(_ budget: WeekBudget) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let start = formatter.date(from: budget.weekStart),
              let end = formatter.date(from: budget.weekEnd) else {
            return "\(budget.weekStart) – \(budget.weekEnd)"
        }
        let display = DateFormatter()
        display.dateFormat = "MMM d"
        return "\(display.string(from: start)) – \(display.string(from: end))"
    }
}

// MARK: - Bar graph

/// Seven columns on a shared 0-based kcal scale (linear — bar area is amount, no
/// truncated axes), with the daily goal drawn straight across as a dashed line.
///
/// View mode reads as a progress graph: each bar is what you ATE that day,
/// coloured against that day's goal (faded ink short of it, solid ink landing on
/// it, gold past it). A past day with no logs is an empty frame, not a deficit,
/// and a future day is its plan in outline. Edit mode switches to the plan bars
/// you drag.
private struct WeekBarGraph: View {
    @Bindable var model: WeekBudgetViewModel
    let budget: WeekBudget
    @Binding var dragging: (date: String, startValue: Int)?

    private static let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]
    private static let dragStep = 25 // kcal snap while dragging

    var body: some View {
        GeometryReader { geo in
            let labelsHeight: CGFloat = 42
            let plotHeight = geo.size.height - labelsHeight
            let columnWidth = geo.size.width / 7
            let scaleMax = scaleMax()

            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(budget.days) { day in
                        column(
                            day,
                            width: columnWidth,
                            plotHeight: plotHeight,
                            labelsHeight: labelsHeight,
                            scaleMax: scaleMax
                        )
                    }
                }
                // The cusp: the protocol's daily goal, straight across the plot.
                // Drawn ABOVE the bars so it stays readable where a bar crosses it.
                GoalReferenceLine(
                    fraction: 1 - CGFloat(min(budget.baselineDailyKcal / scaleMax, 1))
                )
                .stroke(VoCalTheme.Colors.ink.opacity(0.45), style: goalLineStroke)
                .frame(height: plotHeight)
                .allowsHitTesting(false)
            }
        }
    }

    /// Shared scale top: the largest bar plus headroom to drag into. Editing keeps
    /// a stable ceiling (the plan cap) so bars don't rescale mid-drag.
    private func scaleMax() -> Double {
        if model.isEditing { return Double(model.planCeiling) }
        let tallest = budget.days.map {
            max($0.consumedKcal, Double($0.adjustedTargetKcal), $0.plannedKcal)
        }.max() ?? budget.baselineDailyKcal
        return max(tallest * 1.15, budget.baselineDailyKcal * 1.15)
    }

    @ViewBuilder
    private func column(
        _ day: WeekBudgetDay,
        width: CGFloat,
        plotHeight: CGFloat,
        labelsHeight: CGFloat,
        scaleMax: Double
    ) -> some View {
        let barWidth = width * 0.56
        let editable = model.isEditing && day.isAdjustable
        let value = displayValue(day)
        let barHeight = height(of: Double(value), plotHeight: plotHeight, scaleMax: scaleMax)
        let consumedHeight = height(of: day.consumedKcal, plotHeight: plotHeight, scaleMax: scaleMax)
        let isDraggingThis = dragging?.date == day.date

        let status = day.status
        // A day's own goal sits above its bar when it differs from the shared
        // dashed baseline (only after a replan) — otherwise the baseline line
        // already IS that day's goal and a second mark would just be noise.
        let dayGoalHeight = height(
            of: Double(day.adjustedTargetKcal), plotHeight: plotHeight, scaleMax: scaleMax
        )
        let showsDayGoal = !model.isEditing
            && abs(Double(day.adjustedTargetKcal) - budget.baselineDailyKcal) > 25

        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if model.isEditing {
                    // Plan bar you drag.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(editable ? VoCalTheme.Colors.gold.opacity(0.22) : VoCalTheme.Colors.ink.opacity(0.05))
                        .frame(width: barWidth, height: max(barHeight, 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(
                                    editable ? VoCalTheme.Colors.goldBorderStrong : .clear,
                                    lineWidth: 1.2
                                )
                        )
                } else if status.drawsGoalFrame {
                    // Nothing eaten (or nothing yet): show the goal as an empty
                    // frame. An unlogged day is missing data, not a deficit, so it
                    // never borrows the "under" colour.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(status.barFill)
                        .frame(width: barWidth, height: max(barHeight, 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(status.barStroke, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        )
                } else {
                    // Today: an empty frame up to the day's goal behind the bar,
                    // so the room still left is visible rather than implied.
                    if status == .inProgress {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                VoCalTheme.Colors.ink.opacity(0.16),
                                style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])
                            )
                            .frame(width: barWidth, height: max(dayGoalHeight, 6))
                    }
                    // What you ate, coloured against that day's goal.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(status.barFill)
                        .frame(width: barWidth, height: max(consumedHeight, 6))
                }

                if showsDayGoal {
                    // This day's own (rebalanced) goal.
                    GoalReferenceLine(fraction: 0)
                        .stroke(VoCalTheme.Colors.ink.opacity(0.5), style: goalLineStroke)
                        .frame(width: barWidth + 6, height: 1)
                        .offset(y: -dayGoalHeight)
                }

                // Floating value while dragging.
                if isDraggingThis {
                    Text("\(value)")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.onCta)
                        .padding(.horizontal, VoCalTheme.Spacing.s)
                        .padding(.vertical, 3)
                        .background(VoCalTheme.Colors.cta, in: Capsule())
                        .offset(y: -barHeight - 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: plotHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(editable ? dragGesture(day, plotHeight: plotHeight, scaleMax: scaleMax) : nil)
            .animation(.snappy(duration: 0.18), value: value)

            VStack(spacing: 2) {
                Text(Self.dayLetters[min(max(day.weekday, 0), 6)])
                    .font(.system(size: 12, weight: day.isToday ? .bold : .medium))
                    .foregroundStyle(day.isToday ? VoCalTheme.Colors.gold : VoCalTheme.Colors.muted)
                Text(footLabel(day, status: status, value: value))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(labelColor(day, status: status))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(height: labelsHeight, alignment: .top)
            .padding(.top, 6)
        }
        .frame(width: width)
        .accessibilityElement()
        .accessibilityLabel(a11yLabel(day, value: value))
    }

    /// Edit mode shows the draft plan; view mode shows what the bar represents —
    /// calories eaten on a day that has them, the goal on a day that doesn't.
    private func displayValue(_ day: WeekBudgetDay) -> Int {
        if model.isEditing, day.isAdjustable { return model.editorValue(for: day) }
        if day.status.drawsGoalFrame { return day.adjustedTargetKcal }
        return Int(day.consumedKcal.rounded())
    }

    /// Under the bar: the plan while editing, otherwise the day's own result in
    /// the same plain words as the week chip ("120 over", "310 under").
    private func footLabel(_ day: WeekBudgetDay, status: WeekDayStatus, value: Int) -> String {
        if model.isEditing { return "\(value)" }
        switch status {
        case .over: return "+\(day.deltaKcal)"
        case .under: return "\(day.deltaKcal)"
        case .onTarget: return "\(value)"
        case .inProgress: return "\(value)"
        case .notLogged: return "—"
        case .upcoming: return "\(value)"
        }
    }

    private func labelColor(_ day: WeekBudgetDay, status: WeekDayStatus) -> Color {
        if model.isEditing, day.isAdjustable { return VoCalTheme.Colors.ink }
        if status == .over { return VoCalTheme.Colors.gold }
        return VoCalTheme.Colors.muted
    }

    private func height(of value: Double, plotHeight: CGFloat, scaleMax: Double) -> CGFloat {
        guard scaleMax > 0 else { return 0 }
        return plotHeight * CGFloat(min(max(value / scaleMax, 0), 1))
    }

    private func dragGesture(
        _ day: WeekBudgetDay, plotHeight: CGFloat, scaleMax: Double
    ) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { gesture in
                if dragging?.date != day.date {
                    dragging = (day.date, model.editorValue(for: day))
                }
                guard let dragging else { return }
                // Upward drag (negative translation) increases kcal; snap to steps.
                let kcalPerPoint = scaleMax / Double(plotHeight)
                let rawDelta = -Double(gesture.translation.height) * kcalPerPoint
                let snapped = Int((rawDelta / Double(Self.dragStep)).rounded()) * Self.dragStep
                model.setAllocation(day.date, proposing: dragging.startValue + snapped)
            }
            .onEnded { _ in dragging = nil }
    }

    private func a11yLabel(_ day: WeekBudgetDay, value: Int) -> String {
        let name = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][
            min(max(day.weekday, 0), 6)]
        if model.isEditing {
            return day.isAdjustable
                ? "\(name), planned \(value) calories, adjustable"
                : "\(name), locked past day"
        }
        // Voice-over gets the same three words the colours carry.
        let eaten = Int(day.consumedKcal.rounded())
        switch day.status {
        case .over:
            return "\(name), \(eaten) calories, \(day.deltaKcal) over goal"
        case .under:
            return "\(name), \(eaten) calories, \(abs(day.deltaKcal)) under goal"
        case .onTarget:
            return "\(name), \(eaten) calories, on target"
        case .inProgress:
            return "\(name), \(eaten) of \(day.adjustedTargetKcal) calories so far"
        case .notLogged:
            return "\(name), nothing logged"
        case .upcoming:
            return "\(name), \(day.adjustedTargetKcal) calorie goal"
        }
    }
}

#Preview {
    WeekBudgetView(model: WeekBudgetViewModel(service: MockWeekBudgetService()))
}
