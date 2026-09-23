import Foundation
import Testing
@testable import VoCalCore

@Suite("CaptureUploadLimits")
struct CaptureUploadLimitsTests {
    // BOUNDARY: the server's captures router refuses audio above _MAX_AUDIO_BYTES with 413.
    // The phone must refuse the same size before reading the blob. The Python side asserts
    // the same number from this file (services/api/tests/test_capture_limits.py).
    @Test("The upload cap is the server's 50 MB")
    func capMatchesServer() {
        #expect(CaptureUploadLimits.maxAudioBytes == 50 * 1024 * 1024)
    }
}
