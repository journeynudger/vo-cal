import Foundation
import VoCalCapture

public enum VoiceCapturePhase: String, Codable, Sendable, CaseIterable {
    case arming
    case starting
    case recordingUnverified = "recording_unverified"
    case recordingLive = "recording_live"
    case suspectedStall = "suspected_stall"
    case blocked
    case resuming
    case recovering
    case stopping
    case finalizing
    case commitDeferred = "commit_deferred"
    case committed
    case lost

    public var isTerminal: Bool {
        self == .committed || self == .lost
    }

    public var isActiveRecording: Bool {
        switch self {
        case .arming, .starting, .recordingUnverified, .recordingLive, .suspectedStall, .resuming, .recovering, .stopping:
            return true
        case .blocked, .finalizing, .commitDeferred, .committed, .lost:
            return false
        }
    }
}

public enum VoiceAudioFileStatus: String, Codable, Sendable {
    case open
    case closed
    case quarantined
}

public enum VoiceAudioFileRepairStatus: String, Codable, Sendable {
    case notNeeded = "not_needed"
    case repaired
    case failed
}

public enum VoiceSegmentSealReason: String, Codable, Sendable {
    case initialStart = "initial_start"
    case inputFormatChange = "input_format_change"
    case userStop = "user_stop"
    case routeChange = "route_change"
    case interruption = "interruption"
    case stallRecovery = "stall_recovery"
    case recoveryFinalize = "recovery_finalize"
    case finalization = "finalization"
}

public struct VoiceAudioFileSnapshot: Codable, Equatable, Sendable {
    public var relpath: String
    public var status: VoiceAudioFileStatus
    public var openedAt: Date
    public var closedAt: Date?
    public var bytes: Int64
    public var repairStatus: VoiceAudioFileRepairStatus
    public var sealReason: VoiceSegmentSealReason?

    public init(
        relpath: String,
        status: VoiceAudioFileStatus,
        openedAt: Date,
        closedAt: Date? = nil,
        bytes: Int64,
        repairStatus: VoiceAudioFileRepairStatus,
        sealReason: VoiceSegmentSealReason? = nil
    ) {
        self.relpath = relpath
        self.status = status
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.bytes = bytes
        self.repairStatus = repairStatus
        self.sealReason = sealReason
    }
}

private enum VoiceLegacySegmentStatus: String, Codable {
    case recording
    case sealed
    case quarantined
}

private enum VoiceLegacySegmentRepairStatus: String, Codable {
    case notNeeded = "not_needed"
    case repaired
    case failed

    var audioFileRepairStatus: VoiceAudioFileRepairStatus {
        switch self {
        case .notNeeded:
            return .notNeeded
        case .repaired:
            return .repaired
        case .failed:
            return .failed
        }
    }
}

private struct VoiceLegacySegmentSnapshot: Codable {
    let index: Int
    let relpath: String
    let status: VoiceLegacySegmentStatus
    let openedAt: Date
    let sealedAt: Date?
    let bytes: Int64
    let repairStatus: VoiceLegacySegmentRepairStatus
    let sealReason: VoiceSegmentSealReason?
}

public struct VoiceSessionSnapshot: Codable, Equatable, Sendable {
    public let sessionID: String
    public let captureID: String
    public var phase: VoiceCapturePhase
    public var sourceSurface: String
    public var createdAt: Date
    public var updatedAt: Date
    public var heartbeatAt: Date
    public var lastProgressAt: Date?
    public var failureReason: String?
    public var recoveryCount: Int
    public var preferredInputUID: String?
    public var audioFile: VoiceAudioFileSnapshot?
    public var finalBlobRelpath: String?
    public var pendingCommitReason: String?
    public var blockedReason: VoiceBlockedReason?
    public var blockerClearedAt: Date?
    public var blockedAutoFinalizeAt: Date?
    public var context: [String: CaptureJSONValue]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case captureID = "capture_id"
        case phase
        case sourceSurface = "source_surface"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case heartbeatAt = "heartbeat_at"
        case lastProgressAt = "last_progress_at"
        case failureReason = "failure_reason"
        case recoveryCount = "recovery_count"
        case preferredInputUID = "preferred_input_uid"
        case audioFile = "audio_file"
        case finalBlobRelpath = "final_blob_relpath"
        case pendingCommitReason = "pending_commit_reason"
        case blockedReason = "blocked_reason"
        case blockerClearedAt = "blocker_cleared_at"
        case blockedAutoFinalizeAt = "blocked_auto_finalize_at"
        case context
        case currentSegmentIndex = "current_segment_index"
        case currentSegmentRelpath = "current_segment_relpath"
        case segments
    }

    public init(
        sessionID: String,
        captureID: String,
        phase: VoiceCapturePhase,
        sourceSurface: String,
        createdAt: Date,
        updatedAt: Date,
        heartbeatAt: Date,
        lastProgressAt: Date? = nil,
        failureReason: String? = nil,
        recoveryCount: Int,
        preferredInputUID: String? = nil,
        audioFile: VoiceAudioFileSnapshot? = nil,
        finalBlobRelpath: String? = nil,
        pendingCommitReason: String? = nil,
        blockedReason: VoiceBlockedReason? = nil,
        blockerClearedAt: Date? = nil,
        blockedAutoFinalizeAt: Date? = nil,
        context: [String: CaptureJSONValue] = [:]
    ) {
        self.sessionID = sessionID
        self.captureID = captureID
        self.phase = phase
        self.sourceSurface = sourceSurface
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.heartbeatAt = heartbeatAt
        self.lastProgressAt = lastProgressAt
        self.failureReason = failureReason
        self.recoveryCount = recoveryCount
        self.preferredInputUID = preferredInputUID
        self.audioFile = audioFile
        self.finalBlobRelpath = finalBlobRelpath
        self.pendingCommitReason = pendingCommitReason
        self.blockedReason = blockedReason
        self.blockerClearedAt = blockerClearedAt
        self.blockedAutoFinalizeAt = blockedAutoFinalizeAt
        self.context = context
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        captureID = try container.decode(String.self, forKey: .captureID)
        phase = try container.decode(VoiceCapturePhase.self, forKey: .phase)
        sourceSurface = try container.decode(String.self, forKey: .sourceSurface)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        heartbeatAt = try container.decode(Date.self, forKey: .heartbeatAt)
        lastProgressAt = try container.decodeIfPresent(Date.self, forKey: .lastProgressAt)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        recoveryCount = try container.decode(Int.self, forKey: .recoveryCount)
        preferredInputUID = try container.decodeIfPresent(String.self, forKey: .preferredInputUID)
        finalBlobRelpath = try container.decodeIfPresent(String.self, forKey: .finalBlobRelpath)
        pendingCommitReason = try container.decodeIfPresent(String.self, forKey: .pendingCommitReason)
        blockedReason = try container.decodeIfPresent(VoiceBlockedReason.self, forKey: .blockedReason)
        blockerClearedAt = try container.decodeIfPresent(Date.self, forKey: .blockerClearedAt)
        blockedAutoFinalizeAt = try container.decodeIfPresent(Date.self, forKey: .blockedAutoFinalizeAt)
        context = try container.decodeIfPresent([String: CaptureJSONValue].self, forKey: .context) ?? [:]

        if let audioFile = try container.decodeIfPresent(VoiceAudioFileSnapshot.self, forKey: .audioFile) {
            self.audioFile = audioFile
            return
        }

        let currentSegmentIndex = try container.decodeIfPresent(Int.self, forKey: .currentSegmentIndex)
        let currentSegmentRelpath = try container.decodeIfPresent(String.self, forKey: .currentSegmentRelpath)
        let legacySegments = try container.decodeIfPresent([VoiceLegacySegmentSnapshot].self, forKey: .segments) ?? []

        let selectedSegment =
            legacySegments.first(where: { $0.index == currentSegmentIndex })
            ?? legacySegments.first(where: { $0.relpath == currentSegmentRelpath })
            ?? legacySegments.last(where: { $0.status == .recording })
            ?? legacySegments.max(by: { $0.bytes < $1.bytes })

        if let selectedSegment {
            let status: VoiceAudioFileStatus
            if currentSegmentRelpath != nil || selectedSegment.status == .recording {
                status = .open
            } else if selectedSegment.status == .quarantined {
                status = .quarantined
            } else {
                status = .closed
            }
            audioFile = VoiceAudioFileSnapshot(
                relpath: currentSegmentRelpath ?? selectedSegment.relpath,
                status: status,
                openedAt: selectedSegment.openedAt,
                closedAt: selectedSegment.sealedAt,
                bytes: selectedSegment.bytes,
                repairStatus: selectedSegment.repairStatus.audioFileRepairStatus,
                sealReason: selectedSegment.sealReason
            )
        } else {
            audioFile = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(captureID, forKey: .captureID)
        try container.encode(phase, forKey: .phase)
        try container.encode(sourceSurface, forKey: .sourceSurface)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(heartbeatAt, forKey: .heartbeatAt)
        try container.encodeIfPresent(lastProgressAt, forKey: .lastProgressAt)
        try container.encodeIfPresent(failureReason, forKey: .failureReason)
        try container.encode(recoveryCount, forKey: .recoveryCount)
        try container.encodeIfPresent(preferredInputUID, forKey: .preferredInputUID)
        try container.encodeIfPresent(audioFile, forKey: .audioFile)
        try container.encodeIfPresent(finalBlobRelpath, forKey: .finalBlobRelpath)
        try container.encodeIfPresent(pendingCommitReason, forKey: .pendingCommitReason)
        try container.encodeIfPresent(blockedReason, forKey: .blockedReason)
        try container.encodeIfPresent(blockerClearedAt, forKey: .blockerClearedAt)
        try container.encodeIfPresent(blockedAutoFinalizeAt, forKey: .blockedAutoFinalizeAt)
        try container.encode(context, forKey: .context)
    }
}

