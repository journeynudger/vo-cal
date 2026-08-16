import Foundation

// Swift mirrors of the weekly-budget wire contract (services/api weekbudget/schemas.py).
// Field names map to snake_case via VoCalJSON. Decode rule (apps/ios/AGENTS.md): declare
// only the keys the UI consumes; server-added fields are ignored, and later additions
// must be Optional-safe here.

/// One day of the week as `/week/budget` computes it. `state` stays a raw string so an
/// unknown value can never fail the whole decode; the view maps it leniently.
struct WeekBudgetDay: Codable, Sendable, Equatable, Identifiable {
    var date: String          // YYYY-MM-DD in the user's timezone
    var weekday: Int          // 0 = Monday .. 6 = Sunday
    var plannedKcal: Double
    /// Whole kcal by contract — the engine rounds once at the edge so the week
    /// total stays exact (see engine._round_days).
    var adjustedTargetKcal: Int
    var consumedKcal: Double
    var logged: Bool
    var state: String

    var id: String { date }

    var isPast: Bool { state == "past" }
    var isToday: Bool { state == "today" }
    /// Today + future are the replannable days (past is frozen server-side).
    var isAdjustable: Bool { !isPast }
}

/// `GET /week/budget` (and the `PUT /week/plan` success payload — same shape).
struct WeekBudget: Codable, Sendable, Equatable {
    var weekStart: String
    var weekEnd: String
    var baselineDailyKcal: Double
    var weeklyTargetKcal: Double
    /// Positive = under-ate so far (headroom to spend); negative = over-ate.
    var carryKcal: Double
    /// Sum of remaining adjusted targets minus today's consumed so far.
    var remainingKcal: Double
    var fullyRebalanced: Bool
    var leftoverKcal: Double
    var targetsAreStub: Bool
    var days: [WeekBudgetDay]
}

/// `PUT /week/plan` body. `allocations` may only name today+future dates (whole
/// kcal); the server freezes past days and validates the weekly sum.
struct WeekPlanRequest: Codable, Sendable, Equatable {
    var weekStart: String
    var tz: String?
    var allocations: [String: Int]
}
