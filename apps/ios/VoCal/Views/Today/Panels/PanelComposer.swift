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
        mealsToday: Int
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
        case .five, .mealPlan:
            panels.append(calories(targets, consumed, remaining))
            panels.append(tile("protein", targets, consumed, remaining, band: proteinBand))
            panels.append(tile("produce", targets, consumed, remaining))
            panels.append(tile("water", targets, consumed, remaining, canAdd: true))
            panels.append(tile("fiber", targets, consumed, remaining))
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
