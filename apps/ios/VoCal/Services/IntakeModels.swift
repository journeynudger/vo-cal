import Foundation

// Swift mirror of the protocols intake contract (services/api protocols/schemas.py).
// Activity is inferred, never asked (decision #36): the engine derives it from
// occupation + training + obligations, so there is no activity field here.

/// The deep intake the protocol engine consumes. Enum-valued fields are raw strings that
/// match the API enums exactly; VoCalJSON maps camelCase → snake_case on the wire.
struct IntakeProfile: Codable, Sendable, Equatable {
    var age: Int
    var sex: String          // "male" | "female"
    var heightIn: Double
    var weightLb: Double
    var goal: String         // "cut" | "maintain" | "gain"
    var work: String         // "desk" | "on_feet" | "manual"
    var train: String        // "none" | "light" | "moderate" | "heavy"
    var kids: Bool
    var med: String          // "none" | "hunger_increasing" | "hunger_suppressing"
    var stress: String       // "low" | "moderate" | "high"
    var mealsPerDay: Int?
}

/// Mutable UI state the intake flow edits, with persona defaults so every "Continue" is
/// valid even before the user changes anything (the screens are pre-answered, prototype
/// style). `profile` projects it into the wire model when the flow finishes.
struct IntakeDraft: Equatable {
    var age = 34
    var sex = "female"
    var heightIn = 66.0       // 5'6"
    var weightLb = 172.0
    var goal = "cut"
    var work = "on_feet"
    var kids = false        // most users don't have young kids — require an explicit "Yes"
    var train = "moderate"
    var med = "none"
    var stress = "high"
    var mealsPerDay = 4

    var profile: IntakeProfile {
        IntakeProfile(
            age: age, sex: sex, heightIn: heightIn, weightLb: weightLb,
            goal: goal, work: work, train: train, kids: kids,
            med: med, stress: stress, mealsPerDay: mealsPerDay
        )
    }
}

/// `POST /protocols/generate` response mirror. The engine's targets nest here; the iOS
/// `VoCalCore.ProtocolTargets` is assembled from this + the top-level `protocolId`.
struct GenerateProtocolResponse: Decodable, Sendable {
    let protocolId: String
    let version: Int
    let active: Bool
    let targets: APITargets

    struct APITargets: Decodable, Sendable {
        let version: Int
        let kcal: Int
        let protein: Int
        // Protein optimal band (bounded goal). Optional so a protocol stored before the band
        // existed still decodes (missing → nil → treated as "no band" downstream).
        let proteinMin: Int?
        let proteinMax: Int?
        let carbs: Int
        let fat: Int
        let fiber: Int
        let waterOz: Int
        let produceServings: Int
        let mealsPerDay: Int
        let whys: [String: String]
    }
}
