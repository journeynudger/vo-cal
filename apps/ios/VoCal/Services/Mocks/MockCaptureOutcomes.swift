import Foundation
import VoCalCapture

/// No backend and no outbox on the mock path: one unfinished recording is seeded on today
/// so the Unfinished row is exercisable on the simulator, gone once it is logged or discarded.
actor MockCaptureOutcomes: UnfinishedCaptureReading, CaptureOutcomeRecording {
    static let shared = MockCaptureOutcomes()
    static let seededCaptureID = "voice_mock_unfinished"

    private var finished: Set<String> = []

    func unfinishedCaptures(on day: Date) -> [UnfinishedCapture] {
        let calendar = Calendar.current
        guard !finished.contains(Self.seededCaptureID), calendar.isDateInToday(day) else { return [] }
        let capturedAt = calendar.date(bySettingHour: 12, minute: 41, second: 0, of: day) ?? day
        return [UnfinishedCapture(captureID: Self.seededCaptureID, capturedAt: capturedAt)]
    }

    func record(_ outcome: CaptureOutcome) {
        finished.insert(outcome.captureID)
    }
}
