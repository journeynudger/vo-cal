import Foundation
import VoCalCore

/// The REST surface the voice-log loop consumes. Defined as a protocol so the loop can
/// be driven by a mock with zero network on the simulator (the mock path is the
/// sim-verifiable default; see RuntimeMode). All bodies/responses cross the wire via
/// `VoCalJSON` codecs (snake_case + ISO8601), matching the FastAPI contract exactly.
protocol APIClientProtocol: Sendable {
    /// `POST /parse` — transcript -> structured items + macros + at most one question.
    func parse(transcript: String, captureID: String?) async throws -> ParseResult

    /// `POST /parse/refine` — answer one or more clarifying questions; returns a new,
    /// immutable parse (supersedes the previous). Macros update in place client-side.
    func refine(parseID: String, answers: [RefineAnswer]) async throws -> ParseResult

    /// `POST /meals` — confirm the parsed meal into a durable log. Idempotent by
    /// `clientMealID` so an offline/outbox replay is safe. Returns the server's
    /// committed row — the only proof that licenses the "Logged" claim.
    func logMeal(_ request: LogMealRequest) async throws -> MealLogConfirmation

    /// `GET /meals/today` — the day's targets/consumed/remaining. Not on the capture
    /// hot path; here so the loop can refresh Today after a confirm.
    func today(date: String) async throws -> TodayResult

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

    /// `DELETE /account` — irreversibly delete the caller's account + all their data.
    func deleteAccount() async throws
}

/// `POST /captures` response (CaptureStatus). We need the server id + status here.
struct CaptureUploadResult: Decodable, Sendable, Equatable {
    let id: String
    let status: String
    let deduped: Bool?
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
