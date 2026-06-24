import Foundation

/// Active protocol targets as served by the API. Numbers come from the
/// deterministic engine; `whys` is the AI-phrased explanation layer keyed by
/// target name ("kcal", "protein", ...). The model never alters numbers.
public struct ProtocolTargets: Codable, Sendable, Equatable {
    public var protocolId: String
    public var version: Int
    public var kcal: Int
    public var protein: Int
    /// Protein optimal band (bounded goal, centered on `protein`): the green range on the
    /// dashboard. Default 0 (= "no band") for back-compat with protocols built before it.
    public var proteinMin: Int
    public var proteinMax: Int
    public var carbs: Int
    public var fat: Int
    public var fiber: Int
    /// Home-dashboard micros (decision #28): produce servings + water (oz).
    public var produceServings: Int
    public var waterOz: Int
    public var mealsPerDay: Int
    public var whys: [String: String]

    public init(
        protocolId: String,
        version: Int,
        kcal: Int,
        protein: Int,
        proteinMin: Int = 0,
        proteinMax: Int = 0,
        carbs: Int,
        fat: Int,
        fiber: Int,
        produceServings: Int,
        waterOz: Int,
        mealsPerDay: Int,
        whys: [String: String] = [:]
    ) {
        self.protocolId = protocolId
        self.version = version
        self.kcal = kcal
        self.protein = protein
        self.proteinMin = proteinMin
        self.proteinMax = proteinMax
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.produceServings = produceServings
        self.waterOz = waterOz
        self.mealsPerDay = mealsPerDay
        self.whys = whys
    }
}
