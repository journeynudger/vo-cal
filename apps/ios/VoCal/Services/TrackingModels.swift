import Foundation
import VoCalCore

// Swift mirror of the tracking contract (services/api tracking/schemas.py). Field names map to
// snake_case via VoCalJSON. Every server-added field decodes tolerantly (apps/ios/AGENTS.md
// decode rule), and a value this build does not know is dropped, never a failed load.

/// How the person follows their nutrition (decision 57): one typed value, chosen first in the
/// intake and changed from Settings → How I track, that decides what every surface prints. The
/// titles are the person's own sentences, never a brand or a coach's rung (decision 58).
enum TrackingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case habits
    case calories
    case five
    case macros
    case mealPlan = "meal_plan"

    var id: String { rawValue }

    /// The modes the app can show today. The meal plan waits on its builder (plan P8): an
    /// option that does nothing is clutter, so it is absent, not disabled (spec 6.9).
    static let offered: [TrackingMode] = [.habits, .calories, .five, .macros]

    /// The option's title: what the person would say.
    var title: String {
        switch self {
        case .habits: "Build better habits"
        case .calories: "Watch my calories"
        case .five: "Calories, protein, produce, fiber, water"
        case .macros: "Track my macros"
        case .mealPlan: "Follow a meal plan"
        }
    }

    /// One line under the title. The titles alone do not tell a stranger that the five has five
    /// parts or that habits has no numbers (spec 6.2, the order pass), so the line stays.
    var support: String {
        switch self {
        case .habits: "Log each day, drink your water, eat your vegetables. No numbers."
        case .calories: "One number a day, and what is left of it."
        case .five: "The five things the method tracks."
        case .macros: "Calories, protein, carbs and fat."
        case .mealPlan: "Meals you plan, checked off as you log them."
        }
    }

    /// The short name Settings shows beside "How I track".
    var shortLabel: String {
        switch self {
        case .habits: "Habits"
        case .calories: "Calories"
        case .five: "The five"
        case .macros: "Macros"
        case .mealPlan: "Meal plan"
        }
    }

    /// False only in habits mode: no calories on cards, rows, chips, the result or the week (the
    /// Rams review, R8). A loaded day carries the server's own answer
    /// (`TodayDashboard.printsNumbers`); this is for the surfaces that run before one loads.
    var printsNumbers: Bool { self != .habits }
}

/// A tile the person adds beyond the mode's own (decision 30, realized). Sugar and sodium exist
/// only where the nutrient model carries them; a tile with nothing known says so, never 0.
enum FocusMetric: String, Codable, Sendable, CaseIterable, Identifiable {
    case protein, fiber, water, produce, carbs, fat, sugar, sodium

    var id: String { rawValue }

    var label: String {
        switch self {
        case .protein: "Protein"
        case .fiber: "Fiber"
        case .water: "Water"
        case .produce: "Produce"
        case .carbs: "Carbs"
        case .fat: "Fat"
        case .sugar: "Sugar"
        case .sodium: "Sodium"
        }
    }
}

/// `GET /tracking` and the `PUT /tracking` echo: the latest version, or the default for an
/// account that never chose (version 0, source "default").
struct TrackingPreference: Decodable, Sendable, Equatable {
    var mode: TrackingMode
    var focusMetrics: [FocusMetric]
    /// Offer keys the person asked never to see again: a mode ("calories") or a focus
    /// ("focus:protein"). Choosing one by hand clears it server-side.
    var declinedOffers: [String]
    /// What Settings → How I track may offer under "Also show": the metrics the mode does not
    /// already print, in the server's order. Empty from a server that predates the list.
    var offerableFocus: [FocusMetric]
    var source: String
    var version: Int

    /// What every account is before it chooses: the five, nothing added.
    static let unchosen = TrackingPreference(
        mode: .five,
        focusMetrics: [],
        declinedOffers: [],
        offerableFocus: PanelComposer.offerableFocus(for: .five),
        source: "default",
        version: 0
    )
}

// Tolerant decode, in an extension so the memberwise initializer survives for the mock. A mode
// or metric from a later server reads as the five (the dashboard every build can draw) or is
// dropped from the list; a missing key takes the default. The encode side is a separate type.
extension TrackingPreference {
    private enum CodingKeys: String, CodingKey {
        case mode, focusMetrics, declinedOffers, offerableFocus, source, version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMode = try container.decodeIfPresent(String.self, forKey: .mode) ?? TrackingMode.five.rawValue
        mode = TrackingMode(rawValue: rawMode) ?? .five
        focusMetrics = (try container.decodeIfPresent([String].self, forKey: .focusMetrics) ?? [])
            .compactMap(FocusMetric.init(rawValue:))
        declinedOffers = try container.decodeIfPresent([String].self, forKey: .declinedOffers) ?? []
        offerableFocus = (try container.decodeIfPresent([String].self, forKey: .offerableFocus) ?? [])
            .compactMap(FocusMetric.init(rawValue:))
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "default"
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }
}

/// `PUT /tracking`: append the next version. Fields left nil keep the latest value server-side,
/// so one thing changes at a time. `declineOffer` records a "Don't offer this again" (durable,
/// never a timer; reversible from Settings → How I track).
struct TrackingUpdate: Encodable, Sendable, Equatable {
    var mode: TrackingMode? = nil
    var focusMetrics: [FocusMetric]? = nil
    var declineOffer: String? = nil
    var source: PreferenceSource = .chosen

    /// Who moved the preference: the person by hand, the person saying yes to an invitation, or
    /// the person declining one.
    enum PreferenceSource: String, Encodable, Sendable {
        case chosen, invited, declined
    }
}

extension ParseResult {
    /// Whether this result's screen prints calories and macros: the server stamps the person's
    /// mode on every parse (`mode`, additive); a result from a server that predates modes, or a
    /// mode this build does not know, prints them.
    var printsNumbers: Bool {
        guard let mode, let known = TrackingMode(rawValue: mode) else { return true }
        return known.printsNumbers
    }
}
