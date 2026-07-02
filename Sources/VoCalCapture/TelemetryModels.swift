import Foundation

public struct CaptureOperationalState: Equatable, Sendable {
    public var started: Bool
    public var deviceID: String?
    public var outboxPath: String?
    public var relayBaseURL: String?
    public var relayEnvironment: String?
    public var accountID: String?
    public var declaredCount: Int
    public var uploadingCount: Int
    public var failedCount: Int
    public var pendingJobCount: Int
    public var quarantinedCount: Int
    public var authPaused: Bool
    public var pausedReason: String?
    public var oldestPendingCreatedAt: Date?
    public var lastSuccessfulUploadAt: Date?
    public var latestCaptureID: String?
    public var latestCaptureState: String?
    public var latestCaptureCreatedAt: Date?
    public var relayReachable: Bool
    public var inFlight: Bool
    public var lastSyncAt: Date?
    public var lastReason: String?
    public var lastError: String?

    public init(
        started: Bool,
        deviceID: String?,
        outboxPath: String?,
        relayBaseURL: String?,
        relayEnvironment: String?,
        accountID: String?,
        declaredCount: Int,
        uploadingCount: Int,
        failedCount: Int,
        pendingJobCount: Int,
        quarantinedCount: Int,
        authPaused: Bool,
        pausedReason: String?,
        oldestPendingCreatedAt: Date?,
        lastSuccessfulUploadAt: Date?,
        latestCaptureID: String?,
        latestCaptureState: String?,
        latestCaptureCreatedAt: Date?,
        relayReachable: Bool,
        inFlight: Bool,
        lastSyncAt: Date?,
        lastReason: String?,
        lastError: String?
    ) {
        self.started = started
        self.deviceID = deviceID
        self.outboxPath = outboxPath
        self.relayBaseURL = relayBaseURL
        self.relayEnvironment = relayEnvironment
        self.accountID = accountID
        self.declaredCount = declaredCount
        self.uploadingCount = uploadingCount
        self.failedCount = failedCount
        self.pendingJobCount = pendingJobCount
        self.quarantinedCount = quarantinedCount
        self.authPaused = authPaused
        self.pausedReason = pausedReason
        self.oldestPendingCreatedAt = oldestPendingCreatedAt
        self.lastSuccessfulUploadAt = lastSuccessfulUploadAt
        self.latestCaptureID = latestCaptureID
        self.latestCaptureState = latestCaptureState
        self.latestCaptureCreatedAt = latestCaptureCreatedAt
        self.relayReachable = relayReachable
        self.inFlight = inFlight
        self.lastSyncAt = lastSyncAt
        self.lastReason = lastReason
        self.lastError = lastError
    }

    public static let initial = CaptureOperationalState(
        started: false,
        deviceID: nil,
        outboxPath: nil,
        relayBaseURL: nil,
        relayEnvironment: nil,
        accountID: nil,
        declaredCount: 0,
        uploadingCount: 0,
        failedCount: 0,
        pendingJobCount: 0,
        quarantinedCount: 0,
        authPaused: false,
        pausedReason: nil,
        oldestPendingCreatedAt: nil,
        lastSuccessfulUploadAt: nil,
        latestCaptureID: nil,
        latestCaptureState: nil,
        latestCaptureCreatedAt: nil,
        relayReachable: false,
        inFlight: false,
        lastSyncAt: nil,
        lastReason: nil,
        lastError: nil
    )
}

public struct CaptureOperationalSummary: Equatable, Sendable {
    public var declaredCount: Int
    public var uploadingCount: Int
    public var failedCount: Int
    public var pendingJobCount: Int
    public var quarantinedCount: Int
    public var authPaused: Bool
    public var pausedReason: String?
    public var oldestPendingCreatedAt: Date?
    public var lastSuccessfulUploadAt: Date?
    public var latestCaptureID: String?
    public var latestCaptureState: String?
    public var latestCaptureCreatedAt: Date?

    public init(
        declaredCount: Int,
        uploadingCount: Int,
        failedCount: Int,
        pendingJobCount: Int,
        quarantinedCount: Int,
        authPaused: Bool,
        pausedReason: String?,
        oldestPendingCreatedAt: Date?,
        lastSuccessfulUploadAt: Date?,
        latestCaptureID: String?,
        latestCaptureState: String?,
        latestCaptureCreatedAt: Date?
    ) {
        self.declaredCount = declaredCount
        self.uploadingCount = uploadingCount
        self.failedCount = failedCount
        self.pendingJobCount = pendingJobCount
        self.quarantinedCount = quarantinedCount
        self.authPaused = authPaused
        self.pausedReason = pausedReason
        self.oldestPendingCreatedAt = oldestPendingCreatedAt
        self.lastSuccessfulUploadAt = lastSuccessfulUploadAt
        self.latestCaptureID = latestCaptureID
        self.latestCaptureState = latestCaptureState
        self.latestCaptureCreatedAt = latestCaptureCreatedAt
    }
}

// Deleted in the Vo-Cal port: `LocationUploadSnapshot` and `LocationTelemetrySnapshot`
// (Serein's passive location-stream telemetry) lived at the end of this file.
// Requirement: Vo-Cal P0 has no passive location/stream subsystem — capture telemetry only.
// Failure mode avoided: dead types referencing a subsystem that does not exist here invite
// agents to "wire them up", re-importing location concerns onto the capture path.
// Evidence: Vo-Cal docs/INVARIANTS.md port provenance (passive-stream/location material
// deleted in §1, §7, §10) and Phase C plan C0 acceptance ("zero references to removed
// Serein subsystems"). Re-port from Serein's SereinCapture/TelemetryModels.swift if a
// location stream ever lands.
