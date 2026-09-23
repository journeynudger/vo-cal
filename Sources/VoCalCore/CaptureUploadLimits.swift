import Foundation

/// Bounds the phone and the server agree on for a capture upload.
///
/// `maxAudioBytes` mirrors `_MAX_AUDIO_BYTES` in `services/api/src/api/captures/router.py`,
/// where the server answers 413 above it. The phone checks a blob's size BEFORE reading it:
/// `VoiceCaptureCoordinator.committedAudio` loaded the whole file into memory and the
/// multipart body copied it again, so an oversized recording cost twice its size in RAM for
/// an upload the server would refuse anyway (restructure Phase 3.2, 2026-09-23). One number,
/// two addresses, held equal by a test on each side.
public enum CaptureUploadLimits {
    public static let maxAudioBytes: Int64 = 50 * 1024 * 1024
}
