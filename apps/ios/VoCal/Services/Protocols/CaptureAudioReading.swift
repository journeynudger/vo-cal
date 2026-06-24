import Foundation

/// Read-only access to a committed capture's audio bytes, for server upload + transcription.
/// A seam (not a direct CaptureOutbox dependency) so the live meal service stays testable and
/// the safety-critical capture subsystem is reached only through one narrow, read-only door.
///
/// Returning nil (capture or blob not found) degrades transcription gracefully — the audio is
/// already durably committed and is never at risk (VOICE_CAPTURE.md: a transcription failure is
/// not a capture failure). This is consumed in the derived pipeline, off the capture hot path.
protocol CaptureAudioReading: Sendable {
    func committedAudio(captureID: String) async throws -> CommittedAudio?
}

/// The bytes + multipart metadata needed to POST a capture to the backend.
struct CommittedAudio: Sendable, Equatable {
    let data: Data
    let filename: String
    let contentType: String
}
