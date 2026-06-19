import SwiftUI
import VoCalCore

/// Home dashboard (DESIGN.md §Today + decision #28): a split Calories-left | Protein card
/// over a produce/water/fiber micronutrient-minimum row, then the day's logged meals. Carbs
/// and fat are deliberately NOT here (they live on meal detail) — the home stays calm and
/// shows only the five pillars Francesco coaches to. Black/gold, VoCalTheme tokens only.
struct TodayView: View {
    @State private var model: TodayViewModel
    @State private var showCheckIn = false
    /// Bumped by the app shell after a meal is logged so Today refreshes with the new meal.
    var refreshToken: Int

    init(model: TodayViewModel? = nil, refreshToken: Int = 0) {
        _model = State(initialValue: model ?? TodayViewModel())
        self.refreshToken = refreshToken
    }

    var body: some View {
        ZStack {
            VoCalTheme.Colors.background.ignoresSafeArea()
            content
        }
        .accessibilityIdentifier(A11y.Today.screen)
        .task(id: refreshToken) { await model.load() }
        .sheet(isPresented: $showCheckIn) {
            CheckInView { applied in
                model.dismissCheckin()
                if applied { Task { await model.load() } }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading where model.dashboard == nil:
            ProgressView().controlSize(.large).tint(VoCalTheme.Colors.gold)
        case let .failed(message):
            failure(message)
        default:
            dashboard(model.dashboard ?? MockTodayService.empty(date: model.selectedDate))
        }
    }

    // MARK: - Dashboard

    private func dashboard(_ data: TodayDashboard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoCalTheme.Spacing.l) {
                header
                WeekStrip(days: weekDays, selected: dateBinding)
                    .padding(.top, VoCalTheme.Spacing.xs)
                if model.checkinDue { checkinBanner }
                splitCard(data)
                microsRow(data)
                loggedSection(data)
            }
            .padding(.horizontal, VoCalTheme.Spacing.l)
            .padding(.top, VoCalTheme.Spacing.s)
            .padding(.bottom, 120) // clear the floating mic button
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.selectedDate.formatted(.dateTime.weekday(.wide).month().day()))
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            Text(isToday ? "Today" : "That day")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Weekly check-in banner (G1) — shown only when due, on the current day.
    private var checkinBanner: some View {
        Button { showCheckIn = true } label: {
            HStack(spacing: VoCalTheme.Spacing.m) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Weekly check-in ready")
                        .font(VoCalTheme.Fonts.primaryLabel)
                        .foregroundStyle(VoCalTheme.Colors.ink)
                    Text("See how the week went")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            .padding(VoCalTheme.Spacing.l)
            .background(VoCalTheme.Colors.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VoCalTheme.Radius.card, style: .continuous)
                    .strokeBorder(VoCalTheme.Colors.gold.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // Split top card: Calories left | Protein.
    private func splitCard(_ data: TodayDashboard) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            StatCard {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                    Text("Calories left")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Text(intString(data.remaining.kcal))
                        .font(VoCalTheme.Fonts.numeral(42))
                        .monospacedDigit()
                        .foregroundStyle(VoCalTheme.Colors.gold)
                        .accessibilityIdentifier(A11y.Today.caloriesLeft)
                    Text("of \(intString(data.targets.kcal)) today")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                }
            }
            StatCard {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                    Text("Protein")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(intString(data.consumed.protein))
                            .font(VoCalTheme.Fonts.numeral(34))
                            .monospacedDigit()
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        Text("g")
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                    Text("of \(intString(data.targets.protein))g goal")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.protein)
                }
            }
        }
    }

    // Produce · Water · Fiber — micronutrient-minimum cards with a neutral fill bar
    // (macro colors are reserved for macros, so these stay ink-neutral; decision #28).
    private func microsRow(_ data: TodayDashboard) -> some View {
        HStack(spacing: VoCalTheme.Spacing.s) {
            micro("Produce", consumed: data.consumed.produce, target: data.targets.produce, unit: "")
            micro("Water", consumed: data.consumed.water, target: data.targets.water, unit: " oz")
            micro("Fiber", consumed: data.consumed.fiber, target: data.targets.fiber, unit: " g")
        }
    }

    private func micro(_ label: String, consumed: Double, target: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
            Text(label)
                .font(VoCalTheme.Fonts.formLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
            HStack(spacing: 0) {
                Text(trimString(consumed)).foregroundStyle(VoCalTheme.Colors.ink)
                Text(" / \(trimString(target))\(unit)").foregroundStyle(VoCalTheme.Colors.muted)
            }
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            MicroBar(fraction: target > 0 ? consumed / target : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoCalTheme.Spacing.m)
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
    }

    // MARK: - Logged today

    @ViewBuilder
    private func loggedSection(_ data: TodayDashboard) -> some View {
        HStack {
            Text("Logged today")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Spacer()
            if !data.meals.isEmpty, data.avgConfidence > 0 {
                Text("avg \(Int((data.avgConfidence * 100).rounded()))% sure")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(VoCalTheme.Colors.gold, in: Capsule())
            }
        }
        .padding(.top, VoCalTheme.Spacing.s)

        if data.meals.isEmpty {
            emptyState
        } else {
            ForEach(data.meals) { meal in
                mealRow(meal)
            }
        }
    }

    private func mealRow(_ meal: TodayMealRow) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Image(systemName: glyph(for: meal.mealType))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: 38, height: 38)
                .background(VoCalTheme.Colors.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(meal.name ?? meal.mealType.capitalized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("\(meal.mealType.capitalized) · \(meal.loggedAt.formatted(date: .omitted, time: .shortened))")
                    .font(VoCalTheme.Fonts.formLabel)
                    .foregroundStyle(VoCalTheme.Colors.muted)
            }
            Spacer()
            Text(intString(meal.kcal))
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.ink)
        }
        .padding(VoCalTheme.Spacing.m)
        .background(VoCalTheme.Colors.card, in: RoundedRectangle(cornerRadius: VoCalTheme.Radius.chip, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: VoCalTheme.Spacing.s) {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.gold)
            Text("No meals yet")
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            Text("Tap the mic and just say what you ate.")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .foregroundStyle(VoCalTheme.Colors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoCalTheme.Spacing.xxl)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: VoCalTheme.Spacing.l) {
            Text(message)
                .font(VoCalTheme.Fonts.primaryLabel)
                .foregroundStyle(VoCalTheme.Colors.ink)
            PillButton(title: "Try again") { Task { await model.load() } }
                .padding(.horizontal, VoCalTheme.Spacing.xxl)
        }
        .padding(VoCalTheme.Spacing.xl)
    }

    // MARK: - Helpers

    private var isToday: Bool { Calendar.current.isDateInToday(model.selectedDate) }

    private var weekDays: [Date] {
        let cal = Calendar.current
        return (-6...0).compactMap { cal.date(byAdding: .day, value: $0, to: .now) }
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { model.selectedDate },
            set: { newValue in Task { await model.select(newValue) } }
        )
    }

    private func glyph(for mealType: String) -> String {
        switch mealType {
        case "breakfast": return "sun.horizon.fill"
        case "lunch": return "carrot.fill"
        case "dinner": return "fork.knife"
        case "snack": return "applelogo"
        default: return "circle.fill"
        }
    }

    private func intString(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    /// Trims a trailing ".0" so "1.0" reads "1" but "2.5" stays "2.5".
    private func trimString(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}

/// Thin neutral progress bar for the micronutrient-minimum cards.
private struct MicroBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(VoCalTheme.Colors.muted.opacity(0.18))
                Capsule()
                    .fill(VoCalTheme.Colors.ink.opacity(0.55))
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

#Preview("Populated") {
    TodayView(model: TodayViewModel(service: MockTodayService(scenario: .populated)))
}

#Preview("Empty") {
    TodayView(model: TodayViewModel(service: MockTodayService(scenario: .empty)))
}
