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
            VoCalLoader(size: 48)
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

    // Split top card: Calories left | Protein (optimal-range bar).
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
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity)
            StatCard {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
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
                    ProteinRangeBar(
                        consumed: data.consumed.protein,
                        low: proteinBandLow(data),
                        high: proteinBandHigh(data)
                    )
                    .padding(.top, 2)
                    let status = proteinStatus(data)
                    Text(status.text)
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(status.color)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // Protein band, with a safe fallback to the target (a zero-width "point") when the active
    // protocol predates the band or is the pre-onboarding stub (server sends 0 → we show a goal,
    // not a misleading 0–0 range). The numbers themselves are engine-owned (AGENTS.md #6).
    private func proteinBandLow(_ d: TodayDashboard) -> Double {
        d.proteinMin > 0 ? d.proteinMin : d.targets.protein
    }

    private func proteinBandHigh(_ d: TodayDashboard) -> Double {
        d.proteinMax > 0 ? d.proteinMax : d.targets.protein
    }

    // Strength-based, non-nagging status (decision #28): under = "more to go" (neutral, not a
    // failure), in-range = the optimal green, over = a calm "over optimal" note. The bar carries
    // the color signal; the text stays calm.
    private func proteinStatus(_ d: TodayDashboard) -> (text: String, color: Color) {
        let consumed = d.consumed.protein
        let lo = proteinBandLow(d)
        let hi = proteinBandHigh(d)
        guard hi > lo else {
            return ("of \(intString(hi))g goal", VoCalTheme.Colors.muted)
        }
        if consumed < lo {
            return ("\(intString(lo - consumed))g to optimal", VoCalTheme.Colors.muted)
        }
        if consumed > hi {
            return ("\(intString(consumed - hi))g over optimal", VoCalTheme.Colors.muted)
        }
        return ("In your optimal range", VoCalTheme.Colors.optimal)
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
            // Number meals by chronological order within the day (Meal 1 = first logged),
            // independent of display order — no more breakfast/lunch labels.
            let chronological = data.meals.sorted { $0.loggedAt < $1.loggedAt }
            ForEach(data.meals) { meal in
                let number = (chronological.firstIndex { $0.id == meal.id } ?? 0) + 1
                mealRow(meal, number: number)
            }
        }
    }

    private func mealRow(_ meal: TodayMealRow, number: Int) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            Image(systemName: "fork.knife")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .frame(width: 38, height: 38)
                .background(VoCalTheme.Colors.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(meal.name ?? "Meal \(number)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.ink)
                Text("Meal \(number) · \(meal.loggedAt.formatted(date: .omitted, time: .shortened))")
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

/// Bounded-goal bar for protein: a centered green "optimal" band on a neutral track, with a
/// gold thumb that travels left→right as protein is logged. Unlike the micronutrient bars,
/// protein is NOT more-is-merrier — too little AND too much are both suboptimal — so the axis
/// leaves a lead-in below the band and overshoot room above it (band width on each side), which
/// keeps the green zone visually centered. The thumb clamps to the ends when off-scale; the
/// status line carries the exact gap. Numbers are engine-owned (AGENTS.md #6).
private struct ProteinRangeBar: View {
    var consumed: Double
    var low: Double
    var high: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let band = max(high - low, 1)          // g; avoid divide-by-zero on a point band
            let pad = band                          // equal lead-in + overshoot room
            let axisMin = max(0, low - pad)
            let axisMax = high + pad
            let span = max(axisMax - axisMin, 1)
            let bandStart = w * frac(low, axisMin, span)
            let bandEnd = w * frac(high, axisMin, span)
            let thumb = w * frac(consumed, axisMin, span)

            ZStack(alignment: .leading) {
                // Track + centered optimal band.
                ZStack(alignment: .leading) {
                    Capsule().fill(VoCalTheme.Colors.muted.opacity(0.16))
                    Capsule()
                        .fill(VoCalTheme.Colors.optimal.opacity(0.38))
                        .frame(width: max(0, bandEnd - bandStart))
                        .offset(x: bandStart)
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity, alignment: .center)

                // Gold thumb at the consumed amount.
                Circle()
                    .fill(VoCalTheme.Colors.gold)
                    .overlay(Circle().stroke(VoCalTheme.Colors.background, lineWidth: 2))
                    .frame(width: 13, height: 13)
                    .offset(x: min(w - 13, max(0, thumb - 6.5)))
            }
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Protein \(Int(consumed.rounded())) grams, optimal \(Int(low.rounded())) to \(Int(high.rounded()))")
    }

    private func frac(_ value: Double, _ axisMin: Double, _ span: Double) -> Double {
        min(1, max(0, (value - axisMin) / span))
    }
}

#Preview("Populated") {
    TodayView(model: TodayViewModel(service: MockTodayService(scenario: .populated)))
}

#Preview("Empty") {
    TodayView(model: TodayViewModel(service: MockTodayService(scenario: .empty)))
}
