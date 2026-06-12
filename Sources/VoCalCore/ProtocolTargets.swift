import Foundation

/// Active protocol targets as served by the API. Numbers come from the
/// deterministic engine; `whys` is the AI-phrased explanation layer keyed by
/// target name ("kcal", "protein", ...). The model never alters numbers.
public struct ProtocolTargets: Codable, Sendable, Equatable {
    public var protocolId: String
    public var version: Int
    public var kcal: Int
    public var protein: Int
    public var carbs: Int
    public var fat: Int
    public var fiber: Int
    public var mealsPerDay: Int
    public var whys: [String: String]

    public init(
        protocolId: String,
        version: Int,
        kcal: Int,
        protein: Int,
        carbs: Int,
        fat: Int,
        fiber: Int,
        mealsPerDay: Int,
        whys: [String: String] = [:]
    ) {
        self.protocolId = protocolId
        self.version = version
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.mealsPerDay = mealsPerDay
        self.whys = whys
    }
}
