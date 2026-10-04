import Foundation

// Swift mirror of the /meals/today response (services/api meals/today.py TodayResponse).
// Field names map to snake_case via VoCalJSON (convertFromSnakeCase). Clients decode only
// the keys they declare, so server-added fields are ignored. The server composes the cards
// for the person's mode (`panels`, decision 60); the seven totals ride along for the rows,
// the edit sheet, and a server one deploy behind the app.

/// The seven tracked daily figures, shared by targets / consumed / remaining.
struct DayTotals: Codable, Sendable, Equatable {
    var kcal: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var produce: Double = 0   // servings/day
    var water: Double = 0     // oz/day
}

/// One logged meal as the Today list shows it (compact — not the full result).
/// `mealType` stays a raw string (server `meal_type`) so an unknown value can never fail
/// decoding; the view maps it to a glyph/label.
struct TodayMealRow: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String?
    var mealType: String
    var loggedAt: Date
    var totals: [String: Double]

    var kcal: Double { totals["kcal"] ?? 0 }
}

/// One card the server composed for the person's mode (meals/dashboard.py Panel). Drawn by
/// `kind`; a kind this build does not know is skipped, so a new metric or mode never needs a
/// client build. Every number here is the server's: the client formats and lays out, never
/// calculates (AGENTS.md #6).
struct TodayPanel: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        case caloriesLeft = "calories_left"
        case metricTile = "metric_tile"
        case habitTile = "habit_tile"
    }

    /// `land` completes inside a window (calories, a protein band); `reach` at or above the
    /// target; `stayUnder` never completes and turns `over` past the target (sugar, sodium).
    enum Direction: String, Sendable {
        case land
        case reach
        case stayUnder = "stay_under"
    }

    var kind: String
    var metric: String
    var title: String
    var consumed: Double
    var target: Double
    var remaining: Double
    var unit: String = ""
    var direction: String = Direction.reach.rawValue
    var complete = false
    var over = false
    var bandLow: Double?
    var bandHigh: Double?
    /// The one line under the value; empty when the value line already says it.
    var support: String = ""
    /// The water tile alone can be tapped (POST /meals/water); nothing else has an entry point.
    var canAdd = false
    /// Foods in the day with no value for this nutrient; shown, never counted as zero.
    var unknownItems = 0

    var id: String { "\(kind).\(metric)" }
    var knownKind: Kind? { Kind(rawValue: kind) }
    var knownDirection: Direction { Direction(rawValue: direction) ?? .reach }

    var hasBand: Bool {
        guard let bandLow, let bandHigh else { return false }
        return bandHigh > bandLow
    }
}

// Tolerant decode (the decode rule, apps/ios/AGENTS.md): only the kind, the metric, the title
// and the three numbers are required; everything else takes its default when the server
// leaves it out. In an extension so the memberwise initializer survives for the composer.
extension TodayPanel {
    private enum CodingKeys: String, CodingKey {
        case kind, metric, title, consumed, target, remaining, unit, direction, complete, over
        case bandLow, bandHigh, support, canAdd, unknownItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        metric = try container.decode(String.self, forKey: .metric)
        title = try container.decode(String.self, forKey: .title)
        consumed = try container.decode(Double.self, forKey: .consumed)
        target = try container.decode(Double.self, forKey: .target)
        remaining = try container.decode(Double.self, forKey: .remaining)
        unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? ""
        direction = try container.decodeIfPresent(String.self, forKey: .direction) ?? Direction.reach.rawValue
        complete = try container.decodeIfPresent(Bool.self, forKey: .complete) ?? false
        over = try container.decodeIfPresent(Bool.self, forKey: .over) ?? false
        bandLow = try container.decodeIfPresent(Double.self, forKey: .bandLow)
        bandHigh = try container.decodeIfPresent(Double.self, forKey: .bandHigh)
        support = try container.decodeIfPresent(String.self, forKey: .support) ?? ""
        canAdd = try container.decodeIfPresent(Bool.self, forKey: .canAdd) ?? false
        unknownItems = try container.decodeIfPresent(Int.self, forKey: .unknownItems) ?? 0
    }
}