public struct VoiceDebugSnapshot: Equatable, Sendable {
    public var sessionCount: Int
    public var captureID: String?
    public var phase: VoiceCapturePhase?
    public var pendingCommitReason: String?
    public var segmentCount: Int
    public var permissionStatus: String
    public var appGroupPath: String?
    public var lastError: String?

    public static let empty = VoiceDebugSnapshot(
        sessionCount: 0,
        captureID: nil,
        phase: nil,
        pendingCommitReason: nil,
        segmentCount: 0,
        permissionStatus: "unknown",
        appGroupPath: nil,
        lastError: nil
    )

    public init(
        sessionCount: Int,
        captureID: String?,
        phase: VoiceCapturePhase?,
        pendingCommitReason: String?,
        segmentCount: Int,
        permissionStatus: String,
        appGroupPath: String?,
        lastError: String?
    ) {
        self.sessionCount = sessionCount
        self.captureID = captureID
        self.phase = phase
        self.pendingCommitReason = pendingCommitReason
        self.segmentCount = segmentCount
        self.permissionStatus = permissionStatus
        self.appGroupPath = appGroupPath
        self.lastError = lastError
    }
}

public struct VoiceToggleResult: Sendable {
    public enum Action: Sendable, Equatable {
        case started(captureID: String)
        case blocked(captureID: String)
        case stopping(captureID: String)
        case finalized(captureID: String)
        case deferred(captureID: String)
        case lost(captureID: String)
    }

    public let action: Action
    public let sessionID: String?

    public init(action: Action, sessionID: String?) {
        self.action = action
        self.sessionID = sessionID
    }
}

public struct VoiceCaptureConstants: Sendable {
    public var heartbeatStaleInterval: Duration = .seconds(5)
    public var startupDeadline: Duration = .seconds(8)
    public var steadyPollInterval: Duration = .milliseconds(500)
    public var transitionalPollInterval: Duration = .milliseconds(250)
    public var suspectedStallAfter: Duration = .milliseconds(1500)
    public var hardStallAfter: Duration = .seconds(3)
    public var recoveryWindow: Duration = .seconds(10)
    public var maxRecoveriesInWindow: Int = 2
    public var blockedAutoFinalizeInterval: Duration = .seconds(300)
    public var externalBlockerRetryDelay: Duration = .seconds(3)
    public var selfHealingRetryDelay: Duration = .seconds(1)

    public init(
        heartbeatStaleInterval: Duration = .seconds(5),
        startupDeadline: Duration = .seconds(8),
        steadyPollInterval: Duration = .milliseconds(500),
        transitionalPollInterval: Duration = .milliseconds(250),
        suspectedStallAfter: Duration = .milliseconds(1500),
        hardStallAfter: Duration = .seconds(3),
        recoveryWindow: Duration = .seconds(10),
        maxRecoveriesInWindow: Int = 2,
        blockedAutoFinalizeInterval: Duration = .seconds(300),
        externalBlockerRetryDelay: Duration = .seconds(3),
        selfHealingRetryDelay: Duration = .seconds(1)
    ) {
        self.heartbeatStaleInterval = heartbeatStaleInterval
        self.startupDeadline = startupDeadline
        self.steadyPollInterval = steadyPollInterval
        self.transitionalPollInterval = transitionalPollInterval
        self.suspectedStallAfter = suspectedStallAfter
        self.hardStallAfter = hardStallAfter
        self.recoveryWindow = recoveryWindow
        self.maxRecoveriesInWindow = maxRecoveriesInWindow
        self.blockedAutoFinalizeInterval = blockedAutoFinalizeInterval
        self.externalBlockerRetryDelay = externalBlockerRetryDelay
        self.selfHealingRetryDelay = selfHealingRetryDelay
    }
}

public enum VoiceRecoveryTrigger: String, Codable, Sendable, Equatable {
    case launch = "launch"
    case sceneActive = "scene_active"
    case protectedDataAvailable = "protected_data_available"
    case toggle = "toggle"
}

public enum VoiceSessionOwnership: String, Codable, Sendable, Equatable {
    case ownedByCurrentProcess = "owned_by_current_process"
    case unowned = "unowned"
}

public enum VoiceSessionRecoveryDecision: String, Codable, Sendable, Equatable {
    case activeAndHealthy = "active_and_healthy"
    case blockedAwaitingResume = "blocked_awaiting_resume"
    case staleOrOrphaned = "stale_or_orphaned"
    case commitDeferred = "commit_deferred"
    case terminalCleanup = "terminal_cleanup"
}

public enum VoiceRouteChangeDisposition: String, Codable, Sendable, Equatable {
    case armHint = "arm_hint"
    case ignoreUnknown = "ignore_unknown"
}

public enum VoiceMicrophonePermissionStatus: String, Codable, Sendable, Equatable {
    case granted
    case denied
    case undetermined
}

public enum VoiceCaptureError: LocalizedError {
    case appGroupUnavailable
    case deviceIdentityUnavailable
    case microphonePermissionMissing
    case liveActivityUnavailable(String)
    case activeSessionUnavailable
    case noRecoverableAudio
    case captureTooShort
    case recorderFailed(String)
    case commitDeferred(String)

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "voice_app_group_unavailable"
        case .deviceIdentityUnavailable:
            return "voice_device_identity_unavailable"
        case .microphonePermissionMissing:
            return "voice_microphone_permission_missing"
        case let .liveActivityUnavailable(reason):
            return "voice_live_activity_unavailable:\(reason)"
        case .activeSessionUnavailable:
            return "voice_active_session_unavailable"
        case .noRecoverableAudio:
            return "voice_no_recoverable_audio"
        case .captureTooShort:
            return "voice_capture_too_short"
        case let .recorderFailed(reason):
            return "voice_recorder_failed:\(reason)"
        case let .commitDeferred(reason):
            return "voice_commit_deferred:\(reason)"
        }
    }
}

public extension CaptureJSONValue {
    static func fromJSONObject(_ value: Any) -> CaptureJSONValue? {
        switch value {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            if value.doubleValue.rounded(.towardZero) == value.doubleValue {
                return .integer(value.int64Value)
            }
            return .number(value.doubleValue)
        case let value as [String: Any]:
            let mapped = value.reduce(into: [String: CaptureJSONValue]()) { partialResult, entry in
                if let converted = fromJSONObject(entry.value) {
                    partialResult[entry.key] = converted
                }
            }
            return .object(mapped)
        case let value as [Any]:
            return .array(value.compactMap { fromJSONObject($0) })
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }

    func toJSONObject() -> Any {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .integer(value):
            return value
        case let .bool(value):
            return value
        case let .object(value):
            return value.mapValues { $0.toJSONObject() }
        case let .array(value):
            return value.map { $0.toJSONObject() }
        case .null:
            return NSNull()
        }
    }
}

public typealias VoiceOperationGeneration = UInt64

public enum VoiceRouteChangeReason: String, Codable, Sendable, Equatable {
    case newDeviceAvailable = "new_device_available"
    case oldDeviceUnavailable = "old_device_unavailable"
    case override = "override"
    case categoryChange = "category_change"
    case routeConfigurationChange = "route_configuration_change"
    case noSuitableRouteForCategory = "no_suitable_route_for_category"
    case wakeFromSleep = "wake_from_sleep"
    case unknown = "unknown"
}

public enum VoiceInterruptionReason: String, Codable, Sendable, Equatable {
    case system
    case appWasSuspended = "app_was_suspended"
    case builtInMicMuted = "built_in_mic_muted"
    case unknown
}

public enum VoiceBlockedReason: String, Codable, Sendable, Equatable {
    case interruption
    case appWasSuspended = "app_was_suspended"
    case builtInMicMuted = "built_in_mic_muted"
    case routeLoss = "route_loss"
    case noSuitableRoute = "no_suitable_route"
    case audioSessionUnavailable = "audio_session_unavailable"
}

public struct VoiceRouteChangeObservation: Codable, Sendable, Equatable {
    public var reason: VoiceRouteChangeReason
    public var inputRouteChanged: Bool?
    public var previousInputUID: String? = nil
    public var currentInputUID: String? = nil

    public init(
        reason: VoiceRouteChangeReason,
        inputRouteChanged: Bool? = nil,
        previousInputUID: String? = nil,
        currentInputUID: String? = nil
    ) {
        self.reason = reason
        self.inputRouteChanged = inputRouteChanged
        self.previousInputUID = previousInputUID
        self.currentInputUID = currentInputUID
    }
}

