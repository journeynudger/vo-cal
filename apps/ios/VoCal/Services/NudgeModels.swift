import Foundation

// Swift mirrors of the nudge-plan bodies (services/api nudges/schemas.py). Field names
// map to snake_case via VoCalJSON. Every server-added field must stay Optional-safe
// here (decode rule: apps/ios/AGENTS.md) — these decode only the keys they declare.

/// One nudge, exactly as the deterministic server engine selected it. The copy is
/// the product's coaching voice (empathy-first); the client never rewrites it.
struct NudgeCard: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var category: String
    var message: String
    var proTip: String
    var priority: Int
    var cooldownDays: Int
}

/// A nudge the client should deliver later as a LOCAL notification. `fireAt` is the
/// server-computed user-local fire time (quiet-hours already applied server-side).
struct ScheduledNudge: Codable, Sendable, Equatable {
    var fireAt: Date
    var card: NudgeCard
}

/// `POST /nudges/plan` response: at most one immediate card (in-app surface) plus
/// the local-notification schedule. Deterministic: same context + ledger → same plan.
struct NudgePlan: Codable, Sendable, Equatable {
    var immediate: [NudgeCard]
    var scheduled: [ScheduledNudge]

    static let empty = NudgePlan(immediate: [], scheduled: [])
}

/// `POST /nudges/plan` request: the client-owned shown-ledger (nudge id → ISO date
/// last shown) plus the user's delivery level. Advisory — a stale ledger repeats a
/// nudge, never harms.
struct NudgePlanRequest: Codable, Sendable, Equatable {
    var recentlyShown: [String: String]
    var level: String = NudgeLevel.essential.rawValue
}

/// How much coaching the user wants delivered (server engine owns the semantics —
/// engine.py). Raw values are the wire contract for `NudgePlanRequest.level`.
///
/// `essential` is the product default: only the two habit-protecting nudges (went
/// quiet / nothing logged today), at most one a day and a few a week. `standard`
/// is the full coaching catalog (never more than two a day). `off` is silence.
enum NudgeLevel: String, CaseIterable, Sendable, Identifiable {
    case essential
    case standard
    case off

    var id: String { rawValue }

    /// Settings display name (sentence case per the Beacon button/label rule).
    var label: String {
        switch self {
        case .essential: return "Essential"
        case .standard: return "All coaching"
        case .off: return "Off"
        }
    }

    /// One-line explanation of the delivery promise this level makes.
    var detail: String {
        switch self {
        case .essential:
            return "Only the reminders that protect your habit. At most one a day, a few a week."
        case .standard:
            return "Tips on protein, water, fiber, and treats too. Never more than two a day."
        case .off:
            return "No nudges or reminders."
        }
    }
}
