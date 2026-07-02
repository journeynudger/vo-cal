import Foundation

// The on-device `VoiceTranscriber` protocol (+ MockVoiceTranscriber / AppleVoiceTranscriber)
// was removed when transcription moved server-side (decision 2026-06-23): the loop now
// transcribes via MealCaptureService against the API. Only this error type survives — it is
// still thrown by LiveMealCaptureService when committed audio can't be read.

enum TranscriptionError: LocalizedError {
    case noAudio
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return "transcription_no_audio"
        case let .unavailable(reason):
            return "transcription_unavailable:\(reason)"
        }
    }
}