public enum VoiceRetryClass: String, Codable, Sendable, Equatable {
    case selfHealing = "self_healing"
    case externalBlocker = "external_blocker"
    case deferredCommit = "deferred_commit"
}

public struct VoiceStartPrerequisites: Sendable, Equatable {
    public var bootstrapReady: Bool
    public var microphonePermissionGranted: Bool
    public var liveActivityEnabled: Bool

    public init(
        bootstrapReady: Bool,
        microphonePermissionGranted: Bool,
        liveActivityEnabled: Bool
    ) {
        self.bootstrapReady = bootstrapReady
        self.microphonePermissionGranted = microphonePermissionGranted
        self.liveActivityEnabled = liveActivityEnabled
    }
}

public enum VoiceStartAdmissibilityDecision: Sendable {
    case allow
    case deny(VoiceCaptureError)
}

public struct VoiceLivenessObservation: Sendable, Equatable {
    public var observedAt: Date
    public var startedAt: Date?
    public var lastProgressAt: Date?
    public var fileBytes: Int64
    public var recorderTime: TimeInterval
    public var previousFileBytes: Int64
    public var previousRecorderTime: TimeInterval

    public var hadProgress: Bool {
        recorderTime > previousRecorderTime || fileBytes > previousFileBytes
    }

    public init(
        observedAt: Date,
        startedAt: Date? = nil,
        lastProgressAt: Date? = nil,
        fileBytes: Int64,
        recorderTime: TimeInterval,
        previousFileBytes: Int64,
        previousRecorderTime: TimeInterval
    ) {
        self.observedAt = observedAt
        self.startedAt = startedAt
        self.lastProgressAt = lastProgressAt
        self.fileBytes = fileBytes
        self.recorderTime = recorderTime
        self.previousFileBytes = previousFileBytes
        self.previousRecorderTime = previousRecorderTime
    }
}

public enum VoiceLivenessVerdict: String, Sendable, Equatable {
    case noChange = "no_change"
    case confirmedLive = "confirmed_live"
    case suspectedStall = "suspected_stall"
    case hardStall = "hard_stall"
    case startupTimeout = "startup_timeout"
}

public enum VoiceRuntimeHintKind: String, Sendable, Equatable {
    case routeChange = "route_change"
    case configurationChange = "configuration_change"
}

public struct VoiceRuntimeHint: Sendable, Equatable {
    public var kind: VoiceRuntimeHintKind
    public var observedAt: Date
    public var routeReason: VoiceRouteChangeReason?

    public init(
        kind: VoiceRuntimeHintKind,
        observedAt: Date,
        routeReason: VoiceRouteChangeReason? = nil
    ) {
        self.kind = kind
        self.observedAt = observedAt
        self.routeReason = routeReason
    }
}

public enum VoiceRecoveryMode: String, Sendable, Equatable {
    case nominalInputFormatChange = "nominal_input_format_change"
}

public struct VoiceDestructiveProof: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case userStop = "user_stop"
        case recoveryClassification = "recovery_classification"
        case recoveryCommit = "recovery_commit"
        case interruption = "interruption"
        case stallRecovery = "stall_recovery"
        case routeChange = "route_change"
        case startupTimeout = "startup_timeout"
        case terminalCleanup = "terminal_cleanup"
        case startFailure = "start_failure"
    }

    public var reason: Reason
    public var sessionID: String
    public var generation: VoiceOperationGeneration?
    public var ownership: VoiceSessionOwnership?
    public var isFresh: Bool?
    public var recoveryDecision: VoiceSessionRecoveryDecision?

    public init(
        reason: Reason,
        sessionID: String,
        generation: VoiceOperationGeneration? = nil,
        ownership: VoiceSessionOwnership? = nil,
        isFresh: Bool? = nil,
        recoveryDecision: VoiceSessionRecoveryDecision? = nil
    ) {
        self.reason = reason
        self.sessionID = sessionID
        self.generation = generation
        self.ownership = ownership
        self.isFresh = isFresh
        self.recoveryDecision = recoveryDecision
    }
}

public struct VoicePendingToggleRequest: Sendable, Equatable {
    public var requestID: UUID
    public var sourceSurface: String
    public var reason: String
    public var requestedAt: Date
    public var reservedSessionID: String
    public var reservedCaptureID: String

    public init(
        requestID: UUID,
        sourceSurface: String,
        reason: String,
        requestedAt: Date,
        reservedSessionID: String,
        reservedCaptureID: String
    ) {
        self.requestID = requestID
        self.sourceSurface = sourceSurface
        self.reason = reason
        self.requestedAt = requestedAt
        self.reservedSessionID = reservedSessionID
        self.reservedCaptureID = reservedCaptureID
    }
}

public struct VoiceRecoveryObservation: Sendable, Equatable {
    public var session: VoiceSessionSnapshot
    public var ownership: VoiceSessionOwnership
    public var observedAt: Date
    public var outboxCommitted: Bool

    public init(
        session: VoiceSessionSnapshot,
        ownership: VoiceSessionOwnership,
        observedAt: Date,
        outboxCommitted: Bool
    ) {
        self.session = session
        self.ownership = ownership
        self.observedAt = observedAt
        self.outboxCommitted = outboxCommitted
    }
}

public enum VoicePendingSealContinuation: Sendable, Equatable {
    case recover(reason: VoiceSegmentSealReason)
    case finalize(reason: VoiceSegmentSealReason, proof: VoiceDestructiveProof)
}

public struct VoiceKernelManagedSession: Sendable, Equatable {
    public var snapshot: VoiceSessionSnapshot
    public var generation: VoiceOperationGeneration
    public var mixWithOthers: Bool
    public var toggleRequestIDs: [UUID]
    public var pendingSealContinuation: VoicePendingSealContinuation? = nil
    public var blockedRecoveryReason: VoiceSegmentSealReason? = nil
    public var blockedRecoveryRetryClass: VoiceRetryClass? = nil
    public var recoveryRetryCount: Int = 0
    public var recentHint: VoiceRuntimeHint? = nil
    public var recoveryMode: VoiceRecoveryMode? = nil

    public init(
        snapshot: VoiceSessionSnapshot,
        generation: VoiceOperationGeneration,
        mixWithOthers: Bool,
        toggleRequestIDs: [UUID],
        pendingSealContinuation: VoicePendingSealContinuation? = nil,
        blockedRecoveryReason: VoiceSegmentSealReason? = nil,
        blockedRecoveryRetryClass: VoiceRetryClass? = nil,
        recoveryRetryCount: Int = 0,
        recentHint: VoiceRuntimeHint? = nil,
        recoveryMode: VoiceRecoveryMode? = nil
    ) {
        self.snapshot = snapshot
        self.generation = generation
        self.mixWithOthers = mixWithOthers
        self.toggleRequestIDs = toggleRequestIDs
        self.pendingSealContinuation = pendingSealContinuation
        self.blockedRecoveryReason = blockedRecoveryReason
        self.blockedRecoveryRetryClass = blockedRecoveryRetryClass
        self.recoveryRetryCount = recoveryRetryCount
        self.recentHint = recentHint
        self.recoveryMode = recoveryMode
    }
}

public struct VoiceKernelState: Sendable, Equatable {
    public var current: VoiceKernelManagedSession?
    public var nextGeneration: VoiceOperationGeneration = 1
    public var recoveryAttempts: [Date] = []

    public init(
        current: VoiceKernelManagedSession? = nil,
        nextGeneration: VoiceOperationGeneration = 1,
        recoveryAttempts: [Date] = []
    ) {
        self.current = current
        self.nextGeneration = nextGeneration
        self.recoveryAttempts = recoveryAttempts
    }
}

public enum VoiceKernelEvent: Sendable {
    case toggleRequested(VoicePendingToggleRequest)
    case recoveryScanRequested(trigger: VoiceRecoveryTrigger)
    case recoveryScanCompleted(
        trigger: VoiceRecoveryTrigger,
        request: VoicePendingToggleRequest?,
        sessions: [VoiceRecoveryObservation],
        quarantinedCorruptBundleCount: Int
    )
    case startPrerequisitesObserved(request: VoicePendingToggleRequest, prerequisites: VoiceStartPrerequisites)
    case startSucceeded(generation: VoiceOperationGeneration, session: VoiceSessionSnapshot)
    case startFailed(generation: VoiceOperationGeneration, error: VoiceCaptureError)
    case livenessObserved(generation: VoiceOperationGeneration, session: VoiceSessionSnapshot, observation: VoiceLivenessObservation)
    case routeChanged(generation: VoiceOperationGeneration, observation: VoiceRouteChangeObservation, observedAt: Date)
    case configurationChanged(generation: VoiceOperationGeneration, observedAt: Date)
    case interruptionBegan(reason: VoiceInterruptionReason, observedAt: Date)
    case blockedClearObserved(source: String, observedAt: Date)
    case blockedDeadlineObservedExpired(observedAt: Date)
    case mediaServicesWereReset(observedAt: Date)
    case unexpectedRecorderStop(generation: VoiceOperationGeneration, reason: String, observedAt: Date)
    case segmentSealed(generation: VoiceOperationGeneration, session: VoiceSessionSnapshot)
    case segmentSealFailed(generation: VoiceOperationGeneration, reason: VoiceSegmentSealReason, error: VoiceCaptureError)
    case recoverySucceeded(generation: VoiceOperationGeneration, session: VoiceSessionSnapshot)
    case recoveryBlocked(
        generation: VoiceOperationGeneration,
        reason: VoiceSegmentSealReason,
        retryClass: VoiceRetryClass,
        error: VoiceCaptureError
    )
    case recoveryFailed(generation: VoiceOperationGeneration, reason: VoiceSegmentSealReason, error: VoiceCaptureError)
    case recoveryRetryRequested(generation: VoiceOperationGeneration)
    case operationFinished(generation: VoiceOperationGeneration, result: VoiceToggleResult, resultingSession: VoiceSessionSnapshot?)
}

