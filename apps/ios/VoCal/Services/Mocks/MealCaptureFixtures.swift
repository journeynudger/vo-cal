import Foundation
import VoCalCore

/// Canned ParseResults built from VoCalCore types so EVERY voice-log UI state is reachable
/// on the simulator with zero network. Numbers mirror the hosted prototype
/// (scratchpad/vocal-preview.html) and the parser-contract examples; they are display
/// fixtures, not the deterministic engine (the real macros come from the backend on the
/// live path). Questions carry `.options` chips per docs/PARSER_CONTRACT.md so the
/// per-ingredient check sheets render their quick-answer chips.
enum MealCaptureFixtures {
    static let model = "mock"
    static let promptVersion = "mock-v1"

    /// The lingo-tutorial gold-standard utterance — the canned beef+rice transcript the
    /// sim/UITestMode path "hears" so the enhancing/result states are reachable with no mic.
    static let defaultTranscript =
        "so I had um four ounces of 93/7 beef and like two hundred grams of cooked jasmine rice"

    static func transcript(for scenario: MockCaptureScenario) -> String {
        switch scenario {
        case .beefAndRice:
            return defaultTranscript
        case .burger:
            return "uh a burger, the beef I am not really sure, some cheddar, mayo, and a sesame bun"
        }
    }

    // MARK: - Beef + rice: fully specified, no questions.

    static func beefAndRice(mealType: MealType, parseID: String = "mock-beef-rice") -> ParseResult {
        let beef = ParseResultItem(
            name: "Ground beef 93/7",
            amount: 4, unit: .oz, state: .cooked, fatRatio: "93/7",
            grams: 113,
            macros: NutrientProfile(kcal: 170, protein: 24, carbs: 0, fat: 8, fiber: 0),
            confidence: 0.96, source: .dictionary, matchScore: 0.96
        )
        let rice = ParseResultItem(
            name: "Jasmine rice",
            amount: 200, unit: .g, state: .cooked,
            grams: 200,
            macros: NutrientProfile(kcal: 260, protein: 5, carbs: 56, fat: 1, fiber: 0.6),
            confidence: 0.98, source: .dictionary, matchScore: 0.98
        )
        return ParseResult(
            parseId: parseID,
            mealType: mealType,
            items: [beef, rice],
            totals: beef.macros + rice.macros,
            mealConfidence: 0.97,
            questions: [],
            missingDetails: [],
            model: model,
            promptVersion: promptVersion
        )
    }

    // MARK: - Burger: unknown beef fat ratio (fat_ratio question), cheddar (variant
    // question), mayo (variant question). Macros for the unresolved items are typical-value
    // priors; answering a question supersedes the item with the chosen option's macros.

    static func burger(mealType: MealType, parseID: String = "mock-burger") -> ParseResult {
        let patty = ParseResultItem(
            name: "Beef patty",
            amount: 4, unit: .oz, state: .cooked, fatRatio: nil,
            grams: 113,
            macros: NutrientProfile(kcal: 200, protein: 23, carbs: 0, fat: 11, fiber: 0),
            confidence: 0.55, source: .dictionary, matchScore: 0.7
        )
        let cheddar = ParseResultItem(
            name: "Cheddar cheese",
            amount: 1, unit: .slice, state: .unspecified,
            grams: 28,
            macros: NutrientProfile(kcal: 113, protein: 7, carbs: 1, fat: 9, fiber: 0),
            confidence: 0.58, source: .dictionary, matchScore: 0.7
        )
        let mayo = ParseResultItem(
            name: "Mayonnaise",
            amount: 1, unit: .tbsp, state: .unspecified,
            grams: 14,
            macros: NutrientProfile(kcal: 94, protein: 0, carbs: 0, fat: 10, fiber: 0),
            confidence: 0.58, source: .dictionary, matchScore: 0.7
        )
        let bun = ParseResultItem(
            name: "Sesame bun",
            amount: 1, unit: .piece, state: .unspecified,
            grams: 50,
            macros: NutrientProfile(kcal: 140, protein: 5, carbs: 26, fat: 2, fiber: 1),
            confidence: 0.90, source: .dictionary, matchScore: 0.9
        )
        let items = [patty, cheddar, mayo, bun]
        let questions = [
            MissingDetail(
                field: "items[0].fat_ratio",
                importance: .high,
                question: "Fat ratio of the beef - like 80/20 or 93/7?",
                options: ["80/20", "85/15", "90/10", "93/7"]
            ),
            MissingDetail(
                field: "items[1].variant",
                importance: .medium,
                question: "Which cheddar?",
                options: ["Whole", "Reduced-fat", "Fat-free"]
            ),
            MissingDetail(
                field: "items[2].variant",
                importance: .medium,
                question: "Regular or light mayo?",
                options: ["Regular", "Light", "Olive-oil"]
            ),
        ]
        return ParseResult(
            parseId: parseID,
            mealType: mealType,
            items: items,
            totals: items.map(\.macros).reduce(.zero, +),
            mealConfidence: 0.62,
            questions: questions,
            missingDetails: questions,
            model: model,
            promptVersion: promptVersion
        )
    }

    /// Macro answers per option, keyed by question field + option label. Mirrors the
    /// prototype's per-option deltas so answering visibly moves the totals.
    static func resolvedItem(
        field: String,
        option: String,
        base: ParseResultItem
    ) -> ParseResultItem {
        var item = base
        let highConfidence = 0.94
        switch (field, option) {
        // Beef fat ratio.
        case ("items[0].fat_ratio", "80/20"):
            item.fatRatio = "80/20"
            item.macros = NutrientProfile(kcal: 290, protein: 20, carbs: 0, fat: 23, fiber: 0)
        case ("items[0].fat_ratio", "85/15"):
            item.fatRatio = "85/15"
            item.macros = NutrientProfile(kcal: 250, protein: 21, carbs: 0, fat: 18, fiber: 0)
        case ("items[0].fat_ratio", "90/10"):
            item.fatRatio = "90/10"
            item.macros = NutrientProfile(kcal: 200, protein: 23, carbs: 0, fat: 11, fiber: 0)
        case ("items[0].fat_ratio", "93/7"):
            item.fatRatio = "93/7"
            item.macros = NutrientProfile(kcal: 170, protein: 24, carbs: 0, fat: 8, fiber: 0)
        // Cheddar variant.
        case ("items[1].variant", "Whole"):
            item.variant = "whole"
            item.macros = NutrientProfile(kcal: 113, protein: 7, carbs: 1, fat: 9, fiber: 0)
        case ("items[1].variant", "Reduced-fat"):
            item.variant = "reduced-fat"
            item.macros = NutrientProfile(kcal: 70, protein: 8, carbs: 1, fat: 4, fiber: 0)
        case ("items[1].variant", "Fat-free"):
            item.variant = "fat-free"
            item.macros = NutrientProfile(kcal: 40, protein: 9, carbs: 2, fat: 0, fiber: 0)
        // Mayo variant.
        case ("items[2].variant", "Regular"):
            item.variant = "regular"
            item.macros = NutrientProfile(kcal: 94, protein: 0, carbs: 0, fat: 10, fiber: 0)
        case ("items[2].variant", "Light"):
            item.variant = "light"
            item.macros = NutrientProfile(kcal: 36, protein: 0, carbs: 1, fat: 3.5, fiber: 0)
        case ("items[2].variant", "Olive-oil"):
            item.variant = "olive-oil"
            item.macros = NutrientProfile(kcal: 50, protein: 0, carbs: 0, fat: 5, fiber: 0)
        default:
            break
        }
        item.confidence = highConfidence
        return item
    }
}