/// The full Today dashboard payload.
struct TodayDashboard: Codable, Sendable, Equatable {
    var date: String
    var targets: DayTotals
    var consumed: DayTotals
    var remaining: DayTotals
    var meals: [TodayMealRow]
    var avgConfidence: Double = 0
    /// True when no active protocol exists yet (pre-onboarding stub targets are in play) —
    /// the UI nudges toward setting up a protocol instead of implying a real plan.
    var targetsAreStub: Bool = false
    /// Protein optimal band (server-owned, AGENTS.md #6): too little AND too much are both
    /// suboptimal, so protein renders as a centered green range — not a more-is-merrier fill.
    /// Both default to the protein target (a zero-width band) for protocols built before it.
    var proteinMin: Double = 0
    var proteinMax: Double = 0
    /// The person's mode and what it prints (decisions 57 to 61). `printsNumbers` is false
    /// only in habits mode and governs the rows, the chips, the week card and the result as
    /// well as the cards (the Rams review, R8).
    var mode: TrackingMode = .five
    var printsNumbers = true
    var showsWeekCard = true
    /// The cards, composed server-side for the mode. Empty from a server that predates them.
    var panels: [TodayPanel] = []

    /// The panels to draw: the server's, or, for a dashboard from an API one deploy behind the
    /// app (totals, no `panels`), the five composed from the totals it did send.
    var panelsToDraw: [TodayPanel] {
        if !panels.isEmpty { return panels }
        return PanelComposer.compose(
            mode: .five,
            targets: targets,
            consumed: consumed,
            remaining: remaining,
            proteinBand: (
                proteinMin > 0 ? proteinMin : targets.protein,
                proteinMax > 0 ? proteinMax : targets.protein
            ),
            mealsToday: meals.count
        )
    }
}

// Tolerant decode for the later-added fields. A Swift default value does NOT make the
// synthesized decoder tolerant — it still requires the key — so a dashboard from an API
// one deploy behind the app (or a field ever renamed server-side) would fail the WHOLE
// Today load, not degrade one figure (deferred item from #18). In an extension so the
// memberwise initializer survives for previews/mocks; encode stays synthesized.
extension TodayDashboard {
    private enum CodingKeys: String, CodingKey {
        case date, targets, consumed, remaining, meals
        case avgConfidence, targetsAreStub, proteinMin, proteinMax
        case mode, printsNumbers, showsWeekCard, panels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        targets = try container.decode(DayTotals.self, forKey: .targets)
        consumed = try container.decode(DayTotals.self, forKey: .consumed)
        remaining = try container.decode(DayTotals.self, forKey: .remaining)
        meals = try container.decode([TodayMealRow].self, forKey: .meals)
        avgConfidence = try container.decodeIfPresent(Double.self, forKey: .avgConfidence) ?? 0
        targetsAreStub = try container.decodeIfPresent(Bool.self, forKey: .targetsAreStub) ?? false
        proteinMin = try container.decodeIfPresent(Double.self, forKey: .proteinMin) ?? 0
        proteinMax = try container.decodeIfPresent(Double.self, forKey: .proteinMax) ?? 0
        // A mode this build does not know draws as the five, the dashboard every build can
        // draw; its panels still come from the server and render by kind.
        let rawMode = try container.decodeIfPresent(String.self, forKey: .mode) ?? TrackingMode.five.rawValue
        mode = TrackingMode(rawValue: rawMode) ?? .five
        printsNumbers = try container.decodeIfPresent(Bool.self, forKey: .printsNumbers) ?? true
        showsWeekCard = try container.decodeIfPresent(Bool.self, forKey: .showsWeekCard) ?? true
        panels = try container.decodeIfPresent([TodayPanel].self, forKey: .panels) ?? []
    }
}