public enum VoiceKernelEffect: Sendable {
    case scanActiveSessions(trigger: VoiceRecoveryTrigger, request: VoicePendingToggleRequest?)
    case observeStartPrerequisites(VoicePendingToggleRequest)
    case startReservedSession(session: VoiceSessionSnapshot, generation: VoiceOperationGeneration, mixWithOthers: Bool)
    case persistCurrentSession(
        generation: VoiceOperationGeneration,
        session: VoiceSessionSnapshot,
        previousPhase: VoiceCapturePhase,
        reason: String
    )
    case sealCurrentSegment(generation: VoiceOperationGeneration, reason: VoiceSegmentSealReason)
    case scheduleRecoveryRetry(generation: VoiceOperationGeneration, after: Duration)
    case finalizeCurrentSession(generation: VoiceOperationGeneration, reason: VoiceSegmentSealReason, proof: VoiceDestructiveProof)
    case recoverCurrentSession(generation: VoiceOperationGeneration, reason: VoiceSegmentSealReason)
    case commitRecoveredSession(session: VoiceSessionSnapshot, generation: VoiceOperationGeneration, proof: VoiceDestructiveProof)
    case removeRecoveredSession(session: VoiceSessionSnapshot, proof: VoiceDestructiveProof)
    case resolveToggleResult(requestIDs: [UUID], result: VoiceToggleResult)
    case failToggle(requestIDs: [UUID], error: VoiceCaptureError)
}

public struct VoiceCoordinatorKernel: Sendable {
    public let constants: VoiceCaptureConstants

    public init(constants: VoiceCaptureConstants) {
        self.constants = constants
    }

    public func step(state: inout VoiceKernelState, event: VoiceKernelEvent) -> [VoiceKernelEffect] {
        switch event {
        case let .toggleRequested(request):
            return stepToggleRequested(state: &state, request: request)
        case let .recoveryScanRequested(trigger):
            return [.scanActiveSessions(trigger: trigger, request: nil)]
        case let .recoveryScanCompleted(trigger, request, sessions, _):
            return stepRecoveryScanCompleted(state: &state, trigger: trigger, request: request, sessions: sessions)
        case let .startPrerequisitesObserved(request, prerequisites):
            return stepStartPrerequisitesObserved(state: &state, request: request, prerequisites: prerequisites)
        case let .startSucceeded(generation, session):
            return stepStartSucceeded(state: &state, generation: generation, session: session)
        case let .startFailed(generation, error):
            return stepStartFailed(state: &state, generation: generation, error: error)
        case let .livenessObserved(generation, session, observation):
            return stepLivenessObserved(state: &state, generation: generation, session: session, observation: observation)
        case let .routeChanged(generation, observation, observedAt):
            return stepRouteChanged(state: &state, generation: generation, observation: observation, observedAt: observedAt)
        case let .configurationChanged(generation, observedAt):
            return stepConfigurationChanged(state: &state, generation: generation, observedAt: observedAt)
        case let .interruptionBegan(reason, observedAt):
            return stepInterruptionBegan(state: &state, reason: reason, observedAt: observedAt)
        case let .blockedClearObserved(source, observedAt):
            return stepBlockedClearObserved(state: &state, source: source, observedAt: observedAt)
        case let .blockedDeadlineObservedExpired(observedAt):
            return stepBlockedDeadlineObservedExpired(state: &state, observedAt: observedAt)
        case let .mediaServicesWereReset(observedAt):
            return stepMediaServicesWereReset(state: &state, observedAt: observedAt)
        case let .unexpectedRecorderStop(generation, _, observedAt):
            return stepUnexpectedRecorderStop(state: &state, generation: generation, observedAt: observedAt)
        case let .segmentSealed(generation, session):
            return stepSegmentSealed(state: &state, generation: generation, session: session)
        case let .segmentSealFailed(generation, reason, _):
            return stepSegmentSealFailed(state: &state, generation: generation, reason: reason)
        case let .recoverySucceeded(generation, session):
            return stepRecoverySucceeded(state: &state, generation: generation, session: session)
        case let .recoveryBlocked(generation, reason, retryClass, _):
            return stepRecoveryBlocked(state: &state, generation: generation, reason: reason, retryClass: retryClass)
        case let .recoveryFailed(generation, reason, _):
            return stepRecoveryFailed(state: &state, generation: generation, reason: reason)
        case let .recoveryRetryRequested(generation):
            return stepRecoveryRetryRequested(state: &state, generation: generation)
        case let .operationFinished(generation, result, resultingSession):
            return stepOperationFinished(state: &state, generation: generation, result: result, resultingSession: resultingSession)
        }
    }

    public func classifySessionRecovery(
        session: VoiceSessionSnapshot,
        trigger: VoiceRecoveryTrigger,
        ownership: VoiceSessionOwnership,
        now: Date,
        outboxCommitted: Bool
    ) -> VoiceSessionRecoveryDecision {
        _ = trigger
        if session.phase.isTerminal {
            return .terminalCleanup
        }
        if outboxCommitted {
            return .terminalCleanup
        }
        if session.finalBlobRelpath != nil || session.phase == .commitDeferred {
            return .commitDeferred
        }
        if session.phase == .blocked {
            return .blockedAwaitingResume
        }
        if ownership == .ownedByCurrentProcess {
            return .activeAndHealthy
        }
        return .staleOrOrphaned
    }

    public func classifyRouteChange(_ observation: VoiceRouteChangeObservation) -> VoiceRouteChangeDisposition {
        switch observation.reason {
        case .newDeviceAvailable,
                .oldDeviceUnavailable,
                .override,
                .categoryChange,
                .routeConfigurationChange,
                .noSuitableRouteForCategory,
                .wakeFromSleep:
            return .armHint
        case .unknown:
            return .ignoreUnknown
        }
    }

    public func classifyStartAdmissibility(_ prerequisites: VoiceStartPrerequisites) -> VoiceStartAdmissibilityDecision {
        guard prerequisites.bootstrapReady else {
            return .deny(.appGroupUnavailable)
        }
        guard prerequisites.microphonePermissionGranted else {
            return .deny(.microphonePermissionMissing)
        }
        guard prerequisites.liveActivityEnabled else {
            return .deny(.liveActivityUnavailable("activities_disabled"))
        }
        return .allow
    }

    public func classifyLiveness(
        session: VoiceSessionSnapshot,
        observation: VoiceLivenessObservation
    ) -> VoiceLivenessVerdict {
        if observation.hadProgress {
            return .confirmedLive
        }

        if observation.lastProgressAt == nil,
           let startedAt = observation.startedAt,
           observation.observedAt.timeIntervalSince(startedAt) >= constants.startupDeadline.timeInterval
        {
            return .startupTimeout
        }

        guard let lastProgressAt = observation.lastProgressAt else {
            return .noChange
        }

        let silence = observation.observedAt.timeIntervalSince(lastProgressAt)
        if silence >= constants.hardStallAfter.timeInterval {
            return .hardStall
        }
        if silence >= constants.suspectedStallAfter.timeInterval,
           session.phase == .recordingLive
        {
            return .suspectedStall
        }
        return .noChange
    }

    func isSessionFresh(_ session: VoiceSessionSnapshot, now: Date) -> Bool {
        now.timeIntervalSince(session.heartbeatAt) < constants.heartbeatStaleInterval.timeInterval
    }

