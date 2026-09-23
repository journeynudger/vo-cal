import Foundation
import VoCalCapture

/// A committed recording on a day that has not reached "logged" and was not discarded.
struct UnfinishedCapture: Identifiable, Equatable, Sendable {
    let captureID: String
    let capturedAt: Date
    var id: String { captureID }
}

/// Today's read: what is unfinished on a day.
protocol UnfinishedCaptureReading: Sendable {
    func unfinishedCaptures(on day: Date) async throws -> [UnfinishedCapture]
}

/// The derived pipeline's and Today's write: what happened to a capture after "Saved".
protocol CaptureOutcomeRecording: Sendable {
    func record(_ outcome: CaptureOutcome) async
}

/// What happened to a capture after "Saved", kept beside the outbox, never in it.
///
/// Requirement (restructure R8, Bill's lifecycle question): a recording whose sheet was
/// closed before "Logged", or whose transcription failed offline, vanished from sight; the
/// audio was safe in the outbox and nobody could see it. "Saved" has to mean the person can
/// find it again. The outbox answers "what was recorded"; the ledger answers "what happened
/// next" (logged, with the meal; dismissed, with a reason); the difference, per local day,
/// is Today's Unfinished list. Same storage lifetime as the outbox (the app group), so the
/// two can never disagree after a reinstall: both are gone.
actor CaptureOutcomeStore: UnfinishedCaptureReading, CaptureOutcomeRecording {
    static let shared = CaptureOutcomeStore(door: VoiceCaptureCoordinator.shared, ledger: appGroupLedger())
    /// Newest committed captures scanned per read: bounded (INVARIANTS section 8) and far
    /// above a day's captures. A day further back than this many captures reads as clear.
    static let scanLimit = 500

    private let door: any CaptureHistoryReading
    private let ledger: CaptureOutcomeLedger

    init(door: any CaptureHistoryReading, ledger: CaptureOutcomeLedger) {
        self.door = door
        self.ledger = ledger
    }

    func unfinishedCaptures(on day: Date) async throws -> [UnfinishedCapture] {
        // The outbox's own effective day is UTC (the server's vocabulary); Today is a local
        // day, so membership is decided here with the local calendar.
        let calendar = Calendar.current
        let outcomes = try ledger.outcomes()
        return try await door.committedCaptures(limit: Self.scanLimit)
            .filter { calendar.isDate($0.capturedAt, inSameDayAs: day) && outcomes[$0.captureID] == nil }
            .sorted { $0.capturedAt < $1.capturedAt }
            .map { UnfinishedCapture(captureID: $0.captureID, capturedAt: $0.capturedAt) }
    }

    func record(_ outcome: CaptureOutcome) {
        // A ledger that cannot be written (a full disk) leaves the capture listed: the safe
        // direction, the person sees it again rather than losing it.
        try? ledger.append(outcome)
    }

    private static func appGroupLedger(fileManager: FileManager = .default) -> CaptureOutcomeLedger {
        let root = (try? AppGroupConfig.sharedContainerURL(fileManager: fileManager, bundle: .main))
            ?? fileManager.temporaryDirectory
        return CaptureOutcomeLedger(directory: VoCalCapturePaths.outcomesRoot(appGroupRoot: root))
    }
}
