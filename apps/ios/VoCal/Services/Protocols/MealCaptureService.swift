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

/// Live service: every method delegates to the REST APIClient. Transcription is server-side
/// ElevenLabs Scribe (decision 2026-06-23, reversing on-device #24): the committed audio is
/// uploaded as ground truth, then the server transcribes it. parse/refine/log hit the backend.
struct LiveMealCaptureService: MealCaptureService {
    let api: any APIClientProtocol
    /// Read-only door to the committed capture audio (the VoiceCaptureCoordinator).
    let audioReader: any CaptureAudioReading
    /// Optional non-PII device label for the capture audit trail (nil by default — never a
    /// user-set device name, which is PII; MUST NOT log precise PII).
    var deviceName: String?

    func transcribe(captureID: String, audioURL: URL?) async throws -> String {
        // Off the capture hot path (derived pipeline). audioURL is unused — the bytes come from
        // the durably-committed outbox blob, read read-only via the coordinator.
        guard let audio = try await audioReader.committedAudio(captureID: captureID) else {
            throw TranscriptionError.noAudio
        }
        let upload = try await api.uploadCapture(
            audio: audio.data,
            filename: audio.filename,
            contentType: audio.contentType,
            clientCaptureID: captureID,
            durationMs: nil,
            device: deviceName
        )
        return try await api.transcribe(captureID: upload.id).text
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
