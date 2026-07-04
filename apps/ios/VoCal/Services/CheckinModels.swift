import Foundation
import VoCalCore

// Swift mirrors of the checkin domain (services/api checkin/schemas.py + recommend.py).

/// The user's self-reported check-in inputs (`POST /checkins`).
struct CheckinInputs: Codable, Sendable, Equatable {
    var weightKg: Double?
    var hunger: Int?          // 1-5
    var energy: Int?          // 1-5
    var adherenceSelf: Int?   // 1 (none) - 5 (perfect)
    var notes: String?
}

/// What the system already knows for the week (shown read-only so the form only asks what it
/// can't compute). Server attaches this; the mock supplies a representative week.
/// The certainty fields (GET /meals/summary) power the capture-quality half of the check-in:
/// consistency AND estimate sharpness, plus the single most-impactful focus tip.
struct CheckinComputed: Sendable, Equatable {
    var loggedDays: Int
    var weekDays: Int
    var avgKcal: Int
    var mealsLogged: Int = 0
    var avgCertainty: Int?
    var focusTip: String?
}

/// `GET /meals/summary` — the weekly capture-quality aggregation (certainty layer).
struct WeeklySummaryDTO: Decodable, Sendable {
    let mealsLogged: Int
    let daysLogged: Int
    let avgKcal: Int?
    let avgCertainty: Int?
    let mostCommonMissingDetail: String?
    let focusTip: String?
    let sufficientData: Bool
}

/// Recommendation kinds mirror recommend.py's RecommendationKind.
enum RecommendationKind: String, Sendable {
    case hold
    case recalibrateIbw = "recalibrate_ibw"
    case reduceAllocation = "reduce_allocation"
    case diagnostics
}

/// The engine's recommendation for the week. `newTargets` is present only when an adjustment is
/// proposed (accepting it creates protocol v(n+1)); nil for hold/diagnostics.
struct CheckinRecommendation: Sendable, Equatable {
    var kind: RecommendationKind
    var headline: String
    var why: String
    var newTargets: ProtocolTargets?
    /// The protocol this recommendation pertains to — accepting it revises this protocol.
    var protocolId: String?
}

// Wire response subsets (decode only what the client needs).

/// `GET /checkins/due`.
struct CheckinDueResponse: Decodable, Sendable {
    let due: Bool
}

/// `POST /checkins` (the stored row id is all the client needs back).
struct CheckinSubmitResponse: Decodable, Sendable {
    let id: String
}

/// `POST /checkin/recommend` — the structured recalibration recommendation.
struct RecommendationResponseDTO: Decodable, Sendable {
    let protocolId: String
    let kind: String
    let headline: String
    let rationale: String
    let targets: RecalTargetsDTO?
}

struct RecalTargetsDTO: Decodable, Sendable {
    let targetKcal: Int
    let proteinG: Int
    let waterOz: Int
    let fiberG: Int
}
