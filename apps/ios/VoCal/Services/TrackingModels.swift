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

    /// The modes the app can show, in the chooser's order: least to most asked of the person
    /// (spec 6.2). The meal plan joined once its builder shipped (plan P8); until then the
    /// option was absent, not disabled, because an option that does nothing is clutter (6.9).
    static let offered: [TrackingMode] = [.habits, .calories, .five, .macros, .mealPlan]

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

/// What makes tracking hard for the person (decision 66): any number of these, or none. Each
/// moves exactly one thing (the spec's 6.4), and none is ever named back as a kind of person.
enum Friction: String, Codable, Sendable, CaseIterable, Identifiable {
    case forgetting
    case portions
    case eatingOut = "eating_out"
    case time

    var id: String { rawValue }

    /// The option's title: what the person would say.
    var title: String {
        switch self {
        case .forgetting: "I forget"
        case .portions: "Portions and amounts"
        case .eatingOut: "Eating out"
        case .time: "It takes too long"
        }
    }

    /// The one thing the app does about it, so the person knows what the tap buys.
    var support: String {
        switch self {
        case .forgetting: "A reminder in the evening when a meal is still unlogged."
        case .portions: "A question about an amount you left vague, more often."
        case .eatingOut: "The photo path, right on the bar."
        case .time: "Each meal offered as a usual, until you have a few."
        }
    }
}

/// When the person said they will log (decision 69, spec B2): a moment that already happens,
/// so the cue does the remembering (Gollwitzer). The two consistency check-ins follow it
/// server-side (tracking/projection.py `check_slots_for`), the late-morning one names it back,
/// and the Action button card says the same sentence. `own` is an answer that moves nothing.
enum LogAnchor: String, Codable, Sendable, CaseIterable, Identifiable {
    case afterEating = "after_eating"
    case whenSeated = "when_seated"
    case beforeBed = "before_bed"
    case own

    var id: String { rawValue }

    /// The option's title: what the person would say.
    var title: String {
        switch self {
        case .afterEating: "Right after I eat"
        case .whenSeated: "When I sit back down"
        case .beforeBed: "All at once, before bed"
        case .own: "I'll find my own moment"
        }
    }

    /// What the moment is, and what it moves, so the person knows what the tap buys.
    var support: String {
        switch self {
        case .afterEating: "The fork goes down, the phone comes up. Ten seconds."
        case .whenSeated: "Back at the desk, or the couch, say what you had."
        case .beforeBed: "The whole day in one sentence. No check-in before the evening."
        case .own: "Nothing moves. The check-ins stay where they are."
        }
    }

    /// The Action button card's second sentence, in the plan's own words.
    var buttonSentence: String {
        switch self {
        case .afterEating: "Hold it when you put the fork down."
        case .whenSeated: "Hold it when you're back at your desk."
        case .beforeBed: "Hold it before you turn in. Say the whole day."
        case .own: "One press and it is listening."
        }
    }
}

/// When the two consistency check-ins fire for this person, local "HH:MM"; `lateMorning` is nil
/// when the anchor has none (the before-bed logger). The server's (`check_slots`), or the twin.
struct CheckSlots: Decodable, Sendable, Equatable {
    var lateMorning: String? = "11:30"
    var evening = "20:00"

    /// Line for line with tracking/projection.py `check_slots_for`.
    static func composed(for anchor: LogAnchor?) -> CheckSlots {
        switch anchor {
        case .whenSeated: CheckSlots(lateMorning: "12:30", evening: "20:00")
        case .beforeBed: CheckSlots(lateMorning: nil, evening: "20:30")
        default: CheckSlots()
        }
    }
}

extension CheckSlots {
    private enum CodingKeys: String, CodingKey {
        case lateMorning, evening
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lateMorning = try container.decodeIfPresent(String.self, forKey: .lateMorning)
        evening = try container.decodeIfPresent(String.self, forKey: .evening) ?? "20:00"
    }
}

/// What the level, the frictions and the anchor change, said once by the server
/// (tracking/projection.py `experience_for`) so the phone arranges and never decides. Absent
/// from a server that predates it; the mock composes its twin.
struct Experience: Decodable, Sendable, Equatable {
    var nudgeLevel: NudgeLevel?
    var offersInvitations = true
    var eveningReminder = false
    var amountChecks = "standard"
    var barHint = "default"
    var seedUsuals = false
    var checkSlots = CheckSlots()

    /// The bar names the photo path ("Eating out").
    var showsPhotoHint: Bool { barHint == "photo" }

