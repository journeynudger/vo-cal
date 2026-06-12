import Foundation

public enum RelayJobPriority: Int, Sendable, Codable, CaseIterable {
    case voice = 1
    case share = 2
    case text = 3

    public static func forCapture(kind: String, source: String) -> RelayJobPriority {
        if kind == "voice" {
            return .voice
        }
        if source == CaptureSourceSurface.shareExtension.rawValue {
            return .share
        }
        return .text
    }
}

public enum RelayJobState: String, Sendable, Codable, CaseIterable {
    case queued
    case leased
    case quarantined
}

public enum RelayFailureClass: String, Sendable, Codable, CaseIterable {
    case transient
    case throttled
    case auth
    case permanent
    case duplicate
}

public struct RelayJobRecord: Equatable, Sendable, Identifiable {
    public let captureID: String
    public let priority: RelayJobPriority
    public let state: RelayJobState
    public let attemptCount: Int
    public let nextEligibleAt: Date
    public let leaseToken: String?
    public let leaseExpiresAt: Date?
    public let lastFailureClass: RelayFailureClass?
    public let lastFailureMessage: String?
    public let lastFailureDomain: String?
    public let lastFailureCode: Int?
    public let lastHTTPStatus: Int?
    public let createdAt: Date
    public let updatedAt: Date

    public var id: String { captureID }

