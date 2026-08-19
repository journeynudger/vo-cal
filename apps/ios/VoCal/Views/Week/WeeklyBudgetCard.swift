import SwiftUI
import VoCalCore

/// Compact weekly-budget card for Today: remaining-this-week number, the week's
/// standing in plain words, seven mini bars in the same status colours the full
/// graph uses, and a tap-through. Reads the same view model as the sheet so both
/// stay in sync.
struct WeeklyBudgetCard: View {
    let model: WeekBudgetViewModel
    var onOpen: () -> Void

    var body: some View {
        // No card until the week has loaded once — a skeleton here would just
        // add churn under the dashboard (the card appears within a beat).
        if let budget = model.budget {
            Button(action: onOpen) {
                HStack(spacing: VoCalTheme.Spacing.l) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This week")
                            .font(VoCalTheme.Fonts.formLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(Int(budget.remainingKcal.rounded())
                                .formatted(.number.grouping(.automatic)))
                                .font(.system(size: 24, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(VoCalTheme.Colors.gold)
                            Text("left")
                                .font(VoCalTheme.Fonts.formLabel)
                                .foregroundStyle(VoCalTheme.Colors.muted)
                        }
                        // Where the week actually stands, in the plain words the
                        // rest of the surface uses ("480 over" / "220 under").
                        Text(budget.standing.shortLabel)
                            .font(VoCalTheme.Fonts.formLabel)
                            .monospacedDigit()
                            .foregroundStyle(
                                budget.standing.isOver
                                    ? VoCalTheme.Colors.alert
                                    : VoCalTheme.Colors.muted
                            )
                    }
                    Spacer(minLength: VoCalTheme.Spacing.m)
                    miniBars(budget)
                        .frame(width: 118, height: 40)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                .padding(VoCalTheme.Spacing.l)
                .background(
                    VoCalTheme.Colors.card,
                    in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.Today.weekCard)
            .accessibilityLabel(
                "This week: \(Int(budget.remainingKcal.rounded())) calories left. Opens the weekly budget."
            )
        }
    }

    /// Seven thin bars in the graph's status colours, with the daily goal drawn
    /// across as the same dashed line — the week's shape at a glance, using one
    /// visual language with the full screen.
    private func miniBars(_ budget: WeekBudget) -> some View {
        let top = max(
            budget.days.map { max($0.consumedKcal, Double($0.adjustedTargetKcal)) }.max() ?? 1,
            budget.baselineDailyKcal
        ) * 1.1
        return ZStack(alignment: .topLeading) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(budget.days) { day in
                    let status = day.status
                    let value = status.drawsGoalFrame
                        ? Double(day.adjustedTargetKcal)
                        : day.consumedKcal
                    Capsule()
                        .fill(status.barFill)
                        .overlay(Capsule().strokeBorder(status.barStroke, lineWidth: 1))
                        .frame(height: max(6, 40 * CGFloat(min(value / top, 1))))
                        .frame(maxWidth: .infinity)
                }
            }
            GoalReferenceLine(fraction: 1 - CGFloat(min(budget.baselineDailyKcal / top, 1)))
                .stroke(VoCalTheme.Colors.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 40)
        }
    }
}

#Preview {
    ZStack {
        VoCalTheme.Colors.background.ignoresSafeArea()
        PreviewWeekCardHost()
            .padding()
    }
}

private struct PreviewWeekCardHost: View {
    @State private var model = WeekBudgetViewModel(service: MockWeekBudgetService())

    var body: some View {
        WeeklyBudgetCard(model: model, onOpen: {})
            .task { await model.load() }
    }
}