    /// The server's rule, for the sim (MockTrackingService) and a server one deploy behind:
    /// line for line with `experience_for`. The before-bed logger's evening check exists whether
    /// or not they said they forget (decision 69).
    static func composed(level: NudgeLevel?, frictions: [Friction], anchor: LogAnchor? = nil) -> Experience {
        Experience(
            nudgeLevel: level,
            offersInvitations: level == nil || level == .standard,
            eveningReminder: frictions.contains(.forgetting) || anchor == .beforeBed,
            amountChecks: frictions.contains(.portions) ? "eager" : "standard",
            barHint: frictions.contains(.eatingOut) ? "photo" : "default",
            seedUsuals: frictions.contains(.time),
            checkSlots: CheckSlots.composed(for: anchor)
        )
    }
}

extension Experience {
    private enum CodingKeys: String, CodingKey {
        case nudgeLevel, offersInvitations, eveningReminder, amountChecks, barHint, seedUsuals, checkSlots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nudgeLevel = (try container.decodeIfPresent(String.self, forKey: .nudgeLevel)).flatMap(NudgeLevel.init(rawValue:))
        offersInvitations = try container.decodeIfPresent(Bool.self, forKey: .offersInvitations) ?? true
        eveningReminder = try container.decodeIfPresent(Bool.self, forKey: .eveningReminder) ?? false
        amountChecks = try container.decodeIfPresent(String.self, forKey: .amountChecks) ?? "standard"
        barHint = try container.decodeIfPresent(String.self, forKey: .barHint) ?? "default"
        seedUsuals = try container.decodeIfPresent(Bool.self, forKey: .seedUsuals) ?? false
        checkSlots = (try? container.decodeIfPresent(CheckSlots.self, forKey: .checkSlots)) ?? CheckSlots()
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
    /// How much the app says (decision 66); nil when never asked, and the phone's own level
    /// stands. What gets in the way, any or none. And what the two change, from the server.
    var nudgeLevel: NudgeLevel? = nil
    var frictions: [Friction] = []
    var experience: Experience? = nil
    /// When the person said they will log (decision 69); nil when never asked.
    var logAnchor: LogAnchor? = nil

    /// The experience to obey: the server's, or its twin composed from the fields for a server
    /// that predates it.
    var effectiveExperience: Experience {
        experience ?? Experience.composed(level: nudgeLevel, frictions: frictions, anchor: logAnchor)
    }

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
        case nudgeLevel, frictions, experience, logAnchor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logAnchor = (try container.decodeIfPresent(String.self, forKey: .logAnchor)).flatMap(LogAnchor.init(rawValue:))
        nudgeLevel = (try container.decodeIfPresent(String.self, forKey: .nudgeLevel)).flatMap(NudgeLevel.init(rawValue:))
        frictions = (try container.decodeIfPresent([String].self, forKey: .frictions) ?? []).compactMap(Friction.init(rawValue:))
        experience = try? container.decodeIfPresent(Experience.self, forKey: .experience)
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
struct TrackingUpdate: Codable, Sendable, Equatable {
    var mode: TrackingMode? = nil
    var focusMetrics: [FocusMetric]? = nil
    var declineOffer: String? = nil
    var source: PreferenceSource = .chosen
    /// Decision 66. Nil keeps the latest value; an empty frictions list is an answer ("none").
    var nudgeLevel: NudgeLevel? = nil
    var frictions: [Friction]? = nil
    /// Decision 69. Nil keeps the latest value.
    var logAnchor: LogAnchor? = nil

    /// Who moved the preference: the person by hand, the person saying yes to an invitation, or
    /// the person declining one.
    enum PreferenceSource: String, Codable, Sendable {
        case chosen, invited, declined
    }
}

// Decoded only as the bar's Undo (decision 71): the previous values the server hands back for
// the phone's own PUT. Tolerant, in an extension so the memberwise initializer survives.
extension TrackingUpdate {
    private enum CodingKeys: String, CodingKey {
        case mode, focusMetrics, declineOffer, source, nudgeLevel, frictions, logAnchor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(TrackingMode.self, forKey: .mode)
        focusMetrics = try container.decodeIfPresent([FocusMetric].self, forKey: .focusMetrics)
        declineOffer = try container.decodeIfPresent(String.self, forKey: .declineOffer)
        let sourceWord = try container.decodeIfPresent(String.self, forKey: .source)
        source = sourceWord.flatMap(PreferenceSource.init(rawValue:)) ?? .chosen
        nudgeLevel = try container.decodeIfPresent(NudgeLevel.self, forKey: .nudgeLevel)
        frictions = try container.decodeIfPresent([Friction].self, forKey: .frictions)
        logAnchor = try container.decodeIfPresent(LogAnchor.self, forKey: .logAnchor)
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
