import SwiftUI

/// The weekly budget screen (Carbon-style): a Monday..Sunday bar graph of the
/// carry-adjusted week, a remaining-this-week hero, and a drag-to-replan editor.
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

    /// The carry, said plainly. Under ±25 kcal it's noise, so it reads "on plan".
    @ViewBuilder
    private func carryChip(_ budget: WeekBudget) -> some View {
        let carry = Int(budget.carryKcal.rounded())
        let text: String =
            carry >= 25 ? "+\(carry) banked"
            : carry <= -25 ? "\(-carry) over — absorbed ahead"
            : "on plan"
        Text(text)
            .font(VoCalTheme.Fonts.chipLabel)
            .foregroundStyle(VoCalTheme.Colors.ink)
            .padding(.horizontal, VoCalTheme.Spacing.m)
            .padding(.vertical, 5)
            .background(
                carry >= 25
                    ? VoCalTheme.Colors.gold.opacity(0.16)
                    : VoCalTheme.Colors.ink.opacity(0.05),
                in: Capsule()
            )
    }

    @ViewBuilder
    private func notes(_ budget: WeekBudget) -> some View {
        if model.isEditing {
            Text("Drag a day up or down — the rest of the week absorbs the change, so your weekly total stays put. Past days are locked.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        } else {
            Text("Eat over or under one day and Vo-Cal quietly re-budgets the days left, so the week — not any single day — is what has to land.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
        if !budget.fullyRebalanced {
            // Honest limit note (facts-first): the engine could not place this much.
            Text("Heads up: your remaining days can't absorb \(Int(abs(budget.leftoverKcal).rounded())) kcal of this week's swing, so the week may land off plan.")
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
                .padding(VoCalTheme.Spacing.m)
                .background(
                    VoCalTheme.Colors.gold.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous)
                )
        }
        if budget.targetsAreStub {
            Text("Using starter targets — finish onboarding to budget around your own protocol.")
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
/// truncated axes). Past days show plan track + consumed fill; today/future show
/// the adjusted target (view) or the draggable plan (edit).
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

        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                // Target/plan bar.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(barFill(day, editable: editable))
                    .frame(width: barWidth, height: max(barHeight, 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(barBorder(day, editable: editable), lineWidth: 1.2)
                    )
                // Consumed overlay (view mode): what actually went in the tank.
                if !model.isEditing, day.consumedKcal > 0 {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(consumedFill(day))
                        .frame(width: barWidth, height: max(consumedHeight, 4))
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
                Text("\(value)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(labelColor(day))
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

    /// View mode: past = planned (what that day was budgeted); today/future =
    /// adjusted target. Edit mode: the draft plan.
    private func displayValue(_ day: WeekBudgetDay) -> Int {
        if model.isEditing, day.isAdjustable { return model.editorValue(for: day) }
        return day.isPast ? Int(day.plannedKcal.rounded()) : day.adjustedTargetKcal
    }

    private func barFill(_ day: WeekBudgetDay, editable: Bool) -> Color {
        if editable { return VoCalTheme.Colors.gold.opacity(0.22) }
        if model.isEditing { return VoCalTheme.Colors.ink.opacity(0.05) } // locked past
        if day.isToday { return VoCalTheme.Colors.gold.opacity(0.16) }
        if day.isPast { return VoCalTheme.Colors.ink.opacity(0.06) }
        return VoCalTheme.Colors.softFill
    }

    private func barBorder(_ day: WeekBudgetDay, editable: Bool) -> Color {
        if editable { return VoCalTheme.Colors.goldBorderStrong }
        if model.isEditing { return .clear }
        if day.isToday { return VoCalTheme.Colors.goldBorderStrong }
        if day.isPast { return .clear }
        return VoCalTheme.Colors.goldBorder
    }

    private func consumedFill(_ day: WeekBudgetDay) -> Color {
        day.isToday ? VoCalTheme.Colors.gold : VoCalTheme.Colors.ink.opacity(0.45)
    }

    private func labelColor(_ day: WeekBudgetDay) -> Color {
        if model.isEditing, day.isAdjustable { return VoCalTheme.Colors.ink }
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
        if day.isPast || day.isToday {
            return "\(name), \(Int(day.consumedKcal.rounded())) of \(value) calories"
        }
        return "\(name), target \(value) calories"
    }
}

#Preview {
    WeekBudgetView(model: WeekBudgetViewModel(service: MockWeekBudgetService()))
}