    private func stepToggleRequested(
        state: inout VoiceKernelState,
        request: VoicePendingToggleRequest
    ) -> [VoiceKernelEffect] {
        if var current = state.current {
            switch current.snapshot.phase {
            case .commitDeferred:
                return [.resolveToggleResult(
                    requestIDs: [request.requestID],
                    result: VoiceToggleResult(
                        action: .deferred(captureID: current.snapshot.captureID),
                        sessionID: current.snapshot.sessionID
                    )
                )]
            case .blocked:
                if let blockedAutoFinalizeAt = current.snapshot.blockedAutoFinalizeAt,
                   blockedDeadlineReached(blockedAutoFinalizeAt, observed: request.requestedAt)
                {
                    let generation = nextGeneration(&state)
                    current.generation = generation
                    current.toggleRequestIDs.append(request.requestID)
                    state.current = current
                    return stepBlockedDeadlineObservedExpired(state: &state, observedAt: request.requestedAt)
                }
                guard current.snapshot.blockerClearedAt != nil else {
                    return [.resolveToggleResult(
                        requestIDs: [request.requestID],
                        result: VoiceToggleResult(
                            action: .blocked(captureID: current.snapshot.captureID),
                            sessionID: current.snapshot.sessionID
                        )
                    )]
                }
                let generation = nextGeneration(&state)
                current.generation = generation
                current.toggleRequestIDs.append(request.requestID)
                state.current = current
                return beginResume(
                    state: &state,
                    generation: generation,
                    observedAt: request.requestedAt
                )
            case .stopping, .finalizing:
                current.toggleRequestIDs.append(request.requestID)
                state.current = current
                return []
            default:
                if current.snapshot.phase.isActiveRecording {
                    let previousPhase = current.snapshot.phase
                    let generation = nextGeneration(&state)
                    current.generation = generation
                    current.toggleRequestIDs.append(request.requestID)
                    current.snapshot.phase = .stopping
                    current.snapshot.updatedAt = request.requestedAt
                    current.snapshot.heartbeatAt = request.requestedAt
                    current.pendingSealContinuation = .finalize(
                        reason: .userStop,
                        proof: VoiceDestructiveProof(
                            reason: .userStop,
                            sessionID: current.snapshot.sessionID,
                            generation: generation,
                            ownership: .ownedByCurrentProcess,
                            isFresh: true,
                            recoveryDecision: nil
                        )
                    )
                    state.current = current
                    return [
                        .persistCurrentSession(
                            generation: generation,
                            session: current.snapshot,
                            previousPhase: previousPhase,
                            reason: VoiceSegmentSealReason.userStop.rawValue
                        ),
                        .sealCurrentSegment(generation: generation, reason: .userStop),
                    ]
                }
            }
        }
        return [.scanActiveSessions(trigger: .toggle, request: request)]
    }

    private func stepRecoveryScanCompleted(
        state: inout VoiceKernelState,
        trigger: VoiceRecoveryTrigger,
        request: VoicePendingToggleRequest?,
        sessions: [VoiceRecoveryObservation]
    ) -> [VoiceKernelEffect] {
        var effects: [VoiceKernelEffect] = []
        var handledRequest = false

        for observation in sessions {
            let decision = classifySessionRecovery(
                session: observation.session,
                trigger: trigger,
                ownership: observation.ownership,
                now: observation.observedAt,
                outboxCommitted: observation.outboxCommitted
            )

            switch decision {
            case .activeAndHealthy:
                continue
            case .terminalCleanup:
                effects.append(.removeRecoveredSession(
                    session: observation.session,
                    proof: VoiceDestructiveProof(
                        reason: .terminalCleanup,
                        sessionID: observation.session.sessionID,
                        generation: nil,
                        ownership: observation.ownership,
                        isFresh: isSessionFresh(observation.session, now: observation.observedAt),
                        recoveryDecision: decision
                    )
                ))
            case .commitDeferred:
                let generation = nextGeneration(&state)
                state.current = VoiceKernelManagedSession(
                    snapshot: observation.session,
                    generation: generation,
                    mixWithOthers: false,
                    toggleRequestIDs: request.map { [$0.requestID] } ?? []
                )
                effects.append(.commitRecoveredSession(
                    session: observation.session,
                    generation: generation,
                    proof: VoiceDestructiveProof(
                        reason: .recoveryCommit,
                        sessionID: observation.session.sessionID,
                        generation: generation,
                        ownership: observation.ownership,
                        isFresh: isSessionFresh(observation.session, now: observation.observedAt),
                        recoveryDecision: decision
                    )
                ))
                handledRequest = handledRequest || request != nil
            case .blockedAwaitingResume:
                let generation = nextGeneration(&state)
                state.current = VoiceKernelManagedSession(
                    snapshot: observation.session,
                    generation: generation,
                    mixWithOthers: false,
                    toggleRequestIDs: request.map { [$0.requestID] } ?? []
                )
                if let blockedAutoFinalizeAt = observation.session.blockedAutoFinalizeAt,
                   blockedDeadlineReached(blockedAutoFinalizeAt, observed: observation.observedAt)
                {
                    handledRequest = handledRequest || request != nil
                    effects.append(contentsOf: stepBlockedDeadlineObservedExpired(
                        state: &state,
                        observedAt: observation.observedAt
                    ))
                    continue
                }
                if let request {
                    handledRequest = true
                    if observation.session.blockerClearedAt != nil {
                        effects.append(contentsOf: beginResume(
                            state: &state,
                            generation: generation,
                            observedAt: request.requestedAt
                        ))
                    } else {
                        effects.append(.resolveToggleResult(
                            requestIDs: [request.requestID],
                            result: VoiceToggleResult(
                                action: .blocked(captureID: observation.session.captureID),
                                sessionID: observation.session.sessionID
                            )
                        ))
                    }
                }
            case .staleOrOrphaned:
                let generation = nextGeneration(&state)
                let proof = VoiceDestructiveProof(
                    reason: .recoveryClassification,
                    sessionID: observation.session.sessionID,
                    generation: generation,
                    ownership: observation.ownership,
                    isFresh: isSessionFresh(observation.session, now: observation.observedAt),
                    recoveryDecision: decision
                )
                var updated = observation.session
                let previousPhase = updated.phase
                if updated.phase != .finalizing {
                    updated.phase = .finalizing
                    updated.updatedAt = observation.observedAt
                    updated.heartbeatAt = observation.observedAt
                }
                state.current = VoiceKernelManagedSession(
                    snapshot: updated,
                    generation: generation,
                    mixWithOthers: false,
                    toggleRequestIDs: request.map { [$0.requestID] } ?? [],
                    pendingSealContinuation: .finalize(reason: .recoveryFinalize, proof: proof)
                )
                if previousPhase != updated.phase {
                    effects.append(.persistCurrentSession(
                        generation: generation,
                        session: updated,
                        previousPhase: previousPhase,
                        reason: VoiceSegmentSealReason.recoveryFinalize.rawValue
                    ))
                }
                effects.append(.sealCurrentSegment(generation: generation, reason: .recoveryFinalize))
                handledRequest = handledRequest || request != nil
            }
        }

        if !handledRequest, let request {
            effects.append(.observeStartPrerequisites(request))
        }
        return effects
    }

    private func stepStartPrerequisitesObserved(
        state: inout VoiceKernelState,
        request: VoicePendingToggleRequest,
        prerequisites: VoiceStartPrerequisites
    ) -> [VoiceKernelEffect] {
        if var current = state.current {
            switch current.snapshot.phase {
            case .arming, .starting:
                if !current.toggleRequestIDs.contains(request.requestID) {
                    current.toggleRequestIDs.append(request.requestID)
                    state.current = current
                }
                return []
            case .recordingLive:
                return [.resolveToggleResult(
                    requestIDs: [request.requestID],
                    result: VoiceToggleResult(
                        action: .started(captureID: current.snapshot.captureID),
                        sessionID: current.snapshot.sessionID
                    )
                )]
            case .recordingUnverified, .suspectedStall, .resuming, .recovering:
                if !current.toggleRequestIDs.contains(request.requestID) {
                    current.toggleRequestIDs.append(request.requestID)
                    state.current = current
                }
                return []
            case .stopping, .finalizing:
                return [.resolveToggleResult(
                    requestIDs: [request.requestID],
                    result: VoiceToggleResult(
                        action: .stopping(captureID: current.snapshot.captureID),
                        sessionID: current.snapshot.sessionID
                    )
                )]
            case .commitDeferred:
                return [.resolveToggleResult(
                    requestIDs: [request.requestID],
                    result: VoiceToggleResult(
                        action: .deferred(captureID: current.snapshot.captureID),
                        sessionID: current.snapshot.sessionID
                    )
                )]
            case .blocked:
                return [.resolveToggleResult(
                    requestIDs: [request.requestID],
                    result: VoiceToggleResult(
                        action: .blocked(captureID: current.snapshot.captureID),
                        sessionID: current.snapshot.sessionID
                    )
                )]
            case .committed, .lost:
                return []
            }
        }

        switch classifyStartAdmissibility(prerequisites) {
        case let .deny(error):
            return [.failToggle(requestIDs: [request.requestID], error: error)]
        case .allow:
            let generation = nextGeneration(&state)
            let session = VoiceSessionSnapshot(
                sessionID: request.reservedSessionID,
                captureID: request.reservedCaptureID,
                phase: .arming,
                sourceSurface: request.sourceSurface,
                createdAt: request.requestedAt,
                updatedAt: request.requestedAt,
                heartbeatAt: request.requestedAt,
                lastProgressAt: nil,
                failureReason: nil,
                recoveryCount: 0,
                preferredInputUID: nil,
                audioFile: nil,
                finalBlobRelpath: nil,
                pendingCommitReason: nil,
                blockedReason: nil,
                blockerClearedAt: nil,
                blockedAutoFinalizeAt: nil,
                context: [:]
            )
            state.current = VoiceKernelManagedSession(
                snapshot: session,
                generation: generation,
                mixWithOthers: request.reason == "app_intent",
                toggleRequestIDs: [request.requestID],
                pendingSealContinuation: nil
            )
            return [.startReservedSession(session: session, generation: generation, mixWithOthers: request.reason == "app_intent")]
        }
    }

