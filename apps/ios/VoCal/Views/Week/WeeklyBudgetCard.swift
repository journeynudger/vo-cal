import SwiftUI

/// Compact weekly-budget card for Today: remaining-this-week number, seven mini
/// bars (consumed vs adjusted target), and a tap-through to the full week view.
/// Reads the same view model the sheet uses so both stay in sync.
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

    /// Seven thin bars against the week's tallest value — enough shape to invite
    /// the tap; the full graph carries the detail.
    private func miniBars(_ budget: WeekBudget) -> some View {
        let top = budget.days.map {
            max($0.consumedKcal, Double($0.adjustedTargetKcal))
        }.max() ?? 1
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(budget.days) { day in
                let value = day.isPast ? day.consumedKcal : Double(day.adjustedTargetKcal)
                Capsule()
                    .fill(
                        day.isToday
                            ? VoCalTheme.Colors.gold
                            : day.isPast
                                ? VoCalTheme.Colors.ink.opacity(0.4)
                                : VoCalTheme.Colors.ink.opacity(0.14)
                    )
                    .frame(height: max(6, 40 * CGFloat(min(value / max(top, 1), 1))))
                    .frame(maxWidth: .infinity)
            }
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
