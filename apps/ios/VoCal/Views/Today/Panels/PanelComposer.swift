import Foundation

/// The server composes Today's panels (services/api meals/dashboard.py, decision 60). This is
/// its twin for the two places that have no server: the sim's canned dashboards, composed per
/// mode so every mode renders and records with zero network, and a dashboard from an API one
/// deploy behind the app, which carries the seven totals and no `panels`. The rules mirror the
/// server's line for line and its tests pin them there; once every API carries panels, the
/// fallback caller goes and this stays the mock's. The phone never prices a food here: it
/// arranges the totals the server already summed.
enum PanelComposer {
    /// Calories "land" when the day ends inside this window of the target.
    private static let caloriesLow = 0.90
    private static let caloriesHigh = 1.05

    static func compose(
        mode: TrackingMode,
        focus: [FocusMetric] = [],
        targets: DayTotals,
        consumed: DayTotals,
        remaining: DayTotals,
        proteinBand: (low: Double, high: Double),
        mealsToday: Int,
        planPanel: TodayPanel? = nil
    ) -> [TodayPanel] {
        var panels: [TodayPanel?] = []
        switch mode {
        case .habits:
            panels.append(logged(mealsToday))
            panels.append(tile("water", targets, consumed, remaining, canAdd: true))
            panels.append(tile("produce", targets, consumed, remaining))
        case .calories:
            panels.append(calories(targets, consumed, remaining))
        case .macros:
            panels.append(calories(targets, consumed, remaining))
            panels.append(tile("protein", targets, consumed, remaining, band: proteinBand))
            panels.append(tile("carbs", targets, consumed, remaining))
            panels.append(tile("fat", targets, consumed, remaining))
        case .five:
            panels.append(calories(targets, consumed, remaining))
            panels.append(tile("protein", targets, consumed, remaining, band: proteinBand))
            panels.append(tile("produce", targets, consumed, remaining))
            panels.append(tile("water", targets, consumed, remaining, canAdd: true))
            panels.append(tile("fiber", targets, consumed, remaining))
        case .mealPlan:
            // The plan is the page (decision 65); calories beneath it. The plan card is built
            // by `PlanComposer.panel` from the plan and the day's rows, as the server does.
            panels.append(planPanel)
            panels.append(calories(targets, consumed, remaining))
        }
        for metric in extraMetrics(mode: mode, focus: focus) {
            panels.append(
                tile(
                    metric.rawValue, targets, consumed, remaining,
                    band: metric == .protein ? proteinBand : nil,
                    canAdd: metric == .water
                )
            )
        }
        return panels.compactMap { $0 }
    }

    /// The server's own-metrics table (tracking/projection.py): what a mode already prints, so a
    /// focus metric adds only what is not there. The live path reads `offerable_focus` from the
    /// response; the sim and the fallback read this.
    static func offerableFocus(for mode: TrackingMode) -> [FocusMetric] {
        FocusMetric.allCases.filter { !ownMetrics(mode).contains($0.rawValue) }
    }

    private static func ownMetrics(_ mode: TrackingMode) -> Set<String> {
        switch mode {
        case .habits: ["water", "produce"]
        case .calories: []
        case .five, .mealPlan: ["protein", "produce", "water", "fiber"]
        case .macros: ["protein", "carbs", "fat"]
        }
    }

    private static func extraMetrics(mode: TrackingMode, focus: [FocusMetric]) -> [FocusMetric] {
        let own = ownMetrics(mode)
        var seen: Set<FocusMetric> = []
        return focus.filter { metric in
            guard !own.contains(metric.rawValue), !seen.contains(metric) else { return false }
            seen.insert(metric)
            return true
        }
    }

    private static func calories(_ targets: DayTotals, _ consumed: DayTotals, _ remaining: DayTotals) -> TodayPanel {
        let target = targets.kcal
        let eaten = consumed.kcal
        let ratio = target > 0 ? eaten / target : 0
        return TodayPanel(
            kind: TodayPanel.Kind.caloriesLeft.rawValue,
            metric: "kcal",
            title: "Calories left",
            consumed: eaten,
            target: target,
            remaining: remaining.kcal,
            unit: "cal",
            direction: TodayPanel.Direction.land.rawValue,
            complete: target > 0 && ratio >= caloriesLow && ratio <= caloriesHigh,
            over: eaten > target,
            support: "of \(DashboardNumber.whole(target)) today"
        )
    }