    private func stepStartSucceeded(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        session: VoiceSessionSnapshot
    ) -> [VoiceKernelEffect] {
        guard var current = state.current, current.generation == generation else {
            return []
        }
        current.snapshot = session
        state.current = current
        return []
    }

    private func stepStartFailed(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        error: VoiceCaptureError
    ) -> [VoiceKernelEffect] {
        guard let current = state.current, current.generation == generation else {
            return []
        }
        state.current = nil
        return [.failToggle(requestIDs: current.toggleRequestIDs, error: error)]
    }

    private func stepLivenessObserved(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        session: VoiceSessionSnapshot,
        observation: VoiceLivenessObservation
    ) -> [VoiceKernelEffect] {
        guard var current = state.current, current.generation == generation else {
            return []
        }
        switch current.snapshot.phase {
        case .recordingUnverified, .recordingLive, .suspectedStall:
            break
        case .arming, .starting, .blocked, .resuming, .recovering, .stopping, .finalizing, .commitDeferred, .committed, .lost:
            return []
        }
        current.snapshot = session
        if observation.hadProgress {
            current.recentHint = nil
        }
        state.current = current

        if shouldRetryNominalTransition(current: current, observation: observation) {
            if current.recoveryRetryCount >= recoveryRetryLimit(for: .selfHealing) {
                return stepHardStall(state: &state, session: session, observedAt: observation.observedAt)
            }
            let newGeneration = nextGeneration(&state)
            current.generation = newGeneration
            current.recoveryRetryCount += 1
            state.current = current
            return beginNominalTransition(
                state: &state,
                generation: newGeneration,
                observedAt: observation.observedAt
            )
        }

        if shouldBeginNominalTransition(current: current, observation: observation) {
            let newGeneration = nextGeneration(&state)
            current.generation = newGeneration
            state.current = current
            return beginNominalTransition(
                state: &state,
                generation: newGeneration,
                observedAt: observation.observedAt
            )
        }

        switch classifyLiveness(session: session, observation: observation) {
        case .noChange:
            return []
        case .confirmedLive:
            let previousPhase = session.phase
            var updated = session
            if session.phase != .recordingLive {
                updated.phase = .recordingLive
                updated.updatedAt = observation.observedAt
                updated.heartbeatAt = observation.observedAt
            }
            current.snapshot = updated
            let requestIDs = current.toggleRequestIDs
            current.toggleRequestIDs = []
            current.recentHint = nil
            current.recoveryMode = nil
            current.blockedRecoveryReason = nil
            current.blockedRecoveryRetryClass = nil
            current.recoveryRetryCount = 0
            state.current = current
            var effects: [VoiceKernelEffect] = []
            if session.phase != .recordingLive {
                effects.append(.persistCurrentSession(
                    generation: generation,
                    session: updated,
                    previousPhase: previousPhase,
                    reason: "liveness_confirmed"
                ))
            }
            if !requestIDs.isEmpty {
                effects.append(.resolveToggleResult(
                    requestIDs: requestIDs,
                    result: VoiceToggleResult(action: .started(captureID: updated.captureID), sessionID: updated.sessionID)
                ))
            }
            return effects
        case .suspectedStall:
            guard session.phase != .suspectedStall else {
                return []
            }
            let previousPhase = session.phase
            var updated = session
            updated.phase = .suspectedStall
            updated.updatedAt = observation.observedAt
            updated.heartbeatAt = observation.observedAt
            current.snapshot = updated
            state.current = current
            return [.persistCurrentSession(
                generation: generation,
                session: updated,
                previousPhase: previousPhase,
                reason: "stall_suspected"
            )]
        case .startupTimeout:
            let newGeneration = nextGeneration(&state)
            current.generation = newGeneration
            let previousPhase = current.snapshot.phase
            current.snapshot.phase = .finalizing
            current.snapshot.updatedAt = observation.observedAt
            current.snapshot.heartbeatAt = observation.observedAt
            current.recentHint = nil
            current.recoveryMode = nil
            current.pendingSealContinuation = .finalize(
                reason: .finalization,
                proof: VoiceDestructiveProof(
                    reason: .startupTimeout,
                    sessionID: session.sessionID,
                    generation: newGeneration,
                    ownership: .ownedByCurrentProcess,
                    isFresh: true,
                    recoveryDecision: nil
                )
            )
            state.current = current
            return [
                .persistCurrentSession(
                    generation: newGeneration,
                    session: current.snapshot,
                    previousPhase: previousPhase,
                    reason: VoiceSegmentSealReason.finalization.rawValue
                ),
                .sealCurrentSegment(generation: newGeneration, reason: .finalization),
            ]
        case .hardStall:
            return stepHardStall(state: &state, session: session, observedAt: observation.observedAt)
        }
    }

    private func stepHardStall(
        state: inout VoiceKernelState,
        session: VoiceSessionSnapshot,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        state.recoveryAttempts = state.recoveryAttempts.filter { observedAt.timeIntervalSince($0) < constants.recoveryWindow.timeInterval }
        state.recoveryAttempts.append(observedAt)

        let newGeneration = nextGeneration(&state)
        if var current = state.current {
            current.generation = newGeneration
            current.snapshot.phase = .finalizing
            current.snapshot.updatedAt = observedAt
            current.snapshot.heartbeatAt = observedAt
            current.recentHint = nil
            current.recoveryMode = nil
            current.pendingSealContinuation = .finalize(
                reason: .stallRecovery,
                proof: VoiceDestructiveProof(
                    reason: .stallRecovery,
                    sessionID: session.sessionID,
                    generation: newGeneration,
                    ownership: .ownedByCurrentProcess,
                    isFresh: true,
                    recoveryDecision: nil
                )
            )
            state.current = current
        }

        if state.recoveryAttempts.count > constants.maxRecoveriesInWindow {
            guard let current = state.current else {
                return []
            }
            return [
                .persistCurrentSession(
                    generation: newGeneration,
                    session: current.snapshot,
                    previousPhase: session.phase,
                    reason: VoiceSegmentSealReason.stallRecovery.rawValue
                ),
                .sealCurrentSegment(generation: newGeneration, reason: .stallRecovery),
            ]
        }
        return beginRecoveryAfterSeal(
            state: &state,
            generation: newGeneration,
            reason: .stallRecovery,
            observedAt: observedAt
        )
    }

    private func stepRouteChanged(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        observation: VoiceRouteChangeObservation,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current,
              current.generation == generation
        else {
            return []
        }
        switch current.snapshot.phase {
        case .recordingUnverified, .recordingLive, .suspectedStall:
            break
        case .arming, .starting, .blocked, .resuming, .recovering, .stopping, .finalizing, .commitDeferred, .committed, .lost:
            return []
        }
        switch classifyRouteChange(observation) {
        case .ignoreUnknown:
            return []
        case .armHint:
            current.recentHint = VoiceRuntimeHint(
                kind: .routeChange,
                observedAt: observedAt,
                routeReason: observation.reason
            )
            current.snapshot.preferredInputUID = observation.currentInputUID
            state.current = current
            return []
        }
    }

    private func stepConfigurationChanged(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current,
              current.generation == generation
        else {
            return []
        }
        switch current.snapshot.phase {
        case .recordingUnverified, .recordingLive, .suspectedStall:
            break
        case .arming, .starting, .blocked, .resuming, .recovering, .stopping, .finalizing, .commitDeferred, .committed, .lost:
            return []
        }
        current.recentHint = VoiceRuntimeHint(
            kind: .configurationChange,
            observedAt: observedAt,
            routeReason: nil
        )
        state.current = current
        return []
    }

    private func stepInterruptionBegan(
        state: inout VoiceKernelState,
        reason: VoiceInterruptionReason,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current,
              current.snapshot.phase.isActiveRecording
        else {
            return []
        }
        switch current.snapshot.phase {
        case .recordingUnverified, .recordingLive, .suspectedStall:
            break
        case .arming, .starting, .blocked, .resuming, .recovering, .stopping, .finalizing, .commitDeferred, .committed, .lost:
            return []
        }
        let newGeneration = nextGeneration(&state)
        current.generation = newGeneration
        let previousPhase = current.snapshot.phase
        current.snapshot.phase = .blocked
        current.snapshot.blockedReason = blockedReason(for: reason)
        current.snapshot.blockerClearedAt = nil
        current.snapshot.blockedAutoFinalizeAt = nil
        current.snapshot.updatedAt = observedAt
        current.snapshot.heartbeatAt = observedAt
        current.pendingSealContinuation = nil
        current.recentHint = nil
        current.recoveryMode = nil
        state.current = current
        return [
            .persistCurrentSession(
                generation: newGeneration,
                session: current.snapshot,
                previousPhase: previousPhase,
                reason: VoiceCapturePhase.blocked.rawValue
            ),
            .sealCurrentSegment(generation: newGeneration, reason: .interruption),
        ]
    }

