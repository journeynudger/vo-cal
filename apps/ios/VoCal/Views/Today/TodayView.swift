import SwiftUI
import VoCalCore

/// Home dashboard (DESIGN.md §Today + decision #28): a "Today's Rings" summary card
/// (Apple-Activity-Rings-style — Protein/Water/Fiber, animated) over clean Calories + Produce
/// detail tiles, then the day's logged meals. Carbs and fat are deliberately NOT here (they
/// live on meal detail) — the home stays calm and shows only the pillars Francesco coaches to.
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
                nutritionRingsCard(data)
                detailRow(data)
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

    // Today's rings — Apple-Activity-Rings-style summary for the three core dailies, tinted to
    // our palette: Protein (gold, outer) · Water (blue, middle) · Fiber (green, inner). Smooth
    // staggered fill on appear. The detail tiles below stay clean — no green boxes/checks.
    private func nutritionRingsCard(_ data: TodayDashboard) -> some View {
        let specs = ringSpecs(data)
        return StatCard {
            HStack(spacing: VoCalTheme.Spacing.l) {
                NutritionRings(rings: specs.map { NutritionRings.Ring(fraction: $0.fraction, color: $0.color) })
                    .frame(width: 116, height: 116)
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.m) {
                    ForEach(specs) { spec in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(spec.color)
                            Text(spec.value)
                                .font(.system(size: 17, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(VoCalTheme.Colors.ink)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Ring goals: water/fiber are more-is-merrier minimums (fraction = consumed/target). Protein's
    // ring goal is its target (the optimal-band center); the band nuance stays engine-owned and
    // can return as detail later — the ring is the at-a-glance "are you hitting protein".
    private func ringSpecs(_ d: TodayDashboard) -> [RingSpec] {
        let proteinGoal = max(d.targets.protein, 1)
        return [
            RingSpec(
                id: "protein", name: "Protein", color: VoCalTheme.Colors.gold,
                fraction: d.consumed.protein / proteinGoal,
                value: "\(intString(d.consumed.protein)) / \(intString(d.targets.protein)) g"
            ),
            RingSpec(
                id: "water", name: "Water", color: VoCalTheme.Colors.water,
                fraction: d.targets.water > 0 ? d.consumed.water / d.targets.water : 0,
                value: "\(trimString(d.consumed.water)) / \(trimString(d.targets.water)) oz"
            ),
            RingSpec(
                id: "fiber", name: "Fiber", color: VoCalTheme.Colors.optimal,
                fraction: d.targets.fiber > 0 ? d.consumed.fiber / d.targets.fiber : 0,
                value: "\(trimString(d.consumed.fiber)) / \(trimString(d.targets.fiber)) g"
            ),
        ]
    }

    // Calories (the budget) + Produce — clean number tiles under the rings. No fills, no checks.
    private func detailRow(_ data: TodayDashboard) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            StatCard {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                    Text("Calories left")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Text(intString(data.remaining.kcal))
                        .font(VoCalTheme.Fonts.numeral(40))
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
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.xs) {
                    Text("Produce")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(trimString(data.consumed.produce))
                            .font(VoCalTheme.Fonts.numeral(40))
                            .monospacedDigit()
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        Text("/ \(trimString(data.targets.produce))")
                            .font(VoCalTheme.Fonts.secondaryLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                    Text("servings")
                        .font(VoCalTheme.Fonts.formLabel)
                        .foregroundStyle(VoCalTheme.Colors.muted)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity)
        }
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

/// One labeled ring's data for the Today summary card.
private struct RingSpec: Identifiable {
    let id: String
    let name: String
    let color: Color
    let fraction: Double
    let value: String
}

/// Concentric "activity rings" (Apple-style) tinted to our palette. Each ring fills 0→fraction
/// with a smooth, slightly-staggered animation on appear (outer first); overshoot just stays a
/// full ring. `rings` is ordered outer→inner. Rounded caps + a faint same-color track give the
/// clean, premium look of the reference.
private struct NutritionRings: View {
    struct Ring {
        let fraction: Double
        let color: Color
    }

    var rings: [Ring]
    var lineWidth: CGFloat = 12
    var gap: CGFloat = 6

    @State private var appeared = false

    var body: some View {
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
                // Inset each successive ring inward by one ring-width + gap; the base inset of
                // half a line-width keeps the outermost stroke inside the frame.
                let inset = lineWidth / 2 + CGFloat(index) * (lineWidth + gap)
                let shown = appeared ? min(1, max(0, ring.fraction)) : 0
                ZStack {
                    Circle()
                        .stroke(ring.color.opacity(0.18), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: shown)
                        .stroke(ring.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))   // start the fill at 12 o'clock
                        .animation(.smooth(duration: 0.85).delay(Double(index) * 0.06), value: shown)
                }
                .padding(inset)
            }
        }
        .onAppear { appeared = true }
    }
}

#Preview("Populated") {
    TodayView(model: TodayViewModel(service: MockTodayService(scenario: .populated)))
}

#Preview("Empty") {
    TodayView(model: TodayViewModel(service: MockTodayService(scenario: .empty)))
}
