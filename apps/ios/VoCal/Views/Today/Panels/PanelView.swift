import SwiftUI

/// One card of the dashboard, drawn from a server-composed `TodayPanel` (decision 60) in the
/// page's one progress language: a `CardHeader` over a bar, completion as the green tick and
/// hairline (Phase U). Four kinds today; a kind this build does not know draws nothing, so a
/// new metric or mode needs no client build. Every number is the server's; this only formats.
struct PanelView: View {
    let panel: TodayPanel
    /// A hero is the calories card, or its twin in the five: a 40 pt numeral in a full card. A
    /// tile is the small card of the row beneath: "consumed / target" over a thin bar.
    var size: Size = .tile
    /// What only the phone knows, appended to the calories card's line (Apple Health's burned
    /// figure); nil leaves the server's line alone.
    var supportSuffix: String? = nil
    /// The tap for a tile the server marked `can_add` (water); nil for every other tile.
    var onAdd: (() -> Void)? = nil
    /// The plan card's tap, to the builder (meal-plan mode); nil leaves the card display-only.
    var onOpenPlan: (() -> Void)? = nil

    enum Size {
        case hero
        case tile
    }

    var body: some View {
        switch panel.knownKind {
        case .caloriesLeft?:
            caloriesCard
        case .metricTile?:
            if size == .hero {
                heroTile
            } else {
                tile
            }
        case .habitTile?:
            habitTile
        case .mealPlanSlots?:
            planCard
        case nil:
            EmptyView()
        }
    }

    // MARK: - Calories left

