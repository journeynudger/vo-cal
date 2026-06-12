import Foundation

public struct RelayPlanner: Sendable {
    public static let uploadLeaseInterval: TimeInterval = 5 * 60
    public static let leaseExpiryRetryDelay: TimeInterval = 30
    public static let defaultThrottleRetryDelay: TimeInterval = 15 * 60
    public static let transientMaxAttempts = 20

    public init() {}

    public func plan(
        snapshot: OutboxSnapshot,
        now: Date,
        activeCaptureIDs: Set<String>,
        concurrencyLimit: Int
    ) -> RelayPlan {
        var mutations: [OutboxMutation] = []
        var launches: [UploadLaunch] = []
        var wakeCandidates: [Date] = []
        var pendingCandidates: [PendingCandidate] = []
        var hasMaintenanceMutations = false

        for capture in snapshot.captures {
            switch capture.remoteSyncState {
            case .none:
                continue
            case let .pending(pending):
                wakeCandidates.append(pending.nextEligibleAt)
                if !activeCaptureIDs.contains(capture.captureID) {
                    pendingCandidates.append(PendingCandidate(capture: capture, pending: pending))
                }
            case let .uploading(uploading):
                wakeCandidates.append(uploading.lease.deadline)
                if uploading.lease.deadline <= now {
                    mutations.append(
                        .requeue(
                            captureID: capture.captureID,
                            expectedClaimedAt: uploading.lease.claimedAt,
                            lifecycleState: .declared,
                            nextEligibleAt: now.addingTimeInterval(Self.leaseExpiryRetryDelay),
                            failureClass: .transient,
                            failureMessage: "lease_expired",
                            failureDomain: nil,
                            failureCode: nil,
                            httpStatus: nil
                        )
                    )
                    hasMaintenanceMutations = true
                } else if !activeCaptureIDs.contains(capture.captureID) {
                    mutations.append(
                        .requeue(
                            captureID: capture.captureID,
                            expectedClaimedAt: uploading.lease.claimedAt,
                            lifecycleState: .declared,
                            nextEligibleAt: now,
                            failureClass: .transient,
                            failureMessage: "upload_session_recovered",
                            failureDomain: nil,
                            failureCode: nil,
                            httpStatus: nil
                        )
                    )
                    hasMaintenanceMutations = true
                }
            case .quarantined:
                continue
            }
        }

        if !snapshot.workerState.authPaused {
            let availableSlots = max(0, concurrencyLimit - activeCaptureIDs.count)
            if availableSlots > 0 {
                let eligibleCandidates = pendingCandidates
                    .filter { $0.pending.nextEligibleAt <= now }
                    .sorted(by: PendingCandidate.sort)

                for candidate in eligibleCandidates.prefix(availableSlots) {
                    let attemptCount = candidate.pending.attemptCount + 1
                    let lease = UploadLease(
                        claimedAt: now,
                        deadline: now.addingTimeInterval(Self.uploadLeaseInterval)
                    )
                    mutations.append(
                        .claimUpload(
                            captureID: candidate.capture.captureID,
                            expectedUpdatedAt: candidate.capture.updatedAt,
                            attemptCount: attemptCount,
                            claimedAt: lease.claimedAt,
                            deadline: lease.deadline
                        )
                    )
                    launches.append(
                        UploadLaunch(
                            captureID: candidate.capture.captureID,
                            attemptCount: attemptCount,
                            lease: lease
                        )
                    )
                }
            }
        }

        let wakeAt = nextWakeAt(
            wakeCandidates: wakeCandidates,
            hasMaintenanceMutations: hasMaintenanceMutations,
            now: now
        )
        return RelayPlan(mutations: mutations, launches: launches, wakeAt: wakeAt)
    }