    /// Whether the blocked auto-finalize deadline has been reached as of `observed`.
    ///
    /// Requirement: a partial capture left blocked must converge within its bounded window
    /// (INVARIANTS §9). Failure mode: the deadline is stamped wall-clock as (clearedAt + interval),
    /// so a BACKWARD clock correction (NTP step / manual change) after stamping makes a plain
    /// `observed >= deadline` never become true — the capture wedges in `.blocked` until the clock
    /// organically passes a now-stale future deadline. Evidence: the kernel sees only event
    /// wall-clock `observedAt`, never a monotonic clock. So an `observed` that has fallen before the
    /// clear instant (deadline - interval) is also treated as reached — converging is the safe
    /// response to a backward jump. A few seconds of slack absorbs benign sub-second NTP slew, so a
    /// tiny adjustment can't finalize a still-resumable session early; only a real backward step trips it.
    private func blockedDeadlineReached(_ deadline: Date, observed: Date) -> Bool {
        if observed >= deadline { return true }
        let clearedAt = deadline.addingTimeInterval(-constants.blockedAutoFinalizeInterval.timeInterval)
        let backwardSkewSlack: TimeInterval = 5
        return observed < clearedAt.addingTimeInterval(-backwardSkewSlack)
    }

    private func stepBlockedClearObserved(
        state: inout VoiceKernelState,
        source: String,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current,
              current.snapshot.phase == .blocked
        else {
            return []
        }
        if let blockedAutoFinalizeAt = current.snapshot.blockedAutoFinalizeAt,
           blockedDeadlineReached(blockedAutoFinalizeAt, observed: observedAt)
        {
            return stepBlockedDeadlineObservedExpired(state: &state, observedAt: observedAt)
        }
        guard current.snapshot.blockerClearedAt == nil else {
            return []
        }
        let previousPhase = current.snapshot.phase
        current.snapshot.blockerClearedAt = observedAt
        current.snapshot.blockedAutoFinalizeAt = observedAt.addingTimeInterval(constants.blockedAutoFinalizeInterval.timeInterval)
        current.snapshot.updatedAt = observedAt
        current.snapshot.heartbeatAt = observedAt
        state.current = current
        return [.persistCurrentSession(
            generation: current.generation,
            session: current.snapshot,
            previousPhase: previousPhase,
            reason: "blocked_cleared_\(source)"
        )]
    }

    private func stepBlockedDeadlineObservedExpired(
        state: inout VoiceKernelState,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current,
              current.snapshot.phase == .blocked,
              let blockedAutoFinalizeAt = current.snapshot.blockedAutoFinalizeAt,
              blockedDeadlineReached(blockedAutoFinalizeAt, observed: observedAt)
        else {
            return []
        }
        let generation = current.generation
        let previousPhase = current.snapshot.phase
        current.snapshot.phase = .finalizing
        current.snapshot.updatedAt = observedAt
        current.snapshot.heartbeatAt = observedAt
        current.snapshot.blockedReason = nil
        current.snapshot.blockerClearedAt = nil
        current.snapshot.blockedAutoFinalizeAt = nil
        state.current = current
        return [
            .persistCurrentSession(
                generation: generation,
                session: current.snapshot,
                previousPhase: previousPhase,
                reason: "blocked_auto_finalize"
            ),
            .finalizeCurrentSession(
                generation: generation,
                reason: .recoveryFinalize,
                proof: blockedFinalizationProof(for: current.snapshot, generation: generation)
            ),
        ]
    }

    private func stepMediaServicesWereReset(
        state: inout VoiceKernelState,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current else {
            return []
        }
        switch current.snapshot.phase {
        case .recordingUnverified, .recordingLive, .suspectedStall:
            break
        case .arming, .starting, .blocked, .resuming, .recovering, .stopping, .finalizing, .commitDeferred, .committed, .lost:
            return []
        }
        let newGeneration = nextGeneration(&state)
        current.generation = newGeneration
        current.recentHint = nil
        current.recoveryMode = nil
        state.current = current
        return beginRecoveryAfterSeal(
            state: &state,
            generation: newGeneration,
            reason: .stallRecovery,
            observedAt: observedAt
        )
    }

    private func stepUnexpectedRecorderStop(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current,
              current.generation == generation
        else {
            return []
        }
        switch current.snapshot.phase {
        case .recordingUnverified, .recordingLive, .suspectedStall:
            break
        case .arming, .starting, .blocked, .resuming, .recovering, .stopping, .finalizing, .commitDeferred, .committed, .lost:
            return []
        }
        let newGeneration = nextGeneration(&state)
        current.generation = newGeneration
        state.current = current
        if current.recentHint != nil {
            return beginNominalTransition(
                state: &state,
                generation: newGeneration,
                observedAt: observedAt
            )
        }
        return beginRecoveryAfterSeal(
            state: &state,
            generation: newGeneration,
            reason: .stallRecovery,
            observedAt: observedAt
        )
    }

    private func stepSegmentSealed(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        session: VoiceSessionSnapshot
    ) -> [VoiceKernelEffect] {
        guard var current = state.current, current.generation == generation else {
            return []
        }
        let continuation = current.pendingSealContinuation
        current.snapshot = session
        current.pendingSealContinuation = nil
        state.current = current

        guard let continuation else {
            return []
        }
        switch continuation {
        case let .recover(reason):
            return [.recoverCurrentSession(generation: generation, reason: reason)]
        case let .finalize(reason, proof):
            return [.finalizeCurrentSession(generation: generation, reason: reason, proof: proof)]
        }
    }

    private func stepSegmentSealFailed(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        reason: VoiceSegmentSealReason
    ) -> [VoiceKernelEffect] {
        guard var current = state.current, current.generation == generation else {
            return []
        }
        let continuation = current.pendingSealContinuation
        current.pendingSealContinuation = nil
        state.current = current

        guard let continuation else {
            return []
        }

        switch continuation {
        case .recover:
            return stepRecoveryFailed(state: &state, generation: generation, reason: reason)
        case let .finalize(finalizeReason, proof):
            return [.finalizeCurrentSession(generation: generation, reason: finalizeReason, proof: proof)]
        }
    }

    private func stepRecoverySucceeded(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        session: VoiceSessionSnapshot
    ) -> [VoiceKernelEffect] {
        guard var current = state.current, current.generation == generation else {
            return []
        }
        current.snapshot = session
        current.snapshot.blockedReason = nil
        current.snapshot.blockerClearedAt = nil
        current.snapshot.blockedAutoFinalizeAt = nil
        current.blockedRecoveryReason = nil
        current.blockedRecoveryRetryClass = nil
        current.recoveryRetryCount = 0
        // Clear the recovery mode like every other recovery-terminal handler (e.g. the
        // confirmedLive path). Leaving it set after a successful nominal-input-format-change
        // recovery lets the next no-progress liveness sample satisfy shouldRetryNominalTransition
        // and fire a spurious extra recover/seal cycle (churn, possible double-seal) before real
        // progress. Converges either way, but the extra cycle is unnecessary work on the hot path.
        current.recoveryMode = nil
        state.current = current
        return []
    }

    private func stepRecoveryBlocked(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        reason: VoiceSegmentSealReason,
        retryClass: VoiceRetryClass
    ) -> [VoiceKernelEffect] {
        guard var current = state.current,
              current.generation == generation,
              current.snapshot.phase == .recovering || current.snapshot.phase == .resuming || current.recoveryMode == .nominalInputFormatChange
        else {
            return []
        }
        current.blockedRecoveryReason = reason
        current.blockedRecoveryRetryClass = retryClass
        current.recoveryRetryCount += 1
        state.current = current
        if retryClass == .externalBlocker, current.snapshot.phase == .recovering {
            let observedAt = current.snapshot.updatedAt
            current.snapshot.phase = .blocked
            current.snapshot.blockedReason = .audioSessionUnavailable
            current.snapshot.blockerClearedAt = nil
            current.snapshot.blockedAutoFinalizeAt = nil
            current.snapshot.updatedAt = observedAt
            current.snapshot.heartbeatAt = observedAt
            current.blockedRecoveryReason = nil
            current.blockedRecoveryRetryClass = nil
            current.recoveryRetryCount = 0
            state.current = current
            return [.persistCurrentSession(
                generation: generation,
                session: current.snapshot,
                previousPhase: .recovering,
                reason: "external_blocker_during_recovery"
            )]
        }
        if current.recoveryRetryCount > recoveryRetryLimit(for: retryClass) {
            return stepRecoveryFailed(state: &state, generation: generation, reason: reason)
        }
        return [.scheduleRecoveryRetry(
            generation: generation,
            after: recoveryRetryDelay(forAttempt: current.recoveryRetryCount, retryClass: retryClass)
        )]
    }

    private func stepRecoveryFailed(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        reason: VoiceSegmentSealReason
    ) -> [VoiceKernelEffect] {
        guard let current = state.current, current.generation == generation else {
            return []
        }
        return [.finalizeCurrentSession(
            generation: generation,
            reason: .recoveryFinalize,
            proof: VoiceDestructiveProof(
                reason: .stallRecovery,
                sessionID: current.snapshot.sessionID,
                generation: generation,
                ownership: .ownedByCurrentProcess,
                isFresh: true,
                recoveryDecision: nil
            )
        )]
    }

