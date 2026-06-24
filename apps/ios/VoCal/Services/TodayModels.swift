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
