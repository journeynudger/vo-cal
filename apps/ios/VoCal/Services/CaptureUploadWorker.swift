import Foundation
import VoCalCapture
import VoCalVoice

/// The relay worker for committed captures: every capture the phone has durably saved
/// reaches the server without the person keeping a sheet open.
///
/// Requirement (restructure Phase 3.2, plan task C4 that was never built): until now the
/// only upload was the one the voice-log sheet made inline; a failed upload after the sheet
/// closed, or a capture made offline, stayed local forever. "Saved" was honest and the
/// meal never happened. INVARIANTS §9: all pending work converges.
///
/// Level-triggered: a pass derives its work from the outbox's durable relay state through
/// RelayPlanner (leases with deadlines, 30 s doubling backoff capped at 30 min, twenty
/// transient attempts then quarantine, an auth pause on 401) and never from the event that
/// woke it. Passes run at start, when a capture commits, when the outbox changes on disk,
/// when the scene becomes active, and at the planner's next wake. Nothing here is awaited
/// by the capture path: the coordinator's commit observer hands over a receipt and returns.
///
/// The voice-log sheet uploads eagerly through the same worker (`uploadNow`): one uploader,
/// one bookkeeping, so a sheet closed mid-upload leaves a job the next pass finishes, and a
/// pass never races an upload the sheet is already making (the eager set is skipped).
actor CaptureUploadWorker: CaptureCommitObserver, CaptureEagerUploading {
    static let shared = CaptureUploadWorker(door: VoiceCaptureCoordinator.shared, uploader: APIClient())
    /// Uploads per pass. Two: a burst of offline captures drains in a few passes without
    /// holding several multipart bodies in memory at once.
    static let concurrency = 2

    private let door: any CaptureRelayDoor
    private let uploader: any CaptureUploading
    private let ensureSession: @Sendable () async -> Void
    private var eager: Set<String> = []
    private var passRunning = false
    private var passRequested = false
    private var hintTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var started = false

    init(
        door: any CaptureRelayDoor,
        uploader: any CaptureUploading,
        ensureSession: @escaping @Sendable () async -> Void = { await AuthCoordinator.shared.ensureSession() }
    ) {
        self.door = door
        self.uploader = uploader
        self.ensureSession = ensureSession
    }

    /// Subscribe to the outbox's hints and run the first pass. Idempotent.
    func start() async {
        guard !started else { return }
        started = true
        let door = self.door
        hintTask = Task { [weak self] in
            for await _ in await door.relayChanges() {
                guard let self, !Task.isCancelled else { return }
                await self.kick("outbox_changed")
            }
        }
        kick("start")
    }

    func stop() {
        hintTask?.cancel()
        wakeTask?.cancel()
        hintTask = nil
        wakeTask = nil
        started = false
    }

    /// Ask for a pass soon; a pass already running absorbs it (coalesced, never queued).
    func kick(_ reason: String) {
        if passRunning {
            passRequested = true
            return
        }
        Task { await self.runPass(reason: reason, now: Date()) }
    }

    func captureCommitted(_ record: LocalCommitReceipt) async {
        kick("capture_committed")
    }

    /// One pass: reclaim expired leases and claim what is eligible (the planner), upload
    /// each claim, settle its outcome. `now` is injectable so a test can move the clock
    /// past a backoff instead of waiting for it.
    func runPass(reason: String, now: Date = Date()) async {
        if passRunning {
            passRequested = true
            return
        }
        passRunning = true
        defer { passRunning = false }
        wakeTask?.cancel()
        await ensureSession()
        do {
            let launches = try await door.claimUploadLaunches(limit: Self.concurrency, now: now)
                .filter { !eager.contains($0.captureID) }
            for launch in launches {
                let outcome = await perform(launch)
                let disposition = RelayPlanner().classify(launch: launch, outcome: outcome, now: Date())
                try await door.settleUpload(disposition)
            }
        } catch {
            // The outbox refused (a locked database, a corrupt row): the next pass derives the
            // same work again; nothing is lost by returning.
        }
        if passRequested {
            passRequested = false
            Task { await self.runPass(reason: "coalesced", now: Date()) }
            return
        }
        await scheduleWake()
    }

    /// The sheet's upload: immediate, through the same door, so a success is recorded once
    /// and a permanent refusal (413, 422) quarantines the job instead of leaving it for a
    /// pass to refuse again. Transient failures are the caller's to retry quickly; the pass
    /// picks the job up with backoff if the caller gives up.
    func uploadNow(captureID: String) async throws -> CaptureUploadResult {
        eager.insert(captureID)
        defer { eager.remove(captureID) }
        guard let local = try await door.committedRecord(captureID: captureID),
              let audio = try await door.committedAudio(captureID: captureID)
        else {
            throw TranscriptionError.noAudio
        }
        do {
            let result = try await uploader.uploadCapture(
                audio: audio.data,
                filename: audio.filename,
                contentType: audio.contentType,
                clientCaptureID: captureID,
                durationMs: nil,
                device: nil
            )
            let record = Self.serverRecord(for: local, result: result, at: Date())
            try? await door.settleUpload(RelayDisposition(mutations: [.applyServerRecord(record, completedAt: Date())]))
            return result
        } catch {
            if case let .permanent(failure) = Self.outcome(for: error) {
                try? await door.settleUpload(RelayDisposition(mutations: [
                    .quarantine(
                        captureID: captureID,
                        expectedClaimedAt: nil,
                        quarantinedAt: Date(),
                        failureClass: failure.failureClass,
                        failureMessage: failure.message,
                        failureDomain: failure.errorDomain,
                        failureCode: failure.errorCode,
                        httpStatus: failure.httpStatus
                    ),
                ]))
            }
            throw error
        }
    }

    // MARK: - One launch

    private func perform(_ launch: UploadLaunch) async -> UploadOutcome {
        do {
            guard let local = try await door.committedRecord(captureID: launch.captureID) else {
                return .permanent(RelayOutcomeFailure(failureClass: .permanent, message: "capture_missing", relayReachable: true))
            }
            guard let audio = try await door.committedAudio(captureID: launch.captureID) else {
                // A deferred commit whose blob has not converged yet: transient, bounded by
                // the planner's attempt count.
                return .transient(RelayOutcomeFailure(failureClass: .transient, message: "audio_not_ready", relayReachable: true))
            }
            let result = try await uploader.uploadCapture(
                audio: audio.data,
                filename: audio.filename,
                contentType: audio.contentType,
                clientCaptureID: launch.captureID,
                durationMs: nil,
                device: nil
            )
            let record = Self.serverRecord(for: local, result: result, at: Date())
            return result.deduped == true ? .duplicate(record) : .accepted(record)
        } catch {
            return Self.outcome(for: error)
        }
    }

    /// The planner's vocabulary for an error. Both failure directions are decided here: a
    /// permanent class stops a job that would fail the same way forever (the 413 above the
    /// cap, a 422 the server will always answer); a transient class keeps a job the next
    /// pass might finish (a timeout, a cold Fly machine, a 5xx), bounded by the planner.
    static func outcome(for error: any Error) -> UploadOutcome {
        if case .blobExceedsUploadCap = error as? VoiceCaptureError {
            return .permanent(RelayOutcomeFailure(failureClass: .permanent, message: "blob_exceeds_upload_cap", relayReachable: true))
        }
        guard let api = error as? APIError else {
            return .transient(RelayOutcomeFailure(failureClass: .transient, message: String(describing: type(of: error)), relayReachable: true))
        }
        switch api {
        case .transport:
            return .transient(RelayOutcomeFailure(failureClass: .transient, message: "transport", relayReachable: false))
        case let .status(code, _):
            switch code {
            case 401:
                return .auth(RelayOutcomeFailure(failureClass: .auth, message: "unauthorized", httpStatus: code, relayReachable: true))
            case 429:
                return .throttled(RelayOutcomeFailure(failureClass: .throttled, message: "throttled", httpStatus: code, relayReachable: true))
            case 408, 500...599:
                return .transient(RelayOutcomeFailure(failureClass: .transient, message: "server_\(code)", httpStatus: code, relayReachable: true))
            default:
                return .permanent(RelayOutcomeFailure(failureClass: .permanent, message: "rejected_\(code)", httpStatus: code, relayReachable: true))
            }
        case .decoding:
            // The upload may have landed; a retry dedups on the server and reconciles.
            return .transient(RelayOutcomeFailure(failureClass: .transient, message: "decoding", relayReachable: true))
        case .badURL:
            return .permanent(RelayOutcomeFailure(failureClass: .permanent, message: "bad_url", relayReachable: false))
        }
    }

    /// The record the outbox keeps after a success: the local facts plus the one server
    /// fact that matters, that the blob and the row are durable (state uploaded). The server's
    /// own status string is not copied into the local state: it is the server's vocabulary.
    static func serverRecord(for local: LocalCaptureRecord, result: CaptureUploadResult, at now: Date) -> CaptureServerRecord {
        CaptureServerRecord(
            seq: 0,
            captureID: local.captureID,
            kind: local.kind,
            source: local.source,
            title: nil,
            textContent: nil,
            foundURL: nil,
            capturedAt: local.capturedAt,
            effectiveDay: local.effectiveDay,
            state: CaptureLocalState.uploaded.rawValue,
            lastError: nil,
            blobFilename: local.blobFilename,
            blobContentType: local.blobContentType,
            createdAt: now,
            enrichedAt: nil,
            artifacts: []
        )
    }

    private func scheduleWake() async {
        wakeTask?.cancel()
        guard let at = try? await door.nextUploadEligibleAt() else { return }
        let delay = max(1, at.timeIntervalSinceNow)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.kick("wake")
        }
    }
}

extension APIClient: CaptureUploading {}
