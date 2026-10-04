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
    /// Where the user wants to land, in pounds (the onboarding ruler). Optional:
    /// persisted with the intake for coaching context; the protocol engine does
    /// not consume it (targets stay derived from current stats + goal).
    var desiredWeightLb: Double?
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
/// EXCEPTION — sex has NO default: it flips the engine's IBW base + calorie floor, and a
/// silent pre-selected "female" sent male users' calories way low when they tapped through
/// (field bug 2026-07, the 1690-kcal complaint). Step 0's Continue is gated until chosen.
struct IntakeDraft: Equatable {
    var age = 34
    var sex = ""
    var heightIn = 66.0       // 5'6"
    var weightLb = 172.0
    /// Ruler default = current weight; the step nudges it from there. Kept in
    /// sync when the user hasn't touched the ruler and edits their weight.
    var desiredWeightLb = 172.0
    var desiredWeightTouched = false
    var goal = "cut"
    var work = "on_feet"
    var kids = false        // most users don't have young kids — require an explicit "Yes"
    var train = "moderate"
    var med = "none"
    var stress = "high"
    var mealsPerDay = 4
    /// How the person wants to follow their nutrition: the first question, nothing preselected
    /// (decision 57). Nil until chosen; the step's Continue is gated on it. It travels to the
    /// server on `PUT /tracking` and with the generate call, not inside the profile.
    var mode: TrackingMode?
    /// How much the app should say (decision 66): the second question, nothing preselected;
    /// the step's Continue is gated on it. Travels on `PUT /tracking` with the mode.
    var nudgeLevel: NudgeLevel?
    /// What makes tracking hard: any or none (continuing with none ticked is the answer).
    var frictions: [Friction] = []
    /// When the person will log (decision 69): a moment that already happens, nothing
    /// preselected; the step's Continue is gated on it. Travels on `PUT /tracking` too.
    var logAnchor: LogAnchor?

    /// The answers as the engine takes them. Habits mode never asks the goal, the appetite
    /// medication or a desired weight (spec 6.3), so the profile carries the no-prescription
    /// answers for those rather than the persona defaults the screens would have shown: a
    /// person who asked for no numbers must not be handed a deficit they never chose.
    var profile: IntakeProfile {
        let prescribes = mode != .habits
        return IntakeProfile(
            age: age, sex: sex, heightIn: heightIn, weightLb: weightLb,
            desiredWeightLb: prescribes ? desiredWeightLb : weightLb,
            goal: prescribes ? goal : "maintain", work: work, train: train, kids: kids,
            med: prescribes ? med : "none", stress: stress, mealsPerDay: mealsPerDay
        )
    }
}

/// `GET /intake/latest` response mirror (intake/schemas.py IntakeRecord): the newest
/// persisted intake version. Written by onboarding AND the Settings Profile editor
/// (which replays the onboarding path: POST /intake then /protocols/generate).
struct IntakeRecordDTO: Decodable, Sendable {
    let intakeId: String
    let version: Int
    let intake: IntakeProfile
}

/// `POST /protocols/generate` response mirror. The engine's targets nest here; the iOS
/// `VoCalCore.ProtocolTargets` is assembled from this + the top-level `protocolId`.
struct GenerateProtocolResponse: Decodable, Sendable {
    let protocolId: String
    let version: Int
    let active: Bool
    let targets: APITargets
    /// When this protocol was built, and whether the server's seasonal threshold says
    /// it's time to rebuild (protocols/staleness.py owns the 90 days — never re-derived
    /// here). Optional so responses from a server without the fields still decode.
    let createdAt: Date?
    let needsRecalibration: Bool?
    /// The target keys the person's mode reveals, in order (decision 59; server
    /// tracking/projection.py). Optional: a server that predates modes omits it.
    let reveal: [String]?

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
