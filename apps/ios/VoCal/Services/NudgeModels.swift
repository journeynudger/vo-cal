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
/// last shown). Advisory — a stale ledger repeats a nudge, never harms.
struct NudgePlanRequest: Codable, Sendable, Equatable {
    var recentlyShown: [String: String]
}
