import Foundation
import VoCalCore

/// The REST surface the voice-log loop consumes. Defined as a protocol so the loop can
/// be driven by a mock with zero network on the simulator (the mock path is the
/// sim-verifiable default; see RuntimeMode). All bodies/responses cross the wire via
/// `VoCalJSON` codecs (snake_case + ISO8601), matching the FastAPI contract exactly.
protocol APIClientProtocol: Sendable {
    /// `POST /parse` — transcript -> structured items + macros + at most one question.
    /// `transcriptID` is the server transcript UUID from `POST /transcribe`: without it the
    /// stored parse row loses the capture→transcript→parse provenance link (AGENTS.md #5).
    func parse(transcript: String, captureID: String?, transcriptID: String?) async throws -> ParseResult

    /// `POST /parse/refine` — answer one or more clarifying questions; returns a new,
    /// immutable parse (supersedes the previous). Macros update in place client-side.
    func refine(parseID: String, answers: [RefineAnswer]) async throws -> ParseResult

    /// `POST /meals` — confirm the parsed meal into a durable log. Idempotent by
    /// `clientMealID` so an offline/outbox replay is safe. Returns the server's
    /// committed row — the only proof that licenses the "Logged" claim.
    func logMeal(_ request: LogMealRequest) async throws -> MealLogConfirmation

    /// `POST /meals/{id}/append` — add a new capture's confirmed items to an already-logged
    /// meal (the "add more by voice" flow). Idempotent server-side by the appended parse.
    /// Returns the meal's updated row — the only proof that licenses the "Added" claim.
    func appendToMeal(id: String, _ request: AppendToMealRequest) async throws -> MealLogConfirmation

    /// `POST /meals/water` — hydration tally (not a meal); feeds Today's water card.
    func logWater(_ request: WaterLogRequest) async throws -> WaterLog

    /// `POST /captures` (multipart) — durably store capture audio (ground truth) and return
    /// the server capture id. Idempotent by `clientCaptureID`.
    func uploadCapture(
        audio: Data,
        filename: String,
        contentType: String,
        clientCaptureID: String,
        durationMs: Int?,
        device: String?
    ) async throws -> CaptureUploadResult

    /// `POST /transcribe` — server-side ElevenLabs transcription of the stored capture audio.
    func transcribe(captureID: String) async throws -> TranscriptResult

    /// `POST /nudges/plan` — the deterministic smart-nudge plan for right now:
    /// at most one immediate card + the local-notification schedule, at the user's
    /// delivery level. The client sends its shown-ledger so server cooldowns hold
    /// across evaluations.
    func nudgePlan(recentlyShown: [String: String], level: NudgeLevel) async throws -> NudgePlan

    /// `GET /meals/learned-names` — what the parser learned from renames (Settings list).
    func learnedNames() async throws -> [LearnedName]

    /// `POST /meals/learned-names/forget` — stop applying one learned rename. Append-only
    /// server-side: the rows that taught it stay as the audit trail.
    func forgetLearnedName(heard: String) async throws

    /// `DELETE /account` — irreversibly delete the caller's account + all their data.
    func deleteAccount() async throws
}

/// `POST /captures` response (CaptureStatus). We need the server id + status here.
struct CaptureUploadResult: Decodable, Sendable, Equatable {
    let id: String
    let status: String
    let deduped: Bool?
}

/// `POST /intake` response — the persisted intake's id + version (the echoed profile is ignored).
struct IntakeSaveResult: Decodable, Sendable, Equatable {
    let intakeId: String
    let version: Int
}

/// `POST /transcribe` response. `text` feeds /parse; `transcriptId` carries provenance.
struct TranscriptResult: Decodable, Sendable, Equatable {
    let transcriptId: String
    let captureId: String
    let text: String
    let provider: String
    let languageCode: String?
    let durationMs: Int?
}

/// One clarifying answer routed to `POST /parse/refine`. `value` is a number for amount
/// fields and a string otherwise (the server's RefineAnswer.value is `Any`).
struct RefineAnswer: Codable, Sendable, Equatable {
    let field: String
    let value: AnswerValue

    enum AnswerValue: Codable, Sendable, Equatable {
        case string(String)
        case number(Double)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .string(value):
                try container.encode(value)
            case let .number(value):
                try container.encode(value)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else {
                self = .string(try container.decode(String.self))
            }
        }
    }
}
