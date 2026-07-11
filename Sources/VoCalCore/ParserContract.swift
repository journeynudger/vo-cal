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
    case dictionary, fdc, estimated, manual, unresolved
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

/// A web source a nutrition estimate was grounded in (search-grounded estimation).
public struct FoodSource: Codable, Sendable, Equatable {
    public let url: String
    public let title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case url, title
    }

    // Tolerant decode: `title` may be dropped from a future payload — default to "" rather
    // than throwing (PARSER_CONTRACT: tolerate server field drift, the is_estimate lesson).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
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
    /// AI best-guess (food not in the dictionary/FDC): the UI flags it and invites a correction.
    public var isEstimate: Bool = false
    /// Web sources the estimate was grounded in. Optional: absent from old servers — never required.
    public var sources: [FoodSource]?

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
        matchScore: Double,
        isEstimate: Bool = false,
        sources: [FoodSource]? = nil
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
        self.isEstimate = isEstimate
        self.sources = sources
    }

    // Custom decode so an ABSENT `is_estimate` defaults to false instead of throwing.
    // Synthesized Decodable ignores the `= false` default and requires the key; the live
    // /parse response omits it (it lives only on the meals/confirm path), so every parse
    // threw keyNotFound → "Couldn't analyze the meal." A shipped client must tolerate the
    // server not sending an optional flag (PARSER_CONTRACT: tolerate field drift). Encodable
    // stays synthesized, so round-trips are unaffected.
    enum CodingKeys: String, CodingKey {
        case name, amount, unit, state, fatRatio, brand, prepMethod, variant
        case grams, macros, confidence, source, matchScore, isEstimate, sources
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        unit = try c.decodeIfPresent(FoodUnit.self, forKey: .unit)
        state = try c.decode(FoodState.self, forKey: .state)
        fatRatio = try c.decodeIfPresent(String.self, forKey: .fatRatio)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        prepMethod = try c.decodeIfPresent(String.self, forKey: .prepMethod)
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
        grams = try c.decode(Double.self, forKey: .grams)
        macros = try c.decode(NutrientProfile.self, forKey: .macros)
        confidence = try c.decode(Double.self, forKey: .confidence)
        source = try c.decode(ResolutionSource.self, forKey: .source)
        matchScore = try c.decode(Double.self, forKey: .matchScore)
        isEstimate = try c.decodeIfPresent(Bool.self, forKey: .isEstimate) ?? false
        sources = (try? c.decodeIfPresent([FoodSource].self, forKey: .sources)) ?? nil
    }
}

/// The confidence-aware logging layer (server certainty.py): an honest 0-100 score,
/// calm label, missing-detail flags, assumptions, and coaching tips. The whole block is
/// OPTIONAL (old servers/old stored parses omit it — the is_estimate lesson: an absent
/// additive block must never fail decode) and its inner lists decode leniently.
public struct MealCertainty: Codable, Sendable, Equatable {
    public var score: Int
    public var label: String
    public var displayLabel: String
    public var category: String
    public var missingDetails: [String]
    public var assumptions: [String]
    public var tips: [String]
    public var shouldShowCoaching: Bool

    public init(
        score: Int,
        label: String,
        displayLabel: String,
        category: String,
        missingDetails: [String] = [],
        assumptions: [String] = [],
        tips: [String] = [],
        shouldShowCoaching: Bool = false
    ) {
        self.score = score
        self.label = label
        self.displayLabel = displayLabel
        self.category = category
        self.missingDetails = missingDetails
        self.assumptions = assumptions
        self.tips = tips
        self.shouldShowCoaching = shouldShowCoaching
    }

    enum CodingKeys: String, CodingKey {
        case score, label, displayLabel, category, missingDetails, assumptions, tips
        case shouldShowCoaching
    }

    // Lenient decode: lists/flags fall back rather than throwing if the server ever
    // trims a field (tolerate server drift — PARSER_CONTRACT rule).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = try c.decode(Int.self, forKey: .score)
        label = try c.decode(String.self, forKey: .label)
        displayLabel = try c.decodeIfPresent(String.self, forKey: .displayLabel) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "unknown"
        missingDetails = try c.decodeIfPresent([String].self, forKey: .missingDetails) ?? []
        assumptions = try c.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        tips = try c.decodeIfPresent([String].self, forKey: .tips) ?? []
        shouldShowCoaching = try c.decodeIfPresent(Bool.self, forKey: .shouldShowCoaching) ?? false
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
    /// Optional: absent from old servers and old stored parses — never required.
    public var certainty: MealCertainty?

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
        promptVersion: String,
        certainty: MealCertainty? = nil
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
        self.certainty = certainty
    }
}
