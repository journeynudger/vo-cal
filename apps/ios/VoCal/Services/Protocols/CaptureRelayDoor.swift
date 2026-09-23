import Foundation
import VoCalCapture

/// What the upload worker may ask of the capture runtime: the outbox's relay-job state,
/// through the coordinator, never the outbox itself. Same storage as the capture path,
/// never the same authority (ARCHITECTURE.md): the planner decides, the worker performs,
/// the outbox records. Every call is off the capture hot path by construction: a capture in
/// progress is not in the outbox until it is committed.
protocol CaptureRelayDoor: CaptureAudioReading {
    /// Lease up to `limit` eligible captures for upload (the planner's claims).
    func claimUploadLaunches(limit: Int, now: Date) async throws -> [UploadLaunch]
    /// Record an upload's outcome (the planner's disposition: server record, requeue with
    /// backoff, quarantine, auth pause).
    func settleUpload(_ disposition: RelayDisposition) async throws
    /// The committed local record, for the server record the worker writes after success.
    func committedRecord(captureID: String) async throws -> LocalCaptureRecord?
    /// When the next queued upload becomes eligible; nil when nothing is queued.
    func nextUploadEligibleAt() async throws -> Date?
    /// A hint whenever the outbox changes on disk (a commit, a settle from another pass).
    func relayChanges() async -> AsyncStream<OutboxHint>
}

/// One upload, now, for a sheet the person is looking at (LiveMealCaptureService).
protocol CaptureEagerUploading: Sendable {
    func uploadNow(captureID: String) async throws -> CaptureUploadResult
}

/// The one network call the worker makes. APIClient conforms; the self-test uses a stub.
protocol CaptureUploading: Sendable {
    func uploadCapture(
        audio: Data,
        filename: String,
        contentType: String,
        clientCaptureID: String,
        durationMs: Int?,
        device: String?
    ) async throws -> CaptureUploadResult
}
