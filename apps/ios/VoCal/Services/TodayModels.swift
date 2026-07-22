import Foundation

// Swift mirror of the /meals/today response (services/api meals/today.py TodayResponse).
// Field names map to snake_case via VoCalJSON (convertFromSnakeCase). Clients decode only
// the keys they declare, so server-added fields are ignored. Carbs and fat ride along for
// meal detail but are NOT home-dashboard pillars (decision #28): the dashboard headlines
// calories · protein · produce · fiber · water.

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
    }
}