    private static func tile(
        _ metric: String,
        _ targets: DayTotals,
        _ consumed: DayTotals,
        _ remaining: DayTotals,
        band: (low: Double, high: Double)? = nil,
        canAdd: Bool = false
    ) -> TodayPanel? {
        guard let target = targets.value(for: metric), let eaten = consumed.value(for: metric), target > 0 else {
            return nil
        }
        let left = remaining.value(for: metric) ?? ((target - eaten) * 10).rounded() / 10
        let unit = units[metric] ?? ""
        if let band, band.low < band.high, metric == "protein" {
            return TodayPanel(
                kind: TodayPanel.Kind.metricTile.rawValue,
                metric: metric,
                title: titles[metric] ?? metric.capitalized,
                consumed: eaten,
                target: target,
                remaining: left,
                unit: unit,
                direction: TodayPanel.Direction.land.rawValue,
                complete: eaten >= band.low && eaten <= band.high,
                over: eaten > band.high,
                bandLow: band.low,
                bandHigh: band.high,
                support: bandSupport(eaten, band.low, band.high),
                canAdd: canAdd
            )
        }
        return TodayPanel(
            kind: TodayPanel.Kind.metricTile.rawValue,
            metric: metric,
            title: titles[metric] ?? metric.capitalized,
            consumed: eaten,
            target: target,
            remaining: left,
            unit: unit,
            direction: TodayPanel.Direction.reach.rawValue,
            complete: eaten >= target,
            over: false,
            support: "",
            canAdd: canAdd
        )
    }

    private static func bandSupport(_ eaten: Double, _ low: Double, _ high: Double) -> String {
        if eaten < low { return "\(DashboardNumber.whole(low - eaten)) g to optimal" }
        if eaten > high { return "\(DashboardNumber.whole(eaten - high)) g over optimal" }
        return "In your optimal range"
    }

    private static func logged(_ mealsToday: Int) -> TodayPanel {
        let support: String
        switch mealsToday {
        case ..<1: support = "Not yet"
        case 1: support = "1 meal"
        default: support = "\(mealsToday) meals"
        }
        return TodayPanel(
            kind: TodayPanel.Kind.habitTile.rawValue,
            metric: "logged",
            title: "Logged today",
            consumed: Double(mealsToday),
            target: 1,
            remaining: Double(max(0, 1 - mealsToday)),
            unit: "",
            direction: TodayPanel.Direction.reach.rawValue,
            complete: mealsToday >= 1,
            over: false,
            support: support
        )
    }

    private static let titles: [String: String] = [
        "kcal": "Calories left", "protein": "Protein", "carbs": "Carbs", "fat": "Fat",
        "fiber": "Fiber", "water": "Water", "produce": "Produce", "sugar": "Sugar", "sodium": "Sodium",
    ]
    private static let units: [String: String] = [
        "kcal": "cal", "protein": "g", "carbs": "g", "fat": "g", "fiber": "g", "sugar": "g",
        "water": "oz", "sodium": "mg", "produce": "",
    ]
}

extension DayTotals {
    /// The seven figures by the server's metric key; nil for a metric this type does not carry
    /// (sugar and sodium ride only on the server's panels).
    func value(for metric: String) -> Double? {
        switch metric {
        case "kcal": kcal
        case "protein": protein
        case "carbs": carbs
        case "fat": fat
        case "fiber": fiber
        case "produce": produce
        case "water": water
        default: nil
        }
    }
}

/// The meal plan's twin of the server (services/api meals/plan.py `check_plan`, `match_slots`,
/// `plan_panel`), for the sim only: the mock Today ticks the canned plan against the canned day,
/// and the mock builder says what the engine would. Line for line with the server; the live path
/// prints the server's card and line and never runs this.
enum PlanComposer {
    /// The plan lands when its calories are within this share of the target and its protein
    /// reaches the band's floor (plan P8).
    static let kcalTolerance = 0.10

    static func check(
        _ slots: [PlanSlot],
        targetKcal: Double = 2040,
        proteinFloor: Double = 135
    ) -> PlanCheck {
        let kcal = (slots.reduce(0) { $0 + $1.totals.kcal } * 10).rounded() / 10
        let protein = (slots.reduce(0) { $0 + $1.totals.protein } * 10).rounded() / 10
        let kcalWithin = targetKcal > 0 && abs(kcal - targetKcal) <= kcalTolerance * targetKcal
        let proteinOk = protein >= proteinFloor
        return PlanCheck(
            kcal: kcal, protein: protein, targetKcal: targetKcal, proteinFloor: proteinFloor,
            kcalWithin: kcalWithin, proteinOk: proteinOk,
            line: line(kcal: kcal, protein: protein, target: targetKcal, floor: proteinFloor, kcalWithin: kcalWithin, proteinOk: proteinOk)
        )
    }

