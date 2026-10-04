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
    /// "nudge" or "invitation" (decision 62). An invitation carries what it offers and the key
    /// a "Don't offer this again" declines with (`PUT /tracking` decline_offer).
    var kind: String = "nudge"
    var offerMode: String? = nil
    var offerFocus: String? = nil
    var declineKey: String? = nil

    var isInvitation: Bool { kind == "invitation" }
}

// Tolerant decode for the invitation keys (a server before them sends none); in an extension
// so the memberwise initializer survives for the mock card and the previews.
extension NudgeCard {
    private enum CodingKeys: String, CodingKey {
        case id, category, message, proTip, priority, cooldownDays
        case kind, offerMode, offerFocus, declineKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(String.self, forKey: .category)
        message = try container.decode(String.self, forKey: .message)
        proTip = try container.decode(String.self, forKey: .proTip)
        priority = try container.decode(Int.self, forKey: .priority)
        cooldownDays = try container.decode(Int.self, forKey: .cooldownDays)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "nudge"
        offerMode = try container.decodeIfPresent(String.self, forKey: .offerMode)
        offerFocus = try container.decodeIfPresent(String.self, forKey: .offerFocus)
        declineKey = try container.decodeIfPresent(String.self, forKey: .declineKey)
    }
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
enum NudgeLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case essential
    case standard
    case off

    var id: String { rawValue }

    /// The person's own sentence for the level (decision 66, spec S3): asked in the intake,
    /// repeated in Settings, so the two never speak two vocabularies for one thing. The
    /// engine's words ("essential", "standard") stay on the wire and off every screen.
    var label: String {
        switch self {
        case .essential: return "Only when I'm slipping"
        case .standard: return "Coach me along the way"
        case .off: return "Nothing. I'll check in myself."
        }
    }

    /// The short form for a Settings row's trailing value.
    var shortLabel: String {
        switch self {
        case .essential: return "Only when slipping"
        case .standard: return "Coach me"
        case .off: return "Nothing"
        }
    }

    /// The delivery promise the engine enforces for this level (nudges/engine.py): the one
    /// place the engine's words are owed to the person, verbatim.
    var detail: String {
        switch self {
        case .essential:
            return "A reminder when a day goes quiet. Nothing else."
        case .standard:
            return "Tips on protein, water, treats and the week. Never more than two a day."
        case .off:
            return "No reminders, no tips. Your weekly check-in still shows when it is due."
        }
    }
}