    public func classify(
        launch: UploadLaunch,
        outcome: UploadOutcome,
        now: Date
    ) -> RelayDisposition {
        switch outcome {
        case let .accepted(record):
            return RelayDisposition(
                mutations: [.applyServerRecord(record, completedAt: now)]
            )
        case let .duplicate(record):
            if let record {
                return RelayDisposition(
                    mutations: [.applyServerRecord(record, completedAt: now)]
                )
            }
            return retryDisposition(
                launch: launch,
                now: now,
                lifecycleState: .uploadFailed,
                failureClass: .transient,
                failureMessage: "duplicate_reconciliation_failed",
                failureDomain: "RelayPlanner",
                failureCode: nil,
                httpStatus: 409
            )
        case let .auth(failure):
            return RelayDisposition(
                mutations: [
                    .pauseAuth(message: failure.message, at: now, reason: "relay_auth_blocked"),
                    .requeue(
                        captureID: launch.captureID,
                        expectedClaimedAt: launch.lease.claimedAt,
                        lifecycleState: .uploadFailed,
                        nextEligibleAt: now,
                        failureClass: failure.failureClass,
                        failureMessage: failure.message,
                        failureDomain: failure.errorDomain,
                        failureCode: failure.errorCode,
                        httpStatus: failure.httpStatus
                    ),
                ]
            )
        case let .throttled(failure):
            return RelayDisposition(
                mutations: [
                    .requeue(
                        captureID: launch.captureID,
                        expectedClaimedAt: launch.lease.claimedAt,
                        lifecycleState: .uploadFailed,
                        nextEligibleAt: now.addingTimeInterval(failure.retryAfter ?? Self.defaultThrottleRetryDelay),
                        failureClass: failure.failureClass,
                        failureMessage: failure.message,
                        failureDomain: failure.errorDomain,
                        failureCode: failure.errorCode,
                        httpStatus: failure.httpStatus
                    ),
                ]
            )
        case let .permanent(failure):
            return RelayDisposition(
                mutations: [
                    .quarantine(
                        captureID: launch.captureID,
                        expectedClaimedAt: launch.lease.claimedAt,
                        quarantinedAt: now,
                        failureClass: failure.failureClass,
                        failureMessage: failure.message,
                        failureDomain: failure.errorDomain,
                        failureCode: failure.errorCode,
                        httpStatus: failure.httpStatus
                    ),
                ]
            )
        case let .transient(failure):
            return retryDisposition(
                launch: launch,
                now: now,
                lifecycleState: .uploadFailed,
                failureClass: failure.failureClass,
                failureMessage: failure.message,
                failureDomain: failure.errorDomain,
                failureCode: failure.errorCode,
                httpStatus: failure.httpStatus
            )
        case let .timedOut(failure):
            return retryDisposition(
                launch: launch,
                now: now,
                lifecycleState: .declared,
                failureClass: failure.failureClass,
                failureMessage: failure.message,
                failureDomain: failure.errorDomain,
                failureCode: failure.errorCode,
                httpStatus: failure.httpStatus
            )
        }
    }

    private func retryDisposition(
        launch: UploadLaunch,
        now: Date,
        lifecycleState: CaptureLocalState,
        failureClass: RelayFailureClass,
        failureMessage: String?,
        failureDomain: String?,
        failureCode: Int?,
        httpStatus: Int?
    ) -> RelayDisposition {
        if launch.attemptCount >= Self.transientMaxAttempts {
            return RelayDisposition(
                mutations: [
                    .quarantine(
                        captureID: launch.captureID,
                        expectedClaimedAt: launch.lease.claimedAt,
                        quarantinedAt: now,
                        failureClass: failureClass,
                        failureMessage: failureMessage,
                        failureDomain: failureDomain,
                        failureCode: failureCode,
                        httpStatus: httpStatus
                    ),
                ]
            )
        }

        return RelayDisposition(
            mutations: [
                .requeue(
                    captureID: launch.captureID,
                    expectedClaimedAt: launch.lease.claimedAt,
                    lifecycleState: lifecycleState,
                    nextEligibleAt: nextTransientRetryDate(attemptCount: launch.attemptCount, now: now),
                    failureClass: failureClass,
                    failureMessage: failureMessage,
                    failureDomain: failureDomain,
                    failureCode: failureCode,
                    httpStatus: httpStatus
                ),
            ]
        )
    }

    private func nextWakeAt(
        wakeCandidates: [Date],
        hasMaintenanceMutations: Bool,
        now: Date
    ) -> Date? {
        let futureWake = wakeCandidates
            .filter { $0 > now }
            .min()
        if hasMaintenanceMutations {
            guard let futureWake else {
                return now
            }
            return min(now, futureWake)
        }
        return futureWake
    }

    private func nextTransientRetryDate(attemptCount: Int, now: Date) -> Date {
        let step = max(0, attemptCount - 1)
        let delay = min(30 * pow(2, Double(step)), 30 * 60)
        return now.addingTimeInterval(delay)
    }
}

private struct PendingCandidate {
    let capture: OutboxSnapshotCapture
    let pending: PendingRemoteSyncState

    static func sort(lhs: PendingCandidate, rhs: PendingCandidate) -> Bool {
        if lhs.pending.priority.rawValue != rhs.pending.priority.rawValue {
            return lhs.pending.priority.rawValue < rhs.pending.priority.rawValue
        }
        if lhs.pending.nextEligibleAt != rhs.pending.nextEligibleAt {
            return lhs.pending.nextEligibleAt < rhs.pending.nextEligibleAt
        }
        return lhs.capture.createdAt < rhs.capture.createdAt
    }
}