    private var caloriesCard: some View {
        StatCard(isComplete: panel.complete) {
            CardHeader(title: panel.title, isComplete: panel.complete, support: caloriesSupport) {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                    Text(DashboardNumber.whole(panel.remaining))
                        .font(VoCalTheme.Fonts.numeral(40))
                        .monospacedDigit()
                        // Tighten the tabular-digit advance (monospacedDigit spaces digits
                        // wide); -1.5 shaves the gap without clipping the trailing digit.
                        .tracking(-1.5)
                        // Half a 50/50 split: a 4-digit value ("2,255") or a negative
                        // over-budget value ("-320") must scale to fit, never truncate.
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(VoCalTheme.Colors.gold)
                        .accessibilityIdentifier(A11y.Today.caloriesLeft)
                    // Decorative to VoiceOver: the numeral and the line say it all, and a
                    // 14 pt element with a label is a target too small to hit (audit).
                    CalorieBar(consumed: panel.consumed, target: panel.target)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// "of 2,040 today · 320 burned": the server's line, then what the phone counted.
    private var caloriesSupport: String {
        guard let supportSuffix, !supportSuffix.isEmpty else { return panel.support }
        return "\(panel.support) · \(supportSuffix)"
    }

    // MARK: - A metric as a hero (protein beside calories, the five)

    private var heroTile: some View {
        StatCard(isComplete: panel.complete) {
            CardHeader(title: panel.title, isComplete: panel.complete, support: supportLine, supportColor: supportColor) {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(DashboardNumber.whole(panel.consumed))
                            .font(VoCalTheme.Fonts.numeral(40))
                            .monospacedDigit()
                            .tracking(-1.5)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(VoCalTheme.Colors.ink)
                        if !panel.unit.isEmpty {
                            Text(panel.unit)
                                .font(VoCalTheme.Fonts.secondaryLabel)
                                .foregroundStyle(VoCalTheme.Colors.muted)
                        }
                    }
                    // The numeral speaks the band; the bar beneath is decorative to VoiceOver
                    // (a 14 pt labelled element is a target too small to hit).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenValue)
                    bar(compact: false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - A metric as a tile

    private var tile: some View {
        StatCard(isComplete: panel.complete, radius: VoCalTheme.Radius.row, padding: VoCalTheme.Spacing.m) {
            CardHeader(title: panel.title, isComplete: panel.complete, support: supportLine, supportColor: supportColor) {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                    HStack(spacing: 0) {
                        Text(DashboardNumber.trimmed(panel.consumed))
                            .foregroundStyle(valueColor)
                        Text(" / \(DashboardNumber.trimmed(panel.target))\(unitSuffix)")
                            .foregroundStyle(VoCalTheme.Colors.muted)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    bar(compact: true)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if panel.canAdd {
                // The "+" is the affordance that tells this tile apart from the display-only
                // ones; tap anywhere on the card to add. It stays when the goal is met: a
                // full glass can still be added to (render review, 2026-09-25).
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.gold)
                    .padding(VoCalTheme.Spacing.s)
            }
        }
        .contentShape(Rectangle())
        .modifier(PanelTapToAdd(onAdd: panel.canAdd ? onAdd : nil, label: panel.title))
        .animation(.snappy(duration: 0.25), value: panel.complete)
    }

    // MARK: - A habit

    /// The one tile with no nutrient behind it ("Logged today"): the server's line is the
    /// value ("2 meals", "Not yet"), there is no bar, and the tick is the whole state.
    private var habitTile: some View {
        StatCard(isComplete: panel.complete, radius: VoCalTheme.Radius.row, padding: VoCalTheme.Spacing.m) {
            CardHeader(title: panel.title, isComplete: panel.complete) {
                Text(panel.support.isEmpty ? DashboardNumber.trimmed(panel.consumed) : panel.support)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(panel.complete ? VoCalTheme.Colors.optimal : VoCalTheme.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .animation(.snappy(duration: 0.25), value: panel.complete)
    }

    // MARK: - The plan (meal-plan mode, decision 65)

    /// The planned meals as rows, each with the server's tick, and the day's extras named under
    /// them without a verdict ("Also today"). The header's tick and the "N of M meals" line are
    /// the server's; the card's one affordance is the chevron, to the builder. With no plan the
    /// card says so and what the tap leads to; it never shows an empty list as a plan.
    private var planCard: some View {
        StatCard(isComplete: panel.complete) {
            CardHeader(title: panel.title, isComplete: panel.complete, support: planSupport, supportColor: planSupportColor) {
                VStack(alignment: .leading, spacing: VoCalTheme.Spacing.s) {
                    if panel.slots.isEmpty {
                        Text("No plan yet")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(VoCalTheme.Colors.ink)
                    } else {
                        ForEach(panel.slots) { slot in
                            planRow(slot)
                        }
                    }
                    if !panel.extras.isEmpty {
                        Text("Also today: \(panel.extras.joined(separator: ", "))")
                            .font(VoCalTheme.Fonts.formLabel)
                            .foregroundStyle(VoCalTheme.Colors.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, VoCalTheme.Spacing.xs)
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if onOpenPlan != nil {
                // The chevron is the affordance that tells this card apart from the display-only
                // ones (the water tile's "+", same place); tap anywhere on the card to open.
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoCalTheme.Colors.muted)
                    .padding(VoCalTheme.Spacing.l)
            }
        }
        .contentShape(Rectangle())
        .modifier(PlanTapToOpen(onOpen: onOpenPlan, label: planSpokenLabel))
        .animation(.snappy(duration: 0.25), value: panel.complete)
    }

    private func planRow(_ slot: PlanSlotStatus) -> some View {
        HStack(spacing: VoCalTheme.Spacing.m) {
            // The tick is the state; the name stays ink either way (a greyed row reads as
            // disabled, and a planned meal already eaten is not).
            Image(systemName: slot.logged ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(slot.logged ? VoCalTheme.Colors.optimal : VoCalTheme.Colors.muted.opacity(0.6))
                .accessibilityHidden(true)
            Text(slot.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(VoCalTheme.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: VoCalTheme.Spacing.s)
            Text("\(DashboardNumber.whole(slot.kcal)) cal")
                .font(VoCalTheme.Fonts.secondaryLabel)
                .monospacedDigit()
                .foregroundStyle(VoCalTheme.Colors.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(slot.name), \(DashboardNumber.whole(slot.kcal)) calories, \(slot.logged ? "logged" : "not yet")")
    }

    /// With a plan: the server's "3 of 4 meals". Without one: what the tap leads to.
    private var planSupport: String? {
        if panel.slots.isEmpty {
            return onOpenPlan == nil ? nil : "Build it from the meals you already eat."
        }
        return panel.support.isEmpty ? nil : panel.support
    }

    private var planSupportColor: Color? {
        panel.complete && !panel.slots.isEmpty ? VoCalTheme.Colors.optimal : nil
    }

    private var planSpokenLabel: String {
        panel.slots.isEmpty ? "Your plan, none yet" : "Your plan, \(panel.support)"
    }

    // MARK: - Shared

    private var supportLine: String? {
        panel.support.isEmpty ? nil : panel.support
    }

    /// The optimal green only for a band the person is inside; a ceiling passed and a goal not
    /// yet reached both stay muted (the bar carries the colour, the text stays calm).
    private var supportColor: Color? {
        panel.hasBand && panel.complete ? VoCalTheme.Colors.optimal : nil
    }

    private var valueColor: Color {
        if panel.knownDirection == .stayUnder, panel.over { return VoCalTheme.Colors.alert }
        return panel.complete ? VoCalTheme.Colors.optimal : VoCalTheme.Colors.ink
    }

    private var unitSuffix: String {
        panel.unit.isEmpty ? "" : " \(panel.unit)"
    }

    private var fraction: Double {
        panel.target > 0 ? panel.consumed / panel.target : 0
    }

    /// Macro colours on the macro bars (protein red, carbs amber, fat blue; DESIGN.md), the
    /// optimal green once a goal is met, the alert red once a ceiling is passed; ink otherwise.
    private var barFill: Color {
        if panel.knownDirection == .stayUnder {
            return panel.over ? VoCalTheme.Colors.alert : VoCalTheme.Colors.ink.opacity(0.55)
        }
        if panel.complete { return VoCalTheme.Colors.optimal }
        switch panel.metric {
        case "protein": return VoCalTheme.Colors.protein
        case "carbs": return VoCalTheme.Colors.carbs
        case "fat": return VoCalTheme.Colors.fats
        default: return VoCalTheme.Colors.ink.opacity(0.55)
        }
    }

    @ViewBuilder
    private func bar(compact: Bool) -> some View {
        if panel.hasBand, let low = panel.bandLow, let high = panel.bandHigh {
            RangeBar(consumed: panel.consumed, low: low, high: high, compact: compact)
        } else if compact {
            MicroBar(fraction: fraction, fill: barFill)
        } else {
            CalorieBar(consumed: panel.consumed, target: panel.target)
        }
    }

    private var spokenValue: String {
        let value = DashboardNumber.trimmed(panel.consumed)
        if panel.hasBand, let low = panel.bandLow, let high = panel.bandHigh {
            return "\(value) \(panel.unit) of \(panel.title.lowercased()), optimal \(DashboardNumber.whole(low)) to \(DashboardNumber.whole(high))"
        }
        return "\(panel.title): \(value) of \(DashboardNumber.trimmed(panel.target)) \(panel.unit)"
    }
}

/// Adds the tap-to-add gesture only to a tile the server marked `can_add` (water). Every other
/// tile stays non-interactive: no dead tap, and only the interactive tile advertises the button
/// trait to VoiceOver.
private struct PanelTapToAdd: ViewModifier {
    let onAdd: (() -> Void)?
    let label: String

    func body(content: Content) -> some View {
        if let onAdd {
            content
                .onTapGesture(perform: onAdd)
                .accessibilityIdentifier(A11y.Today.waterTile)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Add \(label.lowercased())")
        } else {
            content
        }
    }
}

/// Adds the tap only to a plan card given somewhere to go (Today); a plan card drawn with no
/// destination stays non-interactive and advertises no button to VoiceOver.
private struct PlanTapToOpen: ViewModifier {
    let onOpen: (() -> Void)?
    let label: String

    func body(content: Content) -> some View {
        if let onOpen {
            content
                .onTapGesture(perform: onOpen)
                .accessibilityIdentifier(A11y.Today.planCard)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(label)
                .accessibilityHint("Edit your plan")
        } else {
            content
        }
    }
}

// MARK: - Layout

/// How the panels sit on the page, from the mode: the plan card, when there is one, full width
/// and first; the five keeps its twin heroes (calories beside protein, Phase U); every other
/// mode shows the calories card full width, then the tiles. Tiles sit three to a row and wrap
/// at four or more (spec 6.4).
enum PanelLayout {
    struct Arrangement: Equatable {
        /// Cards drawn full width before the heroes: the plan card.
        var fullWidth: [TodayPanel] = []
        var heroes: [TodayPanel]
        var tileRows: [[TodayPanel]]
    }

    static func arrange(_ panels: [TodayPanel], mode: TrackingMode) -> Arrangement {
        let known = panels.filter { $0.knownKind != nil }
        var fullWidth: [TodayPanel] = []
        var heroes: [TodayPanel] = []
        var tiles: [TodayPanel] = []
        for (index, panel) in known.enumerated() {
            if panel.knownKind == .mealPlanSlots {
                fullWidth.append(panel)
            } else if panel.knownKind == .caloriesLeft, heroes.isEmpty {
                heroes.append(panel)
            } else if index == 1, heroes.count == 1, panel.knownKind == .metricTile, panel.hasBand, mode == .five {
                heroes.append(panel)
            } else {
                tiles.append(panel)
            }
        }
        return Arrangement(fullWidth: fullWidth, heroes: heroes, tileRows: rows(tiles))
    }

    /// Up to three a row; four or more spread over as few rows as possible, the fuller rows
    /// first (four: two and two; five: three and two).
    static func rows(_ tiles: [TodayPanel]) -> [[TodayPanel]] {
        guard !tiles.isEmpty else { return [] }
        let count = tiles.count
        let rowCount = (count + 2) / 3
        let base = count / rowCount
        var remainder = count % rowCount
        var rows: [[TodayPanel]] = []
        var start = 0
        for _ in 0..<rowCount {
            let size = base + (remainder > 0 ? 1 : 0)
            if remainder > 0 { remainder -= 1 }
            rows.append(Array(tiles[start..<start + size]))
            start += size
        }
        return rows
    }
}

// MARK: - Numbers as the page prints them

enum DashboardNumber {
    /// "2,040": rounded to a whole, grouped.
    static func whole(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    /// "2,300" or "2.5": a whole number grouped, a fraction to one place with no trailing ".0".
    static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return Int(rounded).formatted(.number.grouping(.automatic)) }
        return String(format: "%.1f", rounded)
    }
}

// MARK: - Bars

/// The day's calories as a bar, the range bar's twin: consumed of the target in gold, and in
/// the alert red once the target is passed. Same 14 pt frame as `RangeBar` so the two cards
/// keep one height. Numbers are engine-owned (AGENTS.md #6).
struct CalorieBar: View {
    var consumed: Double
    var target: Double

    var body: some View {
        let fraction = target > 0 ? consumed / target : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(VoCalTheme.Colors.muted.opacity(0.16))
                Capsule()
                    .fill(fraction > 1 ? VoCalTheme.Colors.alert : VoCalTheme.Colors.gold)
                    .frame(width: max(consumed > 0 ? 8 : 0, geo.size.width * min(1, max(0, fraction))))
            }
            .frame(height: 8)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("\(Int(consumed.rounded())) of \(Int(target.rounded())) calories")
    }
}

/// Thin progress bar for a tile. The fill is the caller's: ink while reaching, the optimal
/// green once reached, a macro colour on a macro tile, the alert red past a ceiling.
struct MicroBar: View {
    var fraction: Double
    var fill: Color = VoCalTheme.Colors.ink.opacity(0.55)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(VoCalTheme.Colors.muted.opacity(0.18))
                Capsule()
                    .fill(fill)
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// Bounded-goal bar (protein): a centered green "optimal" band on a neutral track, with a gold
/// thumb that travels as the metric is logged. Unlike the reach bars, protein is NOT
/// more-is-merrier: too little AND too much are both suboptimal, so the axis leaves a lead-in
/// below the band and overshoot room above it (a quarter of the band each), which keeps the
/// green zone centred and about two thirds of the bar. The thumb clamps to the ends when off
/// scale; the support line carries the exact gap. `compact` is the tile's size.
struct RangeBar: View {
    var consumed: Double
    var low: Double
    var high: Double
    var compact = false

    var body: some View {
        let trackHeight: CGFloat = compact ? 5 : 8
        let thumb: CGFloat = compact ? 9 : 13
        GeometryReader { geo in
            let w = geo.size.width
            let band = max(high - low, 1)
            let pad = band * 0.25
            let axisMin = max(0, low - pad)
            let axisMax = high + pad
            let span = max(axisMax - axisMin, 1)
            let bandStart = w * frac(low, axisMin, span)
            let bandEnd = w * frac(high, axisMin, span)
            let position = w * frac(consumed, axisMin, span)

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(VoCalTheme.Colors.muted.opacity(0.16))
                    Capsule()
                        .fill(VoCalTheme.Colors.optimal.opacity(0.38))
                        .frame(width: max(0, bandEnd - bandStart))
                        .offset(x: bandStart)
                }
                .frame(height: trackHeight)
                .frame(maxHeight: .infinity, alignment: .center)

                Circle()
                    .fill(VoCalTheme.Colors.gold)
                    .overlay(Circle().stroke(VoCalTheme.Colors.background, lineWidth: 2))
                    .frame(width: thumb, height: thumb)
                    .offset(x: min(w - thumb, max(0, position - thumb / 2)))
            }
        }
        .frame(height: compact ? 9 : 14)
        .accessibilityElement()
        .accessibilityLabel("\(Int(consumed.rounded())), optimal \(Int(low.rounded())) to \(Int(high.rounded()))")
    }

    private func frac(_ value: Double, _ axisMin: Double, _ span: Double) -> Double {
        min(1, max(0, (value - axisMin) / span))
    }
}

#Preview("Panels") {
    let targets = DayTotals(kcal: 2040, protein: 150, carbs: 200, fat: 60, fiber: 30, produce: 5, water: 96)
    let consumed = DayTotals(kcal: 1980, protein: 152, carbs: 188, fat: 64, fiber: 24, produce: 5, water: 96)
    let remaining = DayTotals(kcal: 60, protein: -2, carbs: 12, fat: -4, fiber: 6, produce: 0, water: 0)
    ScrollView {
        VStack(spacing: VoCalTheme.Spacing.l) {
            ForEach(TrackingMode.offered) { mode in
                Text(mode.title).sectionHeader()
                let panels = PanelComposer.compose(
                    mode: mode, targets: targets, consumed: consumed, remaining: remaining,
                    proteinBand: (135, 165), mealsToday: 4,
                    planPanel: PlanComposer.panel(plan: MockMealPlanService.canned, meals: [])
                )
                let arrangement = PanelLayout.arrange(panels, mode: mode)
                ForEach(arrangement.fullWidth) { PanelView(panel: $0, size: .hero, onOpenPlan: {}) }
                HStack(alignment: .top, spacing: VoCalTheme.Spacing.m) {
                    ForEach(arrangement.heroes) { PanelView(panel: $0, size: .hero) }
                }
                .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(arrangement.tileRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: VoCalTheme.Spacing.s) {
                        ForEach(row) { PanelView(panel: $0) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
    }
    .background(VoCalTheme.Colors.background)
}