    /// One sentence, the facts and no verdict on the person (spec 6.10). "Covered" for protein,
    /// because the band's floor is a floor, not a target.
    private static func line(kcal: Double, protein: Double, target: Double, floor: Double, kcalWithin: Bool, proteinOk: Bool) -> String {
        if kcalWithin && proteinOk {
            return "On your protocol: \(DashboardNumber.whole(kcal)) of \(DashboardNumber.whole(target)) calories, protein covered."
        }
        var parts: [String] = []
        if !kcalWithin {
            let gap = target - kcal
            parts.append("\(DashboardNumber.whole(abs(gap))) calories \(gap > 0 ? "under" : "over") your protocol")
        }
        if !proteinOk {
            parts.append("protein \(DashboardNumber.whole(floor - protein)) g under the band")
        }
        let sentence = parts.joined(separator: "; ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }

    /// Tick the slots the day's meals fill, by name, each slot at most once, in the order the
    /// meals were logged; the rest come back as the "also today" names.
    static func match(_ slots: [PlanSlot], meals: [TodayMealRow]) -> (statuses: [PlanSlotStatus], extras: [String]) {
        var statuses = slots.map { PlanSlotStatus(index: $0.index, name: $0.name, kcal: $0.totals.kcal) }
        var open: [String: [Int]] = [:]
        for (position, slot) in slots.enumerated() {
            open[nameKey(slot.name), default: []].append(position)
        }
        var extras: [String] = []
        for meal in meals.sorted(by: { $0.loggedAt < $1.loggedAt }) {
            let name = meal.name ?? "Meal"
            if var waiting = open[nameKey(name)], !waiting.isEmpty {
                let position = waiting.removeFirst()
                open[nameKey(name)] = waiting
                statuses[position].logged = true
                statuses[position].mealId = meal.id
            } else {
                extras.append(name)
            }
        }
        return (statuses, extras)
    }

    /// The `meal_plan_slots` card. With no plan the card says so and lists what was logged, so
    /// the page is never blank and never claims a plan that does not exist.
    static func panel(plan: MealPlan?, meals: [TodayMealRow]) -> TodayPanel {
        guard let plan, !plan.slots.isEmpty else {
            return TodayPanel(
                kind: TodayPanel.Kind.mealPlanSlots.rawValue, metric: "plan", title: "Your plan",
                consumed: 0, target: 0, remaining: 0, support: "No plan yet",
                slots: [], extras: meals.sorted(by: { $0.loggedAt < $1.loggedAt }).map { $0.name ?? "Meal" }
            )
        }
        let (statuses, extras) = match(plan.slots, meals: meals)
        let logged = statuses.filter(\.logged).count
        let count = statuses.count
        return TodayPanel(
            kind: TodayPanel.Kind.mealPlanSlots.rawValue, metric: "plan", title: "Your plan",
            consumed: Double(logged), target: Double(count), remaining: Double(count - logged),
            complete: logged >= count,
            support: "\(logged) of \(count) meal\(count == 1 ? "" : "s")",
            slots: statuses, extras: extras
        )
    }

    /// The server's auto name (meals/naming.py `auto_name`), for the mock's typed slots: the
    /// heaviest items first, up to three named, then "& N more".
    static func autoName(_ items: [ConfirmedItem]) -> String {
        let named = items.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !named.isEmpty else { return "Meal" }
        let ordered = named.enumerated().sorted { a, b in
            a.element.macros.kcal != b.element.macros.kcal ? a.element.macros.kcal > b.element.macros.kcal : a.offset < b.offset
        }.map { $0.element.name }
        var seen: Set<String> = []
        let unique = ordered.filter { seen.insert($0.lowercased()).inserted }
        let shown = Array(unique.prefix(3))
        let rest = unique.count - shown.count
        var name: String
        switch shown.count {
        case 1: name = shown[0]
        case 2: name = "\(shown[0]) & \(shown[1])"
        default: name = rest > 0 ? "\(shown[0]), \(shown[1]) & \(rest + 1) more" : "\(shown[0]), \(shown[1]) & \(shown[2])"
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func nameKey(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
