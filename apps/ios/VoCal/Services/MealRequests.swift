import Foundation
import VoCalCore

// Swift mirrors of the meals/parse request+response bodies (services/api meals/schemas.py
// + parser/schemas.py). Field names map to snake_case via VoCalJSON; nullability and enums
// follow docs/PARSER_CONTRACT.md. Clients tolerate unknown server-added fields by ignoring
// them (these decode only the keys they declare).

/// The user's confirmed item at log time — the parsed item after edits/answers.
///
/// `variant` must round-trip from the parse result so the server re-resolves the chosen
/// variant (e.g. fat-free cheddar) instead of regressing to the family default (RT-02).
/// `grams`/`macros` are advisory: the server recomputes per-item macros from the item's
/// identity at confirm and never trusts client math (AGENTS.md #6). They're still sent so
/// the server can diff confirmed-vs-parsed into append-only corrections.
struct ConfirmedItem: Codable, Sendable, Equatable {
    var name: String
    var amount: Double?
    var unit: FoodUnit?
    var state: FoodState
    var fatRatio: String?
    var variant: String?
    var brand: String?
    var prepMethod: String?
    var grams: Double
    var macros: NutrientProfile
    var confidence: Double

    init(
        name: String,
        amount: Double? = nil,
        unit: FoodUnit? = nil,
        state: FoodState = .unspecified,
        fatRatio: String? = nil,
        variant: String? = nil,
        brand: String? = nil,
        prepMethod: String? = nil,
        grams: Double,
        macros: NutrientProfile,
        confidence: Double
    ) {
        self.name = name
        self.amount = amount
        self.unit = unit
        self.state = state
        self.fatRatio = fatRatio
        self.variant = variant
        self.brand = brand
        self.prepMethod = prepMethod
        self.grams = grams
        self.macros = macros
        self.confidence = confidence
    }

    /// Project a resolved parse item into a confirmed item (pre-edit identity copy).
    init(from item: ParseResultItem) {
        self.init(
            name: item.name,
            amount: item.amount,
            unit: item.unit,
            state: item.state,
            fatRatio: item.fatRatio,
            variant: item.variant,
            brand: item.brand,
            prepMethod: item.prepMethod,
            grams: item.grams,
            macros: item.macros,
            confidence: item.confidence
        )
    }
}

/// `POST /meals` body. `clientMealID` makes the confirm idempotent across offline retries
/// (the server returns the already-committed row on replay).
struct LogMealRequest: Codable, Sendable, Equatable {
    var clientMealID: String
    var parseID: String?
    var name: String?
    var mealType: MealType
    var items: [ConfirmedItem]
    var saveAsUsual: Bool

    init(
        clientMealID: String = UUID().uuidString.lowercased(),
        parseID: String?,
        name: String?,
        mealType: MealType,
        items: [ConfirmedItem],
        saveAsUsual: Bool = false
    ) {
        self.clientMealID = clientMealID
        self.parseID = parseID
        self.name = name
        self.mealType = mealType
        self.items = items
        self.saveAsUsual = saveAsUsual
    }
}

/// `POST /meals` response — the durable meal_log row. Its existence is the only proof that
/// licenses the "Logged" claim (AGENTS.md MUST-NOT #6 / VOICE_CAPTURE derived `logged` rung).
struct MealLogConfirmation: Codable, Sendable, Equatable {
    var id: String
    var name: String?
    var mealType: MealType
    var totals: NutrientProfile
    var confidence: Double
    var correctionsCount: Int
}

/// `GET /meals/today` response (subset the loop needs). Carries unknown server fields
/// implicitly by decoding only what is declared.
struct TodayResult: Codable, Sendable, Equatable {
    var date: String
    var avgConfidence: Double
}
