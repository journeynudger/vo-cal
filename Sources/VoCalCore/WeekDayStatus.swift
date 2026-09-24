import Foundation

/// How one day of the week stacked up against its calorie goal.
///
/// Pure classification so every surface that renders the week (the budget graph,
/// Today's card, the Progress page) agrees on what "under", "on target" and
/// "over" mean — one rule, not three drifting copies of a threshold.
///
/// The on-target band is the app's existing definition of a landed day
/// (`TodayView.caloriesComplete`, decision #28): calories are a BUDGET, so the
/// win is landing in 90–105% of the goal, not eating as little as possible.
/// A day nobody logged is `notLogged`, never `under` — missing data is not a
/// deficit (facts-first, AGENTS.md #4), and a day still in progress is
/// `inProgress` until it either ends or actually goes over.
public enum WeekDayStatus: String, Sendable, Equatable, CaseIterable {
    /// Finished the day meaningfully below goal.
    case under
    /// Landed in the goal band.
    case onTarget
    /// Finished (or is already) above goal.
    case over
    /// Today, still inside the band with room left.
    case inProgress
    /// A past day with no meal logs at all.
    case notLogged
    /// A day that hasn't happened yet.
    case upcoming

    /// Lower edge of the on-target band, as a fraction of the day's goal.
    public static let onTargetLowFraction = 0.90
    /// Upper edge of the on-target band, as a fraction of the day's goal.
    public static let onTargetHighFraction = 1.05

    /// Classify a day.
    ///
    /// - Parameters:
    ///   - consumed: kcal logged for the day.
    ///   - goal: the day's own calorie goal (its adjusted target — what the app
    ///     actually asked for that day, which is the plan itself unless the
    ///     week was rebalanced).
    ///   - isPast: the day has ended.
    ///   - isToday: the day is in progress.
    ///   - logged: at least one live meal log exists for the day.
    public static func classify(
        consumed: Double,
        goal: Double,
        isPast: Bool,
        isToday: Bool,
        logged: Bool
    ) -> WeekDayStatus {
        guard isPast || isToday else { return .upcoming }
        // A goal of zero can't be over- or under-shot; treat it as unscored.
        guard goal > 0 else { return isToday ? .inProgress : (logged ? .onTarget : .notLogged) }
        if isPast && !logged { return .notLogged }

        let ratio = consumed / goal
        if ratio > onTargetHighFraction { return .over }
        // Today is only judged for going OVER: a day still in progress hasn't
        // failed to reach anything yet, so it never renders as "under" (no
        // nagging, decision #28).
        if isToday { return .inProgress }
        return ratio < onTargetLowFraction ? .under : .onTarget
    }

    /// Whether this status carries a scored result (drives whether a surface
    /// shows a delta figure for the day).
    public var isScored: Bool {
        switch self {
        case .under, .onTarget, .over: return true
        case .inProgress, .notLogged, .upcoming: return false
        }
    }
}

/// A week's running total against its goal, phrased the way the product says it:
/// plain "X over" or "on plan", never jargon.
///
/// Since 2026-09-24 the server carries overages only: a tracked day under its plan is
/// indistinguishable from an unfinished log (one coffee is a log), so it banks nothing and
/// the week never says "under". The branch stays for an older server, and reads honestly
/// if it ever fires.
public struct WeekStanding: Sendable, Equatable {
    /// Negative = over the goal so far; zero = on plan. (Positive only from an old server.)
    public let carryKcal: Double
    /// Below this many kcal either way, the week reads as on plan — rounding
    /// noise should not be reported as a result.
    public static let onPlanTolerance = 25.0

    public init(carryKcal: Double) {
        self.carryKcal = carryKcal
    }

    public var isOver: Bool { carryKcal <= -Self.onPlanTolerance }
    public var isUnder: Bool { carryKcal >= Self.onPlanTolerance }
    public var isOnPlan: Bool { !isOver && !isUnder }

    /// The short chip label: "480 over", "220 under", "on plan".
    public var shortLabel: String {
        if isOver { return "\(Int(abs(carryKcal).rounded())) over" }
        if isUnder { return "\(Int(carryKcal.rounded())) under" }
        return "on plan"
    }

    /// The sentence form used where there is room: "480 calories over so far".
    public var sentence: String {
        if isOnPlan { return "On plan so far this week" }
        let amount = Int(abs(carryKcal).rounded())
        return "\(amount) calories \(isOver ? "over" : "under") so far this week"
    }
}
