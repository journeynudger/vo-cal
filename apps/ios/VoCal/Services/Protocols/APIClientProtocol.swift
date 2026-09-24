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

    /// `POST /parse/photo` (multipart) — a photographed meal: the server stores the photo as
    /// a capture, the vision model extracts, the ladder prices; what the photo cannot see
    /// comes back as checks. `note` is the person's typed line, authoritative over the image.
    func parsePhoto(_ photo: Data, contentType: String, clientCaptureID: String, note: String?) async throws -> ParseResult

    /// `GET /meals/search?q=` — what the person has logged before that matches the typing.
    func searchLogged(query: String) async throws -> [SearchHit]

    /// `PATCH /meals/{id}/name` — the person's own name for a meal; it becomes a usual.
    func renameMeal(id: String, name: String) async throws -> LoggedMeal

    /// `PATCH /meals/usuals/{id}/name` — the person's own name for a usual (409 when another
    /// usual already carries it).
    func renameUsual(id: String, name: String) async throws -> SavedMeal

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

    /// `GET /foods/personal` — the foods the person declared (label or batch), newest first.
    func personalFoods() async throws -> [PersonalFood]

    /// `POST /foods/personal` — save a food from its label. The server computes calories from
    /// the macros when the label's are not given, and prices the food by name from then on.
    func saveLabelFood(_ request: SaveLabelFoodRequest) async throws -> PersonalFood

    /// `POST /foods/personal/batch` — save a batch as a recipe: the server re-resolves the
    /// items, sums them, divides by the servings it makes.
    func saveBatchFood(_ request: SaveBatchFoodRequest) async throws -> PersonalFood

    /// `DELETE /foods/personal/{id}` — retire one (a mark; logged meals keep their numbers).
    func retirePersonalFood(id: String) async throws

    /// `GET /meals/deleted` — meals deleted inside the restore window, newest first.
    func deletedMeals() async throws -> [DeletedMeal]

    /// `POST /meals/{id}/restore` — undo a delete: the meal is back on its day exactly as it
    /// was. 409 when a replay re-logged the same meal meanwhile; 410 past the window.
    func restoreMeal(id: String) async throws -> LoggedMeal

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
