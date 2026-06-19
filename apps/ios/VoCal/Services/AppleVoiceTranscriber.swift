import Foundation

#if canImport(Speech)
import Speech
#endif

// DEVICE-ONLY. This is the live on-device transcription path. It CANNOT be sim-verified:
// the simulator has no microphone and the captured CAF is silence, so the mock transcriber
// supplies a canned transcript for the sim/UITestMode path (see MockVoiceTranscriber and
// MealCaptureService selection). On a real iOS 26 device this runs Apple's on-device
// SpeechTranscriber/SpeechAnalyzer over the committed capture file.
//
// On-device requirement (privacy + offline capture, AGENTS.md voice-first): transcription
// must not require the network. iOS 26's SpeechAnalyzer with a SpeechTranscriber module
// runs the model locally once the locale assets are installed; we request asset
// installation and analyze the committed file URL. Wire this fully in the device thesis
// pass (Phase D6) — it is intentionally a thin, compile-clean stub here so the live path
// exists behind the protocol without blocking the sim-verifiable mock path.
struct AppleVoiceTranscriber: VoiceTranscriber {
    func transcribe(audioURL: URL?) async throws -> String {
        guard let audioURL else {
            throw TranscriptionError.noAudio
        }

        #if canImport(Speech) && !targetEnvironment(simulator)
        // iOS 26 on-device path. SpeechAnalyzer + SpeechTranscriber analyze the committed
        // file locally. The concrete module wiring (locale asset install, analyzer feed,
        // result aggregation) is completed against a real device in the D6 thesis pass;
        // the requirement captured here is: on-device, file-based, no network, retryable.
        return try await transcribeOnDevice(fileURL: audioURL)
        #else
        // Reached only if this type is somehow selected on the simulator. The mock path is
        // the simulator default, so treat this as unavailable rather than fabricate text
        // (no false transcript — capture stays the source of truth).
        throw TranscriptionError.unavailable("on_device_unavailable_on_simulator")
        #endif
    }

    #if canImport(Speech) && !targetEnvironment(simulator)
    private func transcribeOnDevice(fileURL: URL) async throws -> String {
        // Placeholder for the device pass (D6). Kept minimal and honest: until the
        // SpeechAnalyzer module feed is wired against hardware, surface unavailability
        // rather than return fabricated text.
        throw TranscriptionError.unavailable("on_device_transcriber_pending_device_wiring")
    }
    #endif
}
