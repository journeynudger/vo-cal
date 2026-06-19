import Foundation
import VoCalCore

/// One canned scenario the mock loop can play. Drives which transcript is "heard" and
/// which ParseResult comes back, so every UI state is reachable on the sim.
enum MockCaptureScenario: String, Sendable, CaseIterable {
    /// Fully specified, no clarifying questions — straight to confirm.
    case beefAndRice
    /// Unknown beef fat ratio + cheddar variant + mayo — clarifying checks fire.
    case burger
}

/// Orchestrates the post-capture half of the loop: transcript -> parse -> (refine)? ->
/// confirm. The view model owns the capture (claim-ladder) states; this service owns the
/// derived `transcribed/parsed/logged` rungs (VOICE_CAPTURE.md). Protocol so the loop runs
/// fully on the sim against canned ParseResults with no network or microphone.
protocol MealCaptureService: Sendable {
    /// Transcribe the committed capture audio. Mock returns a canned transcript.
    func transcribe(captureID: String, audioURL: URL?) async throws -> String

    /// Parse a transcript into structured items + macros + at most one question.
    func parse(transcript: String, captureID: String) async throws -> ParseResult

    /// Answer clarifying question(s); returns a superseding parse with updated macros.
    func refine(parseID: String, answers: [RefineAnswer]) async throws -> ParseResult

    /// Confirm the meal into a durable log. The returned confirmation is the only proof
    /// that licenses the "Logged" claim.
    func logMeal(_ request: LogMealRequest) async throws -> MealLogConfirmation
}

/// Live service: every method delegates to the REST APIClient. The transcript comes from
/// the on-device transcriber (device-only); parse/refine/log hit the backend.
struct LiveMealCaptureService: MealCaptureService {
    let api: any APIClientProtocol
    let transcriber: any VoiceTranscriber

    func transcribe(captureID: String, audioURL: URL?) async throws -> String {
        try await transcriber.transcribe(audioURL: audioURL)
    }

    func parse(transcript: String, captureID: String) async throws -> ParseResult {
        try await api.parse(transcript: transcript, captureID: captureID)
    }

    func refine(parseID: String, answers: [RefineAnswer]) async throws -> ParseResult {
        try await api.refine(parseID: parseID, answers: answers)
    }

    func logMeal(_ request: LogMealRequest) async throws -> MealLogConfirmation {
        try await api.logMeal(request)
    }
}