    public init(
        captureID: String,
        priority: RelayJobPriority,
        state: RelayJobState,
        attemptCount: Int,
        nextEligibleAt: Date,
        leaseToken: String? = nil,
        leaseExpiresAt: Date? = nil,
        lastFailureClass: RelayFailureClass? = nil,
        lastFailureMessage: String? = nil,
        lastFailureDomain: String? = nil,
        lastFailureCode: Int? = nil,
        lastHTTPStatus: Int? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.captureID = captureID
        self.priority = priority
        self.state = state
        self.attemptCount = attemptCount
        self.nextEligibleAt = nextEligibleAt
        self.leaseToken = leaseToken
        self.leaseExpiresAt = leaseExpiresAt
        self.lastFailureClass = lastFailureClass
        self.lastFailureMessage = lastFailureMessage
        self.lastFailureDomain = lastFailureDomain
        self.lastFailureCode = lastFailureCode
        self.lastHTTPStatus = lastHTTPStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RelayWorkerState: Equatable, Sendable {
    public let authPaused: Bool
    public let authPauseMessage: String?
    public let lastSuccessfulUploadAt: Date?
    public let lastSuccessfulCaptureID: String?
    public let lastPollAt: Date?
    public let lastPollReason: String?

    public init(
        authPaused: Bool,
        authPauseMessage: String? = nil,
        lastSuccessfulUploadAt: Date? = nil,
        lastSuccessfulCaptureID: String? = nil,
        lastPollAt: Date? = nil,
        lastPollReason: String? = nil
    ) {
        self.authPaused = authPaused
        self.authPauseMessage = authPauseMessage
        self.lastSuccessfulUploadAt = lastSuccessfulUploadAt
        self.lastSuccessfulCaptureID = lastSuccessfulCaptureID
        self.lastPollAt = lastPollAt
        self.lastPollReason = lastPollReason
    }

    public static let initial = RelayWorkerState(authPaused: false)
}

public struct RelayQueueHealth: Equatable, Sendable {
    public let pendingJobCount: Int
    public let leasedCount: Int
    public let quarantinedCount: Int
    public let authPaused: Bool
    public let pausedReason: String?
    public let oldestPendingCreatedAt: Date?
    public let lastSuccessfulUploadAt: Date?
    public let lastSuccessfulCaptureID: String?

    public init(
        pendingJobCount: Int,
        leasedCount: Int,
        quarantinedCount: Int,
        authPaused: Bool,
        pausedReason: String? = nil,
        oldestPendingCreatedAt: Date? = nil,
        lastSuccessfulUploadAt: Date? = nil,
        lastSuccessfulCaptureID: String? = nil
    ) {
        self.pendingJobCount = pendingJobCount
        self.leasedCount = leasedCount
        self.quarantinedCount = quarantinedCount
        self.authPaused = authPaused
        self.pausedReason = pausedReason
        self.oldestPendingCreatedAt = oldestPendingCreatedAt
        self.lastSuccessfulUploadAt = lastSuccessfulUploadAt
        self.lastSuccessfulCaptureID = lastSuccessfulCaptureID
    }

    public static let initial = RelayQueueHealth(
        pendingJobCount: 0,
        leasedCount: 0,
        quarantinedCount: 0,
        authPaused: false
    )
}

public struct UploadLease: Equatable, Sendable {
    public let claimedAt: Date
    public let deadline: Date

    public init(claimedAt: Date, deadline: Date) {
        self.claimedAt = claimedAt
        self.deadline = deadline
    }
}

public struct PendingRemoteSyncState: Equatable, Sendable {
    public let priority: RelayJobPriority
    public let attemptCount: Int
    public let nextEligibleAt: Date
    public let lastFailureClass: RelayFailureClass?
    public let lastFailureMessage: String?
    public let lastFailureDomain: String?
    public let lastFailureCode: Int?
    public let lastHTTPStatus: Int?

    public init(
        priority: RelayJobPriority,
        attemptCount: Int,
        nextEligibleAt: Date,
        lastFailureClass: RelayFailureClass? = nil,
        lastFailureMessage: String? = nil,
        lastFailureDomain: String? = nil,
        lastFailureCode: Int? = nil,
        lastHTTPStatus: Int? = nil
    ) {
        self.priority = priority
        self.attemptCount = attemptCount
        self.nextEligibleAt = nextEligibleAt
        self.lastFailureClass = lastFailureClass
        self.lastFailureMessage = lastFailureMessage
        self.lastFailureDomain = lastFailureDomain
        self.lastFailureCode = lastFailureCode
        self.lastHTTPStatus = lastHTTPStatus
    }
}

public struct ActiveRemoteSyncState: Equatable, Sendable {
    public let priority: RelayJobPriority
    public let attemptCount: Int
    public let lease: UploadLease

    public init(
        priority: RelayJobPriority,
        attemptCount: Int,
        lease: UploadLease
    ) {
        self.priority = priority
        self.attemptCount = attemptCount
        self.lease = lease
    }
}

public struct QuarantinedRemoteSyncState: Equatable, Sendable {
    public let priority: RelayJobPriority
    public let attemptCount: Int
    public let quarantinedAt: Date
    public let failureClass: RelayFailureClass
    public let failureMessage: String?
    public let failureDomain: String?
    public let failureCode: Int?
    public let httpStatus: Int?

    public init(
        priority: RelayJobPriority,
        attemptCount: Int,
        quarantinedAt: Date,
        failureClass: RelayFailureClass,
        failureMessage: String? = nil,
        failureDomain: String? = nil,
        failureCode: Int? = nil,
        httpStatus: Int? = nil
    ) {
        self.priority = priority
        self.attemptCount = attemptCount
        self.quarantinedAt = quarantinedAt
        self.failureClass = failureClass
        self.failureMessage = failureMessage
        self.failureDomain = failureDomain
        self.failureCode = failureCode
        self.httpStatus = httpStatus
    }
}

public enum RemoteSyncState: Equatable, Sendable {
    case none
    case pending(PendingRemoteSyncState)
    case uploading(ActiveRemoteSyncState)
    case quarantined(QuarantinedRemoteSyncState)
}

public struct OutboxSnapshotCapture: Equatable, Sendable, Identifiable {
    public let captureID: String
    public let kind: String
    public let source: String
    public let localState: CaptureLocalState
    public let createdAt: Date
    public let updatedAt: Date
    public let remoteSyncState: RemoteSyncState

    public var id: String { captureID }

    public init(
        captureID: String,
        kind: String,
        source: String,
        localState: CaptureLocalState,
        createdAt: Date,
        updatedAt: Date,
        remoteSyncState: RemoteSyncState
    ) {
        self.captureID = captureID
        self.kind = kind
        self.source = source
        self.localState = localState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.remoteSyncState = remoteSyncState
    }
}

public struct OutboxSnapshot: Equatable, Sendable {
    public let captures: [OutboxSnapshotCapture]
    public let workerState: RelayWorkerState

    public init(captures: [OutboxSnapshotCapture], workerState: RelayWorkerState) {
        self.captures = captures
        self.workerState = workerState
    }
}

public enum OutboxHint: Equatable, Sendable {
    case maybeChanged
}

public struct UploadLaunch: Equatable, Sendable, Identifiable {
    public let captureID: String
    public let attemptCount: Int
    public let lease: UploadLease

    public var id: String {
        "\(captureID)|\(CaptureDateCodec.internetString(lease.claimedAt))"
    }

    public init(captureID: String, attemptCount: Int, lease: UploadLease) {
        self.captureID = captureID
        self.attemptCount = attemptCount
        self.lease = lease
    }
}

public struct RelayOutcomeFailure: Equatable, Sendable {
    public let failureClass: RelayFailureClass
    public let message: String
    public let errorDomain: String?
    public let errorCode: Int?
    public let httpStatus: Int?
    public let retryAfter: TimeInterval?
    public let relayReachable: Bool

    public init(
        failureClass: RelayFailureClass,
        message: String,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        httpStatus: Int? = nil,
        retryAfter: TimeInterval? = nil,
        relayReachable: Bool
    ) {
        self.failureClass = failureClass
        self.message = message
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.httpStatus = httpStatus
        self.retryAfter = retryAfter
        self.relayReachable = relayReachable
    }
}

public enum UploadOutcome: Equatable, Sendable {
    case accepted(CaptureServerRecord)
    case duplicate(CaptureServerRecord?)
    case auth(RelayOutcomeFailure)
    case throttled(RelayOutcomeFailure)
    case permanent(RelayOutcomeFailure)
    case transient(RelayOutcomeFailure)
    case timedOut(RelayOutcomeFailure)
}

public enum OutboxMutation: Equatable, Sendable {
    case claimUpload(
        captureID: String,
        expectedUpdatedAt: Date,
        attemptCount: Int,
        claimedAt: Date,
        deadline: Date
    )
    case requeue(
        captureID: String,
        expectedClaimedAt: Date?,
        lifecycleState: CaptureLocalState,
        nextEligibleAt: Date,
        failureClass: RelayFailureClass?,
        failureMessage: String?,
        failureDomain: String?,
        failureCode: Int?,
        httpStatus: Int?
    )
    case quarantine(
        captureID: String,
        expectedClaimedAt: Date?,
        quarantinedAt: Date,
        failureClass: RelayFailureClass,
        failureMessage: String?,
        failureDomain: String?,
        failureCode: Int?,
        httpStatus: Int?
    )
    case applyServerRecord(CaptureServerRecord, completedAt: Date)
    case pauseAuth(message: String?, at: Date, reason: String)
    case resumeAuth(at: Date, reason: String)
    case recordPoll(at: Date, reason: String)
}

public struct RelayPlan: Equatable, Sendable {
    public let mutations: [OutboxMutation]
    public let launches: [UploadLaunch]
    public let wakeAt: Date?

    public init(mutations: [OutboxMutation], launches: [UploadLaunch], wakeAt: Date?) {
        self.mutations = mutations
        self.launches = launches
        self.wakeAt = wakeAt
    }
}

public struct RelayDisposition: Equatable, Sendable {
    public let mutations: [OutboxMutation]

    public init(mutations: [OutboxMutation]) {
        self.mutations = mutations
    }
}

public struct MutationResult: Equatable, Sendable {
    public let applied: Bool

    public init(applied: Bool) {
        self.applied = applied
    }
}