    private func stepRecoveryRetryRequested(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration
    ) -> [VoiceKernelEffect] {
        guard var current = state.current,
              current.generation == generation,
              current.snapshot.phase == .recovering || current.snapshot.phase == .resuming || current.recoveryMode == .nominalInputFormatChange,
              let reason = current.blockedRecoveryReason
        else {
            return []
        }
        current.blockedRecoveryReason = nil
        current.blockedRecoveryRetryClass = nil
        state.current = current
        return [.recoverCurrentSession(generation: generation, reason: reason)]
    }

    private func stepOperationFinished(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        result: VoiceToggleResult,
        resultingSession: VoiceSessionSnapshot?
    ) -> [VoiceKernelEffect] {
        guard let current = state.current, current.generation == generation else {
            return []
        }

        let requestIDs = current.toggleRequestIDs
        switch result.action {
        case .started:
            return []
        case .finalized, .lost:
            state.current = nil
        case .blocked, .deferred, .stopping:
            if var updated = state.current, let resultingSession {
                updated.snapshot = resultingSession
                updated.toggleRequestIDs = []
                updated.blockedRecoveryReason = nil
                updated.blockedRecoveryRetryClass = nil
                updated.recoveryRetryCount = 0
                state.current = updated
            }
        }

        guard !requestIDs.isEmpty else {
            return []
        }
        return [.resolveToggleResult(requestIDs: requestIDs, result: result)]
    }

    private func nextGeneration(_ state: inout VoiceKernelState) -> VoiceOperationGeneration {
        let generation = state.nextGeneration
        state.nextGeneration += 1
        return generation
    }

    private func shouldBeginNominalTransition(
        current: VoiceKernelManagedSession,
        observation: VoiceLivenessObservation
    ) -> Bool {
        guard current.recoveryMode == nil,
              current.snapshot.phase == .recordingUnverified || current.snapshot.phase == .recordingLive || current.snapshot.phase == .suspectedStall,
              !observation.hadProgress,
              let recentHint = current.recentHint
        else {
            return false
        }

        let silenceSinceHint = observation.observedAt.timeIntervalSince(recentHint.observedAt)
        guard silenceSinceHint >= constants.transitionalPollInterval.timeInterval else {
            return false
        }
        return silenceSinceHint <= constants.suspectedStallAfter.timeInterval
    }

    private func shouldRetryNominalTransition(
        current: VoiceKernelManagedSession,
        observation: VoiceLivenessObservation
    ) -> Bool {
        guard current.recoveryMode == .nominalInputFormatChange,
              !observation.hadProgress,
              let startedAt = observation.startedAt
        else {
            return false
        }

        return observation.observedAt.timeIntervalSince(startedAt) >= constants.transitionalPollInterval.timeInterval
    }

    private func nominalRecordingPhase(for phase: VoiceCapturePhase) -> VoiceCapturePhase {
        switch phase {
        case .recordingUnverified:
            return .recordingUnverified
        case .recordingLive, .suspectedStall:
            return .recordingLive
        case .arming, .starting, .blocked, .resuming, .recovering, .stopping, .finalizing, .commitDeferred, .committed, .lost:
            return phase
        }
    }

    private func beginNominalTransition(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current, current.generation == generation else {
            return []
        }

        let previousPhase = current.snapshot.phase
        current.snapshot.phase = nominalRecordingPhase(for: current.snapshot.phase)
        current.snapshot.updatedAt = observedAt
        current.snapshot.heartbeatAt = observedAt
        current.snapshot.blockedReason = nil
        current.snapshot.blockerClearedAt = nil
        current.snapshot.blockedAutoFinalizeAt = nil
        current.pendingSealContinuation = nil
        current.blockedRecoveryReason = nil
        current.blockedRecoveryRetryClass = nil
        current.recentHint = nil
        current.recoveryMode = .nominalInputFormatChange
        state.current = current

        var effects: [VoiceKernelEffect] = []
        if previousPhase != current.snapshot.phase {
            effects.append(.persistCurrentSession(
                generation: generation,
                session: current.snapshot,
                previousPhase: previousPhase,
                reason: VoiceSegmentSealReason.inputFormatChange.rawValue
            ))
        }
        effects.append(.recoverCurrentSession(generation: generation, reason: .inputFormatChange))
        return effects
    }

    private func beginRecoveryAfterSeal(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        reason: VoiceSegmentSealReason,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current, current.generation == generation else {
            return []
        }
        let previousPhase = current.snapshot.phase
        current.snapshot.phase = .recovering
        current.snapshot.updatedAt = observedAt
        current.snapshot.heartbeatAt = observedAt
        current.snapshot.blockedReason = nil
        current.snapshot.blockerClearedAt = nil
        current.snapshot.blockedAutoFinalizeAt = nil
        current.snapshot.recoveryCount += 1
        current.pendingSealContinuation = .recover(reason: reason)
        current.blockedRecoveryReason = nil
        current.blockedRecoveryRetryClass = nil
        current.recoveryRetryCount = 0
        current.recentHint = nil
        current.recoveryMode = nil
        state.current = current
        return [
            .persistCurrentSession(
                generation: generation,
                session: current.snapshot,
                previousPhase: previousPhase,
                reason: reason.rawValue
            ),
            .sealCurrentSegment(generation: generation, reason: reason),
        ]
    }

    private func beginBlockedAfterSeal(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        blockedReason: VoiceBlockedReason,
        sealReason: VoiceSegmentSealReason,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current, current.generation == generation else {
            return []
        }
        let previousPhase = current.snapshot.phase
        current.snapshot.phase = .blocked
        current.snapshot.blockedReason = blockedReason
        current.snapshot.blockerClearedAt = nil
        current.snapshot.blockedAutoFinalizeAt = nil
        current.snapshot.updatedAt = observedAt
        current.snapshot.heartbeatAt = observedAt
        current.pendingSealContinuation = nil
        current.blockedRecoveryReason = nil
        current.blockedRecoveryRetryClass = nil
        current.recoveryRetryCount = 0
        current.recentHint = nil
        current.recoveryMode = nil
        state.current = current
        return [
            .persistCurrentSession(
                generation: generation,
                session: current.snapshot,
                previousPhase: previousPhase,
                reason: current.snapshot.phase.rawValue
            ),
            .sealCurrentSegment(generation: generation, reason: sealReason),
        ]
    }

    private func beginResume(
        state: inout VoiceKernelState,
        generation: VoiceOperationGeneration,
        observedAt: Date
    ) -> [VoiceKernelEffect] {
        guard var current = state.current,
              current.generation == generation
        else {
            return []
        }
        let previousPhase = current.snapshot.phase
        current.snapshot.phase = .resuming
        current.snapshot.updatedAt = observedAt
        current.snapshot.heartbeatAt = observedAt
        current.pendingSealContinuation = nil
        current.blockedRecoveryReason = nil
        current.blockedRecoveryRetryClass = nil
        current.recoveryRetryCount = 0
        current.recentHint = nil
        current.recoveryMode = nil
        state.current = current
        return [
            .persistCurrentSession(
                generation: generation,
                session: current.snapshot,
                previousPhase: previousPhase,
                reason: "blocked_resume_requested"
            ),
            .recoverCurrentSession(
                generation: generation,
                reason: blockedSealReason(for: current.snapshot.blockedReason)
            ),
        ]
    }

    private func recoveryRetryDelay(forAttempt attempt: Int, retryClass: VoiceRetryClass) -> Duration {
        _ = attempt
        switch retryClass {
        case .selfHealing:
            return constants.selfHealingRetryDelay
        case .externalBlocker:
            return constants.externalBlockerRetryDelay
        case .deferredCommit:
            return .seconds(0)
        }
    }

    private func recoveryRetryLimit(for retryClass: VoiceRetryClass) -> Int {
        switch retryClass {
        case .selfHealing:
            return 1
        case .externalBlocker:
            return 1
        case .deferredCommit:
            return 0
        }
    }

    private func blockedReason(for reason: VoiceInterruptionReason) -> VoiceBlockedReason {
        switch reason {
        case .system:
            return .interruption
        case .appWasSuspended:
            return .appWasSuspended
        case .builtInMicMuted:
            return .builtInMicMuted
        case .unknown:
            return .audioSessionUnavailable
        }
    }

    private func blockedSealReason(for blockedReason: VoiceBlockedReason?) -> VoiceSegmentSealReason {
        switch blockedReason {
        case .routeLoss, .noSuitableRoute:
            return .routeChange
        case .interruption, .appWasSuspended, .builtInMicMuted, .audioSessionUnavailable, .none:
            return .interruption
        }
    }

    private func blockedFinalizationProof(
        for session: VoiceSessionSnapshot,
        generation: VoiceOperationGeneration
    ) -> VoiceDestructiveProof {
        VoiceDestructiveProof(
            reason: session.blockedReason == .routeLoss || session.blockedReason == .noSuitableRoute ? .routeChange : .interruption,
            sessionID: session.sessionID,
            generation: generation,
            ownership: .ownedByCurrentProcess,
            isFresh: true,
            recoveryDecision: nil
        )
    }
}

public extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
