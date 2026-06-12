import Foundation
import Testing
@testable import VoCalCapture

@Suite(.serialized)
struct RelayPlannerTests {
    private let planner = RelayPlanner()

    @Test("Expired leases are reclaimed into declared retry state")
    func expiredLeasesAreReclaimed() {
        let now = date("2026-04-09T18:00:00Z")
        let snapshot = OutboxSnapshot(
            captures: [
                capture(
                    id: "voice_capture_expired",
                    createdAt: now.addingTimeInterval(-600),
                    updatedAt: now.addingTimeInterval(-300),
                    remoteSyncState: .uploading(
                        ActiveRemoteSyncState(
                            priority: .voice,
                            attemptCount: 2,
                            lease: UploadLease(
                                claimedAt: now.addingTimeInterval(-360),
                                deadline: now.addingTimeInterval(-30)
                            )
                        )
                    )
                )
            ],
            workerState: .initial
        )

        let plan = planner.plan(
            snapshot: snapshot,
            now: now,
            activeCaptureIDs: ["voice_capture_expired"],
            concurrencyLimit: 1
        )

        #expect(plan.launches.isEmpty)
        #expect(
            plan.mutations.contains(
                .requeue(
                    captureID: "voice_capture_expired",
                    expectedClaimedAt: now.addingTimeInterval(-360),
                    lifecycleState: .declared,
                    nextEligibleAt: now.addingTimeInterval(RelayPlanner.leaseExpiryRetryDelay),
                    failureClass: .transient,
                    failureMessage: "lease_expired",
                    failureDomain: nil,
                    failureCode: nil,
                    httpStatus: nil
                )
            )
        )
    }

    @Test("Auth pause prevents new launches")
    func authPausePreventsLaunches() {
        let now = date("2026-04-09T18:00:00Z")
        let snapshot = OutboxSnapshot(
            captures: [
                capture(
                    id: "voice_capture_pending",
                    createdAt: now.addingTimeInterval(-60),
                    updatedAt: now.addingTimeInterval(-60),
                    remoteSyncState: .pending(
                        PendingRemoteSyncState(
                            priority: .voice,
                            attemptCount: 0,
                            nextEligibleAt: now
                        )
                    )
                )
            ],
            workerState: RelayWorkerState(authPaused: true, authPauseMessage: "auth expired")
        )

        let plan = planner.plan(
            snapshot: snapshot,
            now: now,
            activeCaptureIDs: [],
            concurrencyLimit: 1
        )

        #expect(plan.launches.isEmpty)
        #expect(!plan.mutations.contains { if case .claimUpload = $0 { return true } else { return false } })
    }

    @Test("Transient failures requeue with exponential backoff")
    func transientFailuresBackoff() {
        let now = date("2026-04-09T18:00:00Z")
        let launch = UploadLaunch(
            captureID: "voice_capture_retry",
            attemptCount: 3,
            lease: UploadLease(
                claimedAt: now.addingTimeInterval(-15),
                deadline: now.addingTimeInterval(240)
            )
        )
        let failure = RelayOutcomeFailure(
            failureClass: .transient,
            message: "timed_out",
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorTimedOut,
            httpStatus: nil,
            retryAfter: nil,
            relayReachable: false
        )

        let disposition = planner.classify(launch: launch, outcome: .transient(failure), now: now)

        #expect(
            disposition.mutations == [
                .requeue(
                    captureID: "voice_capture_retry",
                    expectedClaimedAt: launch.lease.claimedAt,
                    lifecycleState: .uploadFailed,
                    nextEligibleAt: now.addingTimeInterval(120),
                    failureClass: .transient,
                    failureMessage: "timed_out",
                    failureDomain: NSURLErrorDomain,
                    failureCode: NSURLErrorTimedOut,
                    httpStatus: nil
                )
            ]
        )
    }

    @Test("Permanent failures quarantine")
    func permanentFailuresQuarantine() {
        let now = date("2026-04-09T18:00:00Z")
        let launch = UploadLaunch(
            captureID: "voice_capture_bad_manifest",
            attemptCount: 1,
            lease: UploadLease(
                claimedAt: now.addingTimeInterval(-10),
                deadline: now.addingTimeInterval(290)
            )
        )
        let failure = RelayOutcomeFailure(
            failureClass: .permanent,
            message: "schema_mismatch",
            errorDomain: "HTTPURLResponse",
            errorCode: 400,
            httpStatus: 400,
            retryAfter: nil,
            relayReachable: true
        )

        let disposition = planner.classify(launch: launch, outcome: .permanent(failure), now: now)

        #expect(
            disposition.mutations == [
                .quarantine(
                    captureID: "voice_capture_bad_manifest",
                    expectedClaimedAt: launch.lease.claimedAt,
                    quarantinedAt: now,
                    failureClass: .permanent,
                    failureMessage: "schema_mismatch",
                    failureDomain: "HTTPURLResponse",
                    failureCode: 400,
                    httpStatus: 400
                )
            ]
        )
    }

    @Test("Duplicate uploads reconcile to uploaded when server truth exists")
    func duplicateUploadsReconcileToUploaded() {
        let now = date("2026-04-09T18:00:00Z")
        let launch = UploadLaunch(
            captureID: "voice_capture_duplicate",
            attemptCount: 2,
            lease: UploadLease(
                claimedAt: now.addingTimeInterval(-20),
                deadline: now.addingTimeInterval(280)
            )
        )
        let record = serverRecord(captureID: "voice_capture_duplicate", seq: 42)

        let disposition = planner.classify(launch: launch, outcome: .duplicate(record), now: now)

        #expect(disposition.mutations == [.applyServerRecord(record, completedAt: now)])
    }

    @Test("Successful uploads are never gated on lease ownership")
    func successfulUploadsAreNeverDiscardedForStaleLeaseOwnership() {
        let now = date("2026-04-09T18:00:00Z")
        let launch = UploadLaunch(
            captureID: "voice_capture_success",
            attemptCount: 4,
            lease: UploadLease(
                claimedAt: now.addingTimeInterval(-200),
                deadline: now.addingTimeInterval(-1)
            )
        )
        let record = serverRecord(captureID: "voice_capture_success", seq: 99)

        let disposition = planner.classify(launch: launch, outcome: .accepted(record), now: now)

        #expect(disposition.mutations == [.applyServerRecord(record, completedAt: now)])
    }

    @Test("Concurrency limit is respected")
    func concurrencyLimitIsRespected() {
        let now = date("2026-04-09T18:00:00Z")
        let snapshot = OutboxSnapshot(
            captures: [
                pendingCapture(id: "text_capture", priority: .text, now: now, createdAtOffset: -30),
                pendingCapture(id: "share_capture", priority: .share, now: now, createdAtOffset: -20),
                pendingCapture(id: "voice_capture", priority: .voice, now: now, createdAtOffset: -10),
                capture(
                    id: "already_uploading",
                    createdAt: now.addingTimeInterval(-50),
                    updatedAt: now.addingTimeInterval(-50),
                    remoteSyncState: .uploading(
                        ActiveRemoteSyncState(
                            priority: .voice,
                            attemptCount: 1,
                            lease: UploadLease(
                                claimedAt: now.addingTimeInterval(-30),
                                deadline: now.addingTimeInterval(270)
                            )
                        )
                    )
                )
            ],
            workerState: .initial
        )

        let plan = planner.plan(
            snapshot: snapshot,
            now: now,
            activeCaptureIDs: ["already_uploading"],
            concurrencyLimit: 2
        )

        #expect(plan.launches.map(\.captureID) == ["voice_capture"])
    }

    @Test("Planner is deterministic for the same snapshot and clock")
    func plannerIsDeterministic() {
        let now = date("2026-04-09T18:00:00Z")
        let snapshot = OutboxSnapshot(
            captures: [
                pendingCapture(id: "voice_capture", priority: .voice, now: now, createdAtOffset: -120),
                pendingCapture(id: "share_capture", priority: .share, now: now, createdAtOffset: -60),
            ],
            workerState: .initial
        )

        let first = planner.plan(snapshot: snapshot, now: now, activeCaptureIDs: [], concurrencyLimit: 2)
        let second = planner.plan(snapshot: snapshot, now: now, activeCaptureIDs: [], concurrencyLimit: 2)

        #expect(first == second)
    }

    @Test("Planner ignores timezone and DST settings")
    func plannerIgnoresTimezoneAndDSTSettings() {
        let now = date("2026-03-08T06:55:00Z")
        let snapshot = OutboxSnapshot(
            captures: [
                pendingCapture(id: "voice_capture_dst", priority: .voice, now: now, createdAtOffset: -300),
            ],
            workerState: .initial
        )
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let newYorkPlan = planner.plan(snapshot: snapshot, now: now, activeCaptureIDs: [], concurrencyLimit: 1)

        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        let losAngelesPlan = planner.plan(snapshot: snapshot, now: now, activeCaptureIDs: [], concurrencyLimit: 1)

        #expect(newYorkPlan == losAngelesPlan)
    }

    private func pendingCapture(
        id: String,
        priority: RelayJobPriority,
        now: Date,
        createdAtOffset: TimeInterval
    ) -> OutboxSnapshotCapture {
        capture(
            id: id,
            createdAt: now.addingTimeInterval(createdAtOffset),
            updatedAt: now.addingTimeInterval(createdAtOffset),
            remoteSyncState: .pending(
                PendingRemoteSyncState(
                    priority: priority,
                    attemptCount: 0,
                    nextEligibleAt: now
                )
            )
        )
    }

    private func capture(
        id: String,
        createdAt: Date,
        updatedAt: Date,
        remoteSyncState: RemoteSyncState
    ) -> OutboxSnapshotCapture {
        OutboxSnapshotCapture(
            captureID: id,
            kind: "voice",
            source: CaptureSourceSurface.nativeRecorder.rawValue,
            localState: .declared,
            createdAt: createdAt,
            updatedAt: updatedAt,
            remoteSyncState: remoteSyncState
        )
    }

    private func serverRecord(captureID: String, seq: Int64) -> CaptureServerRecord {
        let json = """
        {
          "seq": \(seq),
          "capture_id": "\(captureID)",
          "kind": "voice",
          "source": "\(CaptureSourceSurface.nativeRecorder.rawValue)",
          "captured_at": "2026-04-09T17:59:00Z",
          "effective_day": "2026-04-09",
          "state": "\(CaptureLocalState.uploaded.rawValue)",
          "blob_filename": "voice.caf",
          "blob_content_type": "audio/x-caf",
          "created_at": "2026-04-09T17:59:00Z",
          "artifacts": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            return try CaptureDateCodec.parseInternetDate(raw)
        }
        guard let record = try? decoder.decode(CaptureServerRecord.self, from: Data(json.utf8)) else {
            fatalError("server record fixture should decode")
        }
        return record
    }

    private func date(_ raw: String) -> Date {
        (try? CaptureDateCodec.parseInternetDate(raw)) ?? Date(timeIntervalSince1970: 0)
    }
}
