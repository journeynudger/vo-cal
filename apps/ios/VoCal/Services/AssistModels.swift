import Foundation

// The bar's answer (decision 71, docs/design/the-bar-answers-spec.md): the wire shape of
// POST /assist. Field names map to snake_case via VoCalJSON. Tolerant decode throughout (the
// decode rule, apps/ios/AGENTS.md): a kind, a surface or a field this build does not know draws
// the line alone, never a blank and never a failure.

/// One turn of the thread the sheet holds for its life: the person's sentence or the app's
/// catalog line. Sent with each request so a follow-up resolves; stored nowhere.
struct AssistTurn: Codable, Sendable, Equatable {
    var role: String
    var text: String

    static func person(_ text: String) -> AssistTurn { AssistTurn(role: "person", text: text) }
    static func app(_ text: String) -> AssistTurn { AssistTurn(role: "app", text: text) }
}

/// `POST /assist`: the sentence, the thread, and the person's day and zone (as Today sends
/// them) so a number asked for is today's.
struct AssistRequest: Encodable, Sendable {
    var text: String
    var thread: [AssistTurn]
    var date: String?
    var tz: String?
}

/// The changed row, as Settings draws it: the icon tile, the label, the value trailing.
struct AssistChange: Decodable, Sendable, Equatable {
    var icon: String
    var title: String
    var value: String
}

/// The way to the surface that has what was asked for.
struct AssistPointer: Decodable, Sendable, Equatable {
    var surface: String
    var title: String

    enum Surface: String, Sendable {
        case today
        case week
        case protocolPage = "protocol"
        case plan
        case settings
        case notifications
        case profile
    }

    var knownSurface: Surface? { Surface(rawValue: surface) }
}

/// What puts a change back: the previous values for the phone's own `PUT /tracking`, the
/// opposite reactions for `POST /nudges/reactions`. The same calls a tap makes.
struct AssistUndo: Sendable, Equatable {
    var tracking: TrackingUpdate?
    var reactions: [NudgeReactionRequest] = []

    var isEmpty: Bool { tracking == nil && reactions.isEmpty }
}

extension AssistUndo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case tracking, reactions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracking = try container.decodeIfPresent(TrackingUpdate.self, forKey: .tracking)
        reactions = try container.decodeIfPresent([NudgeReactionRequest].self, forKey: .reactions) ?? []
    }
}

/// The answer. `kind` says what happened; the line is the catalog's; at most one of `change`,
/// `panel`, `pointer` is the thing shown; `undo` exists only when a change landed; `turn` is the
/// app's turn for the thread.
struct AssistReply: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// A tracking version or reaction rows were appended; the row shows it; Undo exists.
        case changed
        /// The Today card for the number asked about.
        case shown
        /// The way to the surface that has it.
        case pointed
        /// The line alone: the honest no, "already so", a metric not on Today.
        case told
        /// The sentence described a meal nothing was heard in: the old failure copy applies.
        case meal
    }

    var kind: String
    var line: String
    var change: AssistChange?
    var panel: TodayPanel?
    var pointer: AssistPointer?
    var undo: AssistUndo?
    var turn: AssistTurn

    var knownKind: Kind? { Kind(rawValue: kind) }
}

extension AssistReply: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, line, change, panel, pointer, undo, turn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        line = try container.decode(String.self, forKey: .line)
        change = try container.decodeIfPresent(AssistChange.self, forKey: .change)
        panel = try container.decodeIfPresent(TodayPanel.self, forKey: .panel)
        pointer = try container.decodeIfPresent(AssistPointer.self, forKey: .pointer)
        undo = try container.decodeIfPresent(AssistUndo.self, forKey: .undo)
        turn = try container.decodeIfPresent(AssistTurn.self, forKey: .turn) ?? .app(line)
    }
}
