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
    /// The titration eased a too-fast loss (decision 64): calories go up one step.
    case easeDeficit = "ease_deficit"
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

/// `GET /checkin/checkins` — one stored check-in (newest first). Backs the
/// Progress page's weight trend; weight arrives in kg (the stored unit) and the
/// UI converts for display (the app speaks pounds).
struct CheckinRowDTO: Decodable, Sendable, Identifiable {
    let id: String
    let weightKg: Double?
    let createdAt: Date
    /// The person's own words that week (decision 69, the mirror); absent from older rows.
    let notes: String?
}

/// The person's own words from an earlier check-in, returned verbatim at the next one (decision
/// 69, spec B5): nothing summarized, nothing scored, their sentence under "You wrote last week".
struct CheckinNote: Sendable, Equatable {
    var text: String
    var writtenAt: Date
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
    /// The whole recomputed protocol (decision 64), when the server sent one and this build can
    /// read it: nil for hold and diagnostics, for an older server, and for a shape this build
    /// does not know (the four numbers in `targets` still carry the preview then).
    let proposedProtocol: GenerateProtocolResponse.APITargets?

    private enum CodingKeys: String, CodingKey {
        case protocolId, kind, headline, rationale, targets
        case proposedProtocol = "protocol"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolId = try container.decode(String.self, forKey: .protocolId)
        kind = try container.decode(String.self, forKey: .kind)
        headline = try container.decode(String.self, forKey: .headline)
        rationale = try container.decode(String.self, forKey: .rationale)
        targets = try container.decodeIfPresent(RecalTargetsDTO.self, forKey: .targets)
        proposedProtocol = (try? container.decodeIfPresent(GenerateProtocolResponse.APITargets.self, forKey: .proposedProtocol)) ?? nil
    }
}

struct RecalTargetsDTO: Decodable, Sendable {
    let targetKcal: Int
    let proteinG: Int
    let waterOz: Int
    let fiberG: Int
}
