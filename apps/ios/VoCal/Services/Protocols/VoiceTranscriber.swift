import Foundation

/// Turns committed capture audio into a transcript string. Defined as a protocol so the
/// sim/UITestMode path uses a canned transcript (no microphone exists on the simulator),
/// while the device path uses on-device Apple Speech. A transcription failure is never a
/// capture failure — the audio is already durably saved; the transcript can be retried
/// (VOICE_CAPTURE.md derived `transcribed` rung).
protocol VoiceTranscriber: Sendable {
    /// Transcribe the committed capture at `audioURL`. `audioURL` is nil on the mock path
    /// (no real file); live implementations require it.
    func transcribe(audioURL: URL?) async throws -> String
}

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

/// Sim/UITestMode transcriber: returns a fixed messy-speech transcript so the
/// enhancing/result states are reachable without a mic. The canned text is the
/// fully-specified gold utterance by default; the capture service can override it per
/// scenario (e.g. the "burger…" path) by constructing the mock with a different string.
struct MockVoiceTranscriber: VoiceTranscriber {
    /// Default canned transcript — the lingo-tutorial gold-standard utterance.
    static let defaultTranscript =
        "so I had um four ounces of 93/7 beef and like two hundred grams of cooked jasmine rice"

    let transcript: String
    /// Simulated on-device transcription latency so the UI shows the Transcribing state.
    let latency: Duration

    init(transcript: String = MockVoiceTranscriber.defaultTranscript, latency: Duration = .milliseconds(700)) {
        self.transcript = transcript
        self.latency = latency
    }

    func transcribe(audioURL: URL?) async throws -> String {
        try? await Task.sleep(for: latency)
        return transcript
    }
}
