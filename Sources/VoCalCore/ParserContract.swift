import Foundation

// Swift mirror of docs/PARSER_CONTRACT.md. The server is the source of truth;
// these types must decode whatever the contract emits (snake_case via VoCalJSON)
// and tolerate unknown fields so the server can add fields without breaking
// shipped clients.

public enum MealType: String, Codable, Sendable, CaseIterable {
    case breakfast, lunch, dinner, snack, unspecified
}

public enum FoodUnit: String, Codable, Sendable, CaseIterable {
    case g, oz, lb, cup, tbsp, tsp, piece, slice, scoop, ml
}

public enum FoodState: String, Codable, Sendable, CaseIterable {
    case raw, cooked, unspecified
}

public enum DetailImportance: String, Codable, Sendable, CaseIterable {
    case high, medium, low
}

public enum ResolutionSource: String, Codable, Sendable, CaseIterable {
    case dictionary, fdc, unresolved
}

public struct ParsedItem: Codable, Sendable, Equatable {
    public var name: String
    public var amount: Double?
    public var unit: FoodUnit?
    public var state: FoodState
    public var fatRatio: String?
    public var brand: String?
    public var prepMethod: String?
    /// Chosen variant key (e.g. "fat-free") once a variant check is answered.
    public var variant: String?
    public var confidence: Double

    public init(
        name: String,
        amount: Double? = nil,
        unit: FoodUnit? = nil,
        state: FoodState = .unspecified,
        fatRatio: String? = nil,
        brand: String? = nil,
        prepMethod: String? = nil,
        variant: String? = nil,
        confidence: Double
    ) {
        self.name = name
        self.amount = amount
        self.unit = unit
        self.state = state
        self.fatRatio = fatRatio
        self.brand = brand
        self.prepMethod = prepMethod
        self.variant = variant
        self.confidence = confidence
    }
}

public struct MissingDetail: Codable, Sendable, Equatable {
    public var field: String
    public var importance: DetailImportance
    public var question: String
    /// Quick-answer chips for the UI (variant keys, fat-ratio presets). Nil = free entry.
    public var options: [String]?

    public init(
        field: String,
        importance: DetailImportance,
        question: String,
        options: [String]? = nil
    ) {
        self.field = field
        self.importance = importance
        self.question = question
        self.options = options
    }
}

public struct ParsedMeal: Codable, Sendable, Equatable {
    public var mealType: MealType
    public var items: [ParsedItem]
    public var missingDetails: [MissingDetail]

    public init(mealType: MealType, items: [ParsedItem], missingDetails: [MissingDetail]) {
        self.mealType = mealType
        self.items = items
        self.missingDetails = missingDetails
    }
}

public struct NutrientProfile: Codable, Sendable, Equatable {
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double
    public var fiber: Double

    public init(kcal: Double, protein: Double, carbs: Double, fat: Double, fiber: Double) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
    }

    public static let zero = NutrientProfile(kcal: 0, protein: 0, carbs: 0, fat: 0, fiber: 0)

    public static func + (lhs: NutrientProfile, rhs: NutrientProfile) -> NutrientProfile {
        NutrientProfile(
            kcal: lhs.kcal + rhs.kcal,
            protein: lhs.protein + rhs.protein,
            carbs: lhs.carbs + rhs.carbs,
            fat: lhs.fat + rhs.fat,
            fiber: lhs.fiber + rhs.fiber
        )
    }
}

/// A parsed item joined with its deterministic resolution — the flat shape the
/// backend `ParseResultItem` emits (decoded via VoCalJSON convertFromSnakeCase).
public struct ParseResultItem: Codable, Sendable, Equatable {
    public var name: String
    public var amount: Double?
    public var unit: FoodUnit?
    public var state: FoodState
    public var fatRatio: String?
    public var brand: String?
    public var prepMethod: String?
    public var variant: String?
    public var grams: Double
    public var macros: NutrientProfile
    public var confidence: Double
    public var source: ResolutionSource
    public var matchScore: Double

    public init(
        name: String,
        amount: Double? = nil,
        unit: FoodUnit? = nil,
        state: FoodState = .unspecified,
        fatRatio: String? = nil,
        brand: String? = nil,
        prepMethod: String? = nil,
        variant: String? = nil,
        grams: Double,
        macros: NutrientProfile,
        confidence: Double,
        source: ResolutionSource,
        matchScore: Double
    ) {
        self.name = name
        self.amount = amount
        self.unit = unit
        self.state = state
        self.fatRatio = fatRatio
        self.brand = brand
        self.prepMethod = prepMethod
        self.variant = variant
        self.grams = grams
        self.macros = macros
        self.confidence = confidence
        self.source = source
        self.matchScore = matchScore
    }
}

/// Full server response for a parse: structure + numbers + one check per material
/// ingredient over threshold (decision #29).
public struct ParseResult: Codable, Sendable, Equatable {
    public var parseId: String
    public var supersedes: String?
    public var mealType: MealType
    public var items: [ParseResultItem]
    public var totals: NutrientProfile
    public var mealConfidence: Double
    public var questions: [MissingDetail]
    public var missingDetails: [MissingDetail]
    public var model: String
    public var promptVersion: String

    public init(
        parseId: String,
        supersedes: String? = nil,
        mealType: MealType,
        items: [ParseResultItem],
        totals: NutrientProfile,
        mealConfidence: Double,
        questions: [MissingDetail] = [],
        missingDetails: [MissingDetail] = [],
        model: String,
        promptVersion: String
    ) {
        self.parseId = parseId
        self.supersedes = supersedes
        self.mealType = mealType
        self.items = items
        self.totals = totals
        self.mealConfidence = mealConfidence
        self.questions = questions
        self.missingDetails = missingDetails
        self.model = model
        self.promptVersion = promptVersion
    }
}
