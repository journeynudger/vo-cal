import AVFoundation
import Foundation
import VoCalCapture
import VoCalVoice
import SwiftUI
import UIKit

// Port provenance: Serein apps/ios/SereinApp/Sources/VoiceCaptureCoordinator.swift,
// near-verbatim with Serein → VoCal module renames. The state machine, liveness
// monitoring, interruption handling, route-change classification, crash recovery, and
// filesystem session ledger are preserved unchanged — they are dogfood-hardened.
// Seam cuts in this file (each carries a why-comment at the cut site):
// - VoiceLiveActivityManager / ActivityKit (all request/sync/end call sites)
// - VoiceCaptureIntent / AppIntents entry paths (the `.captureIntentBegan` publish)
// - CaptureContextCollector (passive location/device context; context stays empty)
// The C4 upload runtime attaches via CaptureCommitObserver below — not by reaching
// into this coordinator.

// C4 attachment point. Requirement: the upload/relay runtime (task C4) must learn
// about newly committed captures without the capture path depending on it — if the
// upload subsystem is deleted entirely, capture must still work (Vo-Cal AGENTS.md,
// capture-path isolation). Failure mode avoided: coupling commit acknowledgement to a
// transport subsystem; one wedged upload blocked every subsequent Serein capture for
// hours (Serein AGENTS.md, April 2026). Evidence: phase plan C4; Serein notified its
// relay runtime only through outbox change hints, never inline on the commit path.
protocol CaptureCommitObserver: Sendable {
    func captureCommitted(_ record: LocalCommitReceipt) async
}

struct NoOpCaptureCommitObserver: CaptureCommitObserver {
    func captureCommitted(_ record: LocalCommitReceipt) async {}
}

protocol VoiceAudioSessionControlling: Sendable {
    func configureForCapture(
        usesMixWithOthers: Bool,
        preferredInputUID: String?
    ) async throws
    func deactivate() async
}

actor SystemVoiceAudioSessionController: VoiceAudioSessionControlling {
    func configureForCapture(
        usesMixWithOthers: Bool,
        preferredInputUID: String?
    ) async throws {
        try await Self.configureSharedAudioSession(
            usesMixWithOthers: usesMixWithOthers,
            preferredInputUID: preferredInputUID
        )
    }

    func deactivate() async {
        await Self.deactivateSharedAudioSession()
    }

    @MainActor
    private static func configureSharedAudioSession(
        usesMixWithOthers: Bool,
        preferredInputUID: String?
    ) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .bluetoothHighQualityRecording]
        if usesMixWithOthers {
            options.insert(.mixWithOthers)
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setPreferredSampleRate(VoiceCAFMuxer.sampleRate)
        try session.setActive(true)

        if let preferredInputUID,
           let preferredInput = session.availableInputs?.first(where: { $0.uid == preferredInputUID }) {
            try session.setPreferredInput(preferredInput)
        }
    }

    @MainActor
    private static func deactivateSharedAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

private struct VoiceStartupObservation: Sendable {
    let requestID: UUID
    let handle: ObservabilityOperationHandle
    var sessionID: String?
    var captureID: String?

    func attributes(extra: [String: ObservabilityScalar] = [:]) -> [String: ObservabilityScalar] {
        var attributes = extra
        if let sessionID {
            attributes["session_id"] = .string(sessionID)
        }
        if let captureID {
            attributes["capture_id"] = .string(captureID)
        }
        return attributes
    }
}

actor VoiceCaptureCoordinator {
    typealias OutboxFactory = @Sendable (URL, FileManager) throws -> CaptureOutbox

    static let shared = VoiceCaptureCoordinator()

    private let bundle: Bundle
    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let constants: VoiceCaptureConstants
    private let kernel: VoiceCoordinatorKernel
    private let recorderFactory: VoiceRecorderFactory
    private let audioSessionController: VoiceAudioSessionControlling
    private let outboxFactory: OutboxFactory
    private let repairer: CAFRepairer
    private let observabilityClient: ObservabilityClient
    private let configureSharedObservability: Bool
    private let clock = ContinuousClock()
    private let explicitAppGroupRoot: URL?
    private let explicitDeviceID: String?
    private let debugLogRootOverride: URL?
    private let protectedDataDidBecomeAvailableNotification = Notification.Name("UIApplicationProtectedDataDidBecomeAvailable")

    private var appGroupRoot: URL?
    private var deviceID: String?
    private var store: VoiceSessionStore?
    private var outbox: CaptureOutbox?
    private var configured = false

    private var kernelState = VoiceKernelState()
    private var eventQueue: [VoiceKernelEvent] = []
    private var isDrainingEvents = false
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []
    private var toggleContinuations: [UUID: CheckedContinuation<VoiceToggleResult, Error>] = [:]

    private var currentBundle: VoiceSessionBundle?
    private var currentSession: VoiceSessionSnapshot?
    private var currentRecorder: VoiceRecorderSession?
    private var currentRecorderGeneration: VoiceOperationGeneration?
    private var recorderStopCompletions: Set<VoiceOperationGeneration> = []
    private var recorderStopWaiters: [VoiceOperationGeneration: [CheckedContinuation<Void, Never>]] = [:]
    private var currentAudioStartedAt: Date?
    private var currentAudioLastBytes: Int64 = 0
    private var currentAudioLastRecorderTime: TimeInterval = 0
    private var currentAudioLastProgressAt: Date?
    private var currentAudioSessionUsesMixWithOthers = false
    private var monitorTask: Task<Void, Never>?
    private var recoveryRetryTask: Task<Void, Never>?
    private var observationTasks: [Task<Void, Never>] = []
    private var lastScanResult: VoiceToggleResult?
    private var lastError: String?
    private var microphonePermissionOverride: VoiceMicrophonePermissionStatus?
    private var protectedDataAvailabilityOverride: Bool?
    private var phaseHistoryByCaptureID: [String: [VoiceCapturePhase]] = [:]
    private var startupObservationsByOperationID: [String: VoiceStartupObservation] = [:]
    private var startupOperationIDByRequestID: [UUID: String] = [:]
    private var startupOperationIDBySessionID: [String: String] = [:]
    private var commitObserver: any CaptureCommitObserver = NoOpCaptureCommitObserver()

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        notificationCenter: NotificationCenter = .default,
        constants: VoiceCaptureConstants = .init(),
        recorderFactory: VoiceRecorderFactory = AVAudioEngineRecorderFactory(),
        audioSessionController: VoiceAudioSessionControlling = SystemVoiceAudioSessionController(),
        repairer: CAFRepairer = CAFRepairer(),
        observabilityClient: ObservabilityClient = CaptureObservability.shared.client,
        configureSharedObservability: Bool = true,
        explicitAppGroupRoot: URL? = nil,
        explicitDeviceID: String? = nil,
        debugLogRootOverride: URL? = nil,
        outboxFactory: @escaping OutboxFactory = { appGroupRoot, fileManager in
            try CaptureOutbox(appGroupRoot: appGroupRoot, fileManager: fileManager)
        }
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.notificationCenter = notificationCenter
        self.constants = constants
        self.kernel = VoiceCoordinatorKernel(constants: constants)
        self.recorderFactory = recorderFactory
        self.audioSessionController = audioSessionController
        self.outboxFactory = outboxFactory
        self.repairer = repairer
        self.observabilityClient = observabilityClient
        self.configureSharedObservability = configureSharedObservability
        self.explicitAppGroupRoot = explicitAppGroupRoot
        self.explicitDeviceID = explicitDeviceID
        self.debugLogRootOverride = debugLogRootOverride
    }

    func applicationDidFinishLaunching() async {
        do {
            try await bootstrapIfNeeded()
            observeNotificationsIfNeeded()
            await observeBlockedStateIfNeeded(source: "launch", allowClear: false)
            await submitEventAndDrain(.recoveryScanRequested(trigger: .launch))
        } catch {
            await recordError("voice_launch_failed", error: error)
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) async {
        guard phase == .active else {
            return
        }
        do {
            try await bootstrapIfNeeded()
            observeNotificationsIfNeeded()
            await observeBlockedStateIfNeeded(source: VoiceRecoveryTrigger.sceneActive.rawValue, allowClear: true)
            await submitEventAndDrain(.recoveryScanRequested(trigger: .sceneActive))
        } catch {
            await recordError("voice_scene_active_failed", error: error)
        }
    }

    func setCommitObserver(_ observer: any CaptureCommitObserver) {
        commitObserver = observer
    }

    func requestMicrophonePermission() async -> Bool {
        if let microphonePermissionOverride {
            return microphonePermissionOverride == .granted
        }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func debugSnapshot() async -> VoiceDebugSnapshot {
        do {
            try await bootstrapIfNeeded()
            let activeSessions = try loadActiveSessions().sessions
            let latest = activeSessions.last?.session
            return VoiceDebugSnapshot(
                sessionCount: activeSessions.count,
                captureID: latest?.captureID,
                phase: latest?.phase,
                pendingCommitReason: latest?.pendingCommitReason,
                segmentCount: latest?.audioFile == nil ? 0 : 1,
                permissionStatus: microphonePermissionStatusName(),
                appGroupPath: appGroupRoot?.path,
                lastError: lastError
            )
        } catch {
            return VoiceDebugSnapshot(
                sessionCount: 0,
                captureID: nil,
                phase: nil,
                pendingCommitReason: nil,
                segmentCount: 0,
                permissionStatus: microphonePermissionStatusName(),
                appGroupPath: appGroupRoot?.path,
                lastError: error.localizedDescription
            )
        }
    }

    func toggle(
        sourceSurface: CaptureSourceSurface = .nativeRecorder,
        reason: String = "foreground_toggle",
        executionMode: ObservabilityExecutionMode = .unknown,
        runID: String? = nil
    ) async throws -> VoiceToggleResult {
        let existingPhase = kernelState.current?.snapshot.phase
        let request = makeToggleRequest(sourceSurface: sourceSurface, reason: reason)
        let shouldTrackStartup = shouldTrackStartupObservation(for: existingPhase)
        let voiceBootstrapCold = !configured
        let startupContext = await AppRuntimeCoordinator.shared.prepareVoiceStartup(executionMode: executionMode)

        if shouldTrackStartup {
            let observation = await makeStartupObservation(
                request: request,
                executionMode: executionMode,
                processCold: startupContext.processCold,
                voiceBootstrapCold: voiceBootstrapCold,
                entryMode: startupContext.entryMode,
                runID: runID
            )
            storeStartupObservation(observation)
            observation.handle.milestone("accepted", attributes: observation.attributes())
            observation.handle.milestone(
                "bootstrap_started",
                attributes: observation.attributes(extra: ["bootstrap_cached": .bool(!voiceBootstrapCold)])
            )
        }

        do {
            try await bootstrapIfNeeded()
        } catch {
            recordStartupFailure(
                requestID: request.requestID,
                reason: "bootstrap_failed",
                extra: ["error": .string(error.localizedDescription)]
            )
            throw error
        }

        emitStartupMilestone(
            requestID: request.requestID,
            milestone: "bootstrap_done",
            extra: ["bootstrap_cached": .bool(!voiceBootstrapCold)]
        )
        observeNotificationsIfNeeded()
        if kernelState.current != nil {
            emitStartupMilestone(
                requestID: request.requestID,
                milestone: "recovery_scan_started",
                extra: ["skipped": .bool(true)]
            )
            emitStartupMilestone(
                requestID: request.requestID,
                milestone: "recovery_scan_done",
                extra: ["skipped": .bool(true)]
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            toggleContinuations[request.requestID] = continuation
            eventQueue.append(.toggleRequested(request))
            startDrainerIfNeeded()
        }
    }

    func pollNowForTesting() async throws {
        try await bootstrapIfNeeded()
        guard let generation = kernelState.current?.generation else {
            return
        }
        await observeCurrentLiveness(generation: generation, waitForDrain: true)
    }

    func recoverNowForTesting(trigger: VoiceRecoveryTrigger = .toggle) async throws -> VoiceToggleResult? {
        try await bootstrapIfNeeded()
        lastScanResult = nil
        await submitEventAndDrain(.recoveryScanRequested(trigger: trigger))
        return lastScanResult
    }

    func activeSessionsForTesting() async throws -> [VoiceSessionSnapshot] {
        try await bootstrapIfNeeded()
        return try loadActiveSessions().sessions.map(\.session)
    }

    func currentSessionForTesting() -> VoiceSessionSnapshot? {
        currentSession
    }

    func phaseTraceForTesting(captureID: String) -> [VoiceCapturePhase] {
        phaseHistoryByCaptureID[captureID] ?? []
    }

    func setMicrophonePermissionOverrideForTesting(_ permission: VoiceMicrophonePermissionStatus?) {
        microphonePermissionOverride = permission
    }

    func setProtectedDataAvailabilityOverrideForTesting(_ available: Bool?) {
        protectedDataAvailabilityOverride = available
    }

    func simulateProcessDeathForTesting() {
        cancelObservationTasks()
        resetCurrentSessionHandles()
        kernelState.current = nil
    }

    func shutdownForTesting() {
        currentRecorder?.stop()
        cancelObservationTasks()
        resetCurrentSessionHandles()
        kernelState.current = nil
    }

    private func bootstrapIfNeeded() async throws {
        guard !configured else {
            return
        }

        let resolvedAppGroupRoot: URL
        if let explicitAppGroupRoot {
            resolvedAppGroupRoot = explicitAppGroupRoot
        } else {
            resolvedAppGroupRoot = try AppGroupConfig.sharedContainerURL(fileManager: fileManager, bundle: bundle)
        }

        let resolvedDeviceID: String
        if let explicitDeviceID {
            resolvedDeviceID = explicitDeviceID
        } else {
            resolvedDeviceID = try DeviceIdentityStore.loadOrCreateDeviceID(bundle: bundle)
        }

        _ = try VoCalCapturePaths.ensureInitialized(appGroupRoot: resolvedAppGroupRoot, fileManager: fileManager)
        if configureSharedObservability {
            await CaptureObservability.shared.configureIfNeeded(
                appGroupRoot: debugLogRootOverride ?? resolvedAppGroupRoot
            )
        }
        appGroupRoot = resolvedAppGroupRoot
        deviceID = resolvedDeviceID
        store = VoiceSessionStore(appGroupRoot: resolvedAppGroupRoot, fileManager: fileManager)
        outbox = try outboxFactory(resolvedAppGroupRoot, fileManager)
        try await CaptureDebugRecorder.shared.configure(appGroupRoot: debugLogRootOverride ?? resolvedAppGroupRoot)
        configured = true
    }

    private func observeNotificationsIfNeeded() {
        guard observationTasks.isEmpty else {
            return
        }

        observationTasks.append(Task {
            for await note in notificationCenter.notifications(named: AVAudioSession.routeChangeNotification) {
                await self.handleRouteChange(note)
            }
        })
        observationTasks.append(Task {
            for await note in notificationCenter.notifications(named: AVAudioSession.interruptionNotification) {
                await self.handleInterruption(note)
            }
        })
        observationTasks.append(Task {
            for await note in notificationCenter.notifications(named: AVAudioSession.mediaServicesWereResetNotification) {
                await self.handleMediaServicesReset(note)
            }
        })
        observationTasks.append(Task {
            for await _ in notificationCenter.notifications(named: protectedDataDidBecomeAvailableNotification) {
                await self.observeBlockedStateIfNeeded(
                    source: VoiceRecoveryTrigger.protectedDataAvailable.rawValue,
                    allowClear: true
                )
                await self.submitEventAndDrain(.recoveryScanRequested(trigger: .protectedDataAvailable))
            }
        })
    }

    private func makeToggleRequest(
        sourceSurface: CaptureSourceSurface,
        reason: String
    ) -> VoicePendingToggleRequest {
        let requestedAt = Date()
        let sessionID = UUID().uuidString.lowercased()
        let captureID = "voice_\(CaptureDateCodec.captureIDTimestamp(requestedAt))_\(UUID().uuidString.lowercased().prefix(6))"
        return VoicePendingToggleRequest(
            requestID: UUID(),
            sourceSurface: sourceSurface.rawValue,
            reason: reason,
            requestedAt: requestedAt,
            reservedSessionID: sessionID,
            reservedCaptureID: captureID
        )
    }

    private func submitEventAndDrain(_ event: VoiceKernelEvent) async {
        eventQueue.append(event)
        if isDrainingEvents {
            await withCheckedContinuation { continuation in
                idleContinuations.append(continuation)
            }
            return
        }
        await drainEvents()
    }

    private func startDrainerIfNeeded() {
        guard !isDrainingEvents else {
            return
        }
        Task {
            await self.drainEvents()
        }
    }

    private func scheduleRecoveryRetry(
        generation: VoiceOperationGeneration,
        after: Duration
    ) {
        recoveryRetryTask?.cancel()
        recoveryRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: after)
                await self?.submitEventAndDrain(.recoveryRetryRequested(generation: generation))
            } catch {
                return
            }
        }
    }

    private func observeBlockedStateIfNeeded(source: String, allowClear: Bool) async {
        guard let current = kernelState.current else {
            return
        }
        if current.snapshot.phase == .blocked,
           let blockedAutoFinalizeAt = current.snapshot.blockedAutoFinalizeAt,
           Date() >= blockedAutoFinalizeAt
        {
            await submitEventAndDrain(.blockedDeadlineObservedExpired(observedAt: Date()))
            return
        }
        guard allowClear,
              current.snapshot.phase == .blocked,
              current.snapshot.blockerClearedAt == nil,
              shouldClearBlockedState(from: source, reason: current.snapshot.blockedReason)
        else {
            return
        }
        await submitEventAndDrain(.blockedClearObserved(source: source, observedAt: Date()))
    }

    private func drainEvents() async {
        guard !isDrainingEvents else {
            return
        }
        isDrainingEvents = true
        defer {
            isDrainingEvents = false
            let continuations = idleContinuations
            idleContinuations.removeAll()
            for continuation in continuations {
                continuation.resume()
            }
        }

        while !eventQueue.isEmpty {
            let previousManagedSession = kernelState.current
            let event = eventQueue.removeFirst()
            let effects = kernel.step(state: &kernelState, event: event)
            syncCurrentSessionFromKernel()
            await maybeEmitLiveConfirmation(previous: previousManagedSession, current: kernelState.current)

            for effect in effects {
                await execute(effect)
            }
        }
    }

    private func execute(_ effect: VoiceKernelEffect) async {
        switch effect {
        case let .scanActiveSessions(trigger, request):
            await runRecoveryScan(trigger: trigger, request: request)
        case let .observeStartPrerequisites(request):
            // Seam cut (Live Activity): Serein populated this from
            // VoiceLiveActivityManager.activitiesEnabled(), because AudioRecordingIntent
            // background starts legally require a Live Activity. Requirement: Vo-Cal P0
            // capture is foreground-only — VoiceLiveActivity/ActivityKit is not ported, so
            // the prerequisite is satisfied-by-construction (no activity is required for a
            // foreground recorder). Failure mode avoided: populating `false` would make the
            // kernel deny every start with .liveActivityUnavailable; porting the ActivityKit
            // request instead would reintroduce the cold-start rejection class
            // (target_is_not_foreground). The SPM prerequisite vocabulary stays intact per
            // port discipline. Evidence: Vo-Cal AGENTS.md (foreground-only master decision);
            // Serein AGENTS.md (April 2026 authorization-window incident);
            // https://developer.apple.com/forums/thread/815725
            let prerequisites = VoiceStartPrerequisites(
                bootstrapReady: store != nil && deviceID != nil,
                microphonePermissionGranted: microphonePermissionGranted(),
                liveActivityEnabled: true
            )
            eventQueue.append(.startPrerequisitesObserved(request: request, prerequisites: prerequisites))
        case let .startReservedSession(session, generation, mixWithOthers):
            await runStartReservedSession(session: session, generation: generation, mixWithOthers: mixWithOthers)
        case let .persistCurrentSession(generation, session, previousPhase, reason):
            await persistCurrentSession(
                generation: generation,
                session: session,
                previousPhase: previousPhase,
                reason: reason
            )
        case let .sealCurrentSegment(generation, reason):
            await runSealCurrentSegment(generation: generation, reason: reason)
        case let .scheduleRecoveryRetry(generation, after):
            scheduleRecoveryRetry(generation: generation, after: after)
        case let .finalizeCurrentSession(generation, reason, proof):
            await runFinalizeSession(generation: generation, reason: reason, proof: proof)
        case let .recoverCurrentSession(generation, reason):
            await runRecovery(generation: generation, reason: reason)
        case let .commitRecoveredSession(session, generation, proof):
            await runCommitRecoveredSession(session: session, generation: generation, proof: proof)
        case let .removeRecoveredSession(session, proof):
            await removeRecoveredSession(session: session, proof: proof)
        case let .resolveToggleResult(requestIDs, result):
            for requestID in requestIDs {
                switch result.action {
                case let .started(captureID):
                    updateStartupObservationIdentity(
                        requestID: requestID,
                        sessionID: result.sessionID,
                        captureID: captureID
                    )
                    unlinkStartupObservationRequestID(requestID)
                case let .blocked(captureID):
                    updateStartupObservationIdentity(
                        requestID: requestID,
                        sessionID: result.sessionID,
                        captureID: captureID
                    )
                    recordStartupFailure(
                        requestID: requestID,
                        reason: "blocked",
                        extra: ["result_action": .string("blocked")]
                    )
                case let .finalized(captureID):
                    updateStartupObservationIdentity(
                        requestID: requestID,
                        sessionID: result.sessionID,
                        captureID: captureID
                    )
                    recordStartupFailure(
                        requestID: requestID,
                        reason: "finalized_without_startup",
                        extra: ["result_action": .string("finalized")]
                    )
                case let .deferred(captureID):
                    updateStartupObservationIdentity(
                        requestID: requestID,
                        sessionID: result.sessionID,
                        captureID: captureID
                    )
                    recordStartupFailure(
                        requestID: requestID,
                        reason: "deferred_without_startup",
                        extra: ["result_action": .string("deferred")]
                    )
                case let .lost(captureID):
                    updateStartupObservationIdentity(
                        requestID: requestID,
                        sessionID: result.sessionID,
                        captureID: captureID
                    )
                    recordStartupFailure(
                        requestID: requestID,
                        reason: "lost_without_startup",
                        extra: ["result_action": .string("lost")]
                    )
                case let .stopping(captureID):
                    updateStartupObservationIdentity(
                        requestID: requestID,
                        sessionID: result.sessionID,
                        captureID: captureID
                    )
                    recordStartupFailure(
                        requestID: requestID,
                        reason: "stopping_without_startup",
                        extra: ["result_action": .string("stopping")]
                    )
                }
                toggleContinuations.removeValue(forKey: requestID)?.resume(returning: result)
            }
        case let .failToggle(requestIDs, error):
            for requestID in requestIDs {
                recordStartupFailure(
                    requestID: requestID,
                    reason: "toggle_failed",
                    extra: ["error": .string(error.localizedDescription)]
                )
                toggleContinuations.removeValue(forKey: requestID)?.resume(throwing: error)
            }
        }
    }

    private func runRecoveryScan(
        trigger: VoiceRecoveryTrigger,
        request: VoicePendingToggleRequest?
    ) async {
        if let request {
            emitStartupMilestone(requestID: request.requestID, milestone: "recovery_scan_started")
        }
        do {
            let scan = try loadActiveSessions()
            // Seam cut (Live Activity): Serein ended orphaned Live Activities here. Not
            // ported — foreground-only P0 never starts an activity, so there is nothing to
            // orphan. See the why-comment on the prerequisites seam above.
            let sessions = try scan.sessions.map { entry in
                VoiceRecoveryObservation(
                    session: entry.session,
                    ownership: sessionOwnership(bundle: entry.bundle, session: entry.session),
                    observedAt: Date(),
                    outboxCommitted: try captureAlreadyCommitted(captureID: entry.session.captureID)
                )
            }

            for observation in sessions {
                let decision = Self.classifySessionRecovery(
                    session: observation.session,
                    trigger: trigger,
                    ownership: observation.ownership,
                    now: observation.observedAt,
                    outboxCommitted: observation.outboxCommitted,
                    constants: constants
                )
                assertImplication(
                    observation.ownership == .ownedByCurrentProcess,
                    decision != .staleOrOrphaned && decision != .terminalCleanup,
                    message: "owned session may not be classified stale_or_orphaned",
                    metadata: [
                        "session_id": observation.session.sessionID,
                        "capture_id": observation.session.captureID,
                        "trigger": trigger.rawValue,
                        "decision": decision.rawValue,
                    ]
                )
                emit(.info, name: "voice.session_loaded", message: "Loaded voice session from filesystem ledger", metadata: [
                    "session_id": observation.session.sessionID,
                    "capture_id": observation.session.captureID,
                    "phase": observation.session.phase.rawValue,
                    "reason": trigger.rawValue,
                    "ownership": observation.ownership.rawValue,
                    "action": decision.rawValue,
                    "outbox_committed": observation.outboxCommitted ? "true" : "false",
                ])
            }

            eventQueue.append(.recoveryScanCompleted(
                trigger: trigger,
                request: request,
                sessions: sessions,
                quarantinedCorruptBundleCount: scan.quarantinedCorruptBundleCount
            ))
            if let request {
                emitStartupMilestone(
                    requestID: request.requestID,
                    milestone: "recovery_scan_done",
                    extra: ["session_count": .integer(Int64(sessions.count))]
                )
            }
        } catch {
            await recordError("voice_recovery_scan_failed", error: error)
            if let request {
                eventQueue.append(.startPrerequisitesObserved(
                    request: request,
                    prerequisites: VoiceStartPrerequisites(
                        bootstrapReady: false,
                        microphonePermissionGranted: microphonePermissionGranted(),
                        // Seam cut (Live Activity): satisfied-by-construction in the
                        // foreground-only build. See the prerequisites seam why-comment.
                        liveActivityEnabled: true
                    )
                ))
            }
        }
    }

    private func runStartReservedSession(
        session: VoiceSessionSnapshot,
        generation: VoiceOperationGeneration,
        mixWithOthers: Bool
    ) async {
        guard ensureCurrentGeneration(generation) else {
            return
        }
        guard let store else {
            recordStartupFailure(sessionID: session.sessionID, reason: "app_group_unavailable")
            eventQueue.append(.startFailed(generation: generation, error: .appGroupUnavailable))
            return
        }

        var mutable = session
        updateStartupObservationIdentity(
            sessionID: session.sessionID,
            captureID: session.captureID
        )
        do {
            mutable.context = [:]
            let bundle = try store.createActiveBundle(sessionID: session.sessionID)
            currentBundle = bundle
            currentSession = mutable
            try store.persist(session: mutable, to: bundle)
            recordPhase(mutable.captureID, phase: mutable.phase)
            emit(.notice, name: "voice.phase_changed", message: "Voice session created", metadata: [
                "session_id": mutable.sessionID,
                "capture_id": mutable.captureID,
                "from": "none",
                "to": mutable.phase.rawValue,
                "reason": "session_created",
            ])

            // Seam cut (Live Activity / AudioRecordingIntent): Serein requested a Live
            // Activity right here — AudioRecordingIntent recordings must start and keep one
            // running while the recorder is active, and on cold background starts moving
            // that request behind an unstructured Task loses the intent execution context
            // and ActivityKit rejects with target_is_not_foreground
            // (https://developer.apple.com/forums/thread/815725). Requirement: Vo-Cal P0
            // capture is foreground-only — no AppIntents path, no AudioRecordingIntent, so
            // no Live Activity obligation exists and the request, its generation-proof
            // preflight, and the live_activity_request_started/done milestones are not
            // ported (the milestone deletions are recorded in docs/VOICE_CAPTURE.md).
            // Failure mode avoided: reintroducing the ActivityKit cold-start rejection
            // class, and putting a non-audio subsystem back in front of microphone
            // activation. Evidence: Vo-Cal AGENTS.md (foreground-only master decision);
            // Serein AGENTS.md (April 2026 authorization-window incident); Apple forum
            // thread 815725.
            currentAudioSessionUsesMixWithOthers = mixWithOthers
            emitStartupMilestone(sessionID: mutable.sessionID, milestone: "audio_session_config_started")
            try await configureAudioSession(preferredInputUID: nil)
            emitStartupMilestone(sessionID: mutable.sessionID, milestone: "audio_session_config_done")
            guard ensureCurrentGeneration(generation) else {
                return
            }

            try transition(session: &mutable, bundle: bundle, to: .starting, reason: "recorder_start")
            try startAudioFile(
                session: &mutable,
                bundle: bundle,
                reason: "initial_start",
                generation: generation,
                appendToExisting: false
            )
            guard ensureCurrentGeneration(generation) else {
                return
            }

            eventQueue.append(.startSucceeded(generation: generation, session: mutable))
        } catch {
            let typed = captureError(from: error)
            recordStartupFailure(
                sessionID: mutable.sessionID,
                reason: "start_failed",
                extra: ["error": .string(typed.localizedDescription)]
            )
            await handleStartFailure(typed, generation: generation, session: mutable)
            eventQueue.append(.startFailed(generation: generation, error: typed))
        }
    }

    private func persistCurrentSession(
        generation: VoiceOperationGeneration,
        session: VoiceSessionSnapshot,
        previousPhase: VoiceCapturePhase,
        reason: String
    ) async {
        guard ensureCurrentGeneration(generation),
              let bundle = currentBundle ?? bundleForSessionID(session.sessionID)
        else {
            return
        }
        do {
            try requireStore().persist(session: session, to: bundle)
            currentSession = session
            currentBundle = bundle
            if previousPhase != session.phase {
                recordPhase(session.captureID, phase: session.phase)
                emit(.notice, name: "voice.phase_changed", message: "Voice phase changed", metadata: [
                    "session_id": session.sessionID,
                    "capture_id": session.captureID,
                    "from": previousPhase.rawValue,
                    "to": session.phase.rawValue,
                    "reason": reason,
                ])
            }
            // Seam cut (Live Activity): Serein synced the Live Activity after persisting.
            // Not ported — foreground-only P0. See the prerequisites seam why-comment.
        } catch {
            await recordError("voice_persist_failed", error: error)
        }
    }

    private func runSealCurrentSegment(
        generation: VoiceOperationGeneration,
        reason: VoiceSegmentSealReason,
        session overrideSession: VoiceSessionSnapshot? = nil
    ) async {
        guard let bundle = bundleForSessionID((overrideSession ?? currentSession)?.sessionID),
              var session = overrideSession ?? currentSession
        else {
            return
        }

        currentBundle = bundle
        currentSession = session

        do {
            try await sealCurrentAudioFile(
                session: &session,
                bundle: bundle,
                reason: reason,
                stopRecorder: true,
                generation: generation
            )
            guard ensureCurrentGeneration(generation) else {
                return
            }
            eventQueue.append(.segmentSealed(generation: generation, session: session))
        } catch {
            let captureError = captureError(from: error)
            emit(.error, name: "voice.segment_seal_failed", message: "Voice segment seal failed", metadata: [
                "session_id": session.sessionID,
                "capture_id": session.captureID,
                "reason": reason.rawValue,
                "generation": "\(generation)",
                "error": captureError.localizedDescription,
            ])
            eventQueue.append(.segmentSealFailed(generation: generation, reason: reason, error: captureError))
        }
    }

    private func runFinalizeSession(
        generation: VoiceOperationGeneration,
        reason: VoiceSegmentSealReason,
        proof: VoiceDestructiveProof
    ) async {
        guard let bundle = bundleForSessionID(currentSession?.sessionID),
              var session = currentSession
        else {
            return
        }

        currentBundle = bundle
        currentSession = session

        guard assertDestructivePreconditions(proof: proof, session: session, generation: generation, action: "finalize_session") else {
            return
        }

        do {
            if session.phase != .finalizing {
                try transition(session: &session, bundle: bundle, to: .finalizing, reason: reason.rawValue)
            }
            guard ensureCurrentGeneration(generation) else {
                return
            }

            let finalURL = try VoiceCAFMuxer.prepareSingleFileForCommit(
                session: &session,
                bundle: bundle,
                store: try requireStore(),
                repairer: repairer
            )
            try requireStore().persist(session: session, to: bundle)
            currentSession = session
            emit(.info, name: "voice.final_blob_ready", message: "Voice final CAF prepared", metadata: [
                "session_id": session.sessionID,
                "capture_id": session.captureID,
                "final_blob_relpath": session.finalBlobRelpath ?? "",
            ])
            guard ensureCurrentGeneration(generation) else {
                return
            }

            let result = try await commitFinalArtifact(
                session: &session,
                bundle: bundle,
                finalURL: finalURL,
                generation: generation,
                proof: proof
            )
            lastScanResult = result
            eventQueue.append(.operationFinished(generation: generation, result: result, resultingSession: currentSession))
        } catch let captureError as VoiceCaptureError {
            switch captureError {
            case let .commitDeferred(deferredReason):
                let result = await deferPendingCommit(
                    session: &session,
                    bundle: bundle,
                    reason: deferredReason
                )
                lastScanResult = result
                eventQueue.append(.operationFinished(generation: generation, result: result, resultingSession: currentSession))
            default:
                let result = await handleFinalizeFailure(
                    captureError,
                    session: session,
                    bundle: bundle,
                    generation: generation,
                    proof: proof
                )
                lastScanResult = result
                eventQueue.append(.operationFinished(generation: generation, result: result, resultingSession: currentSession))
            }
        } catch {
            let result = await handleFinalizeFailure(
                error,
                session: session,
                bundle: bundle,
                generation: generation,
                proof: proof
            )
            lastScanResult = result
            eventQueue.append(.operationFinished(generation: generation, result: result, resultingSession: currentSession))
        }
    }

    private func runRecovery(
        generation: VoiceOperationGeneration,
        reason: VoiceSegmentSealReason
    ) async {
        guard ensureCurrentGeneration(generation),
              let bundle = currentBundle ?? bundleForSessionID(currentSession?.sessionID),
              var session = currentSession
        else {
            return
        }

        currentBundle = bundle
        currentSession = session

        do {
            recoveryRetryTask?.cancel()
            recoveryRetryTask = nil
            let recoveryMode = kernelState.current?.recoveryMode
            emit(.warning, name: "voice.recovery_attempt", message: "Attempting voice recovery", metadata: [
                "session_id": session.sessionID,
                "capture_id": session.captureID,
                "recovery_count": "\(session.recoveryCount)",
                "reason": reason.rawValue,
                "phase": session.phase.rawValue,
                "mode": recoveryMode?.rawValue ?? "standard",
            ])
            let preferredInputUID: String?
            if recoveryMode == .nominalInputFormatChange {
                preferredInputUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
            } else {
                preferredInputUID = session.preferredInputUID
            }
            session.preferredInputUID = preferredInputUID
            try await stopCurrentRecorderForRestart()
            try await configureAudioSession(preferredInputUID: preferredInputUID)
            guard ensureCurrentGeneration(generation) else {
                return
            }

            let startReason: String
            let phaseAfterStart: VoiceCapturePhase
            if recoveryMode == .nominalInputFormatChange {
                startReason = VoiceSegmentSealReason.inputFormatChange.rawValue
                phaseAfterStart = session.phase
            } else {
                startReason = session.phase == .resuming ? "resume" : "recovery"
                phaseAfterStart = .recordingUnverified
            }
            try startAudioFile(
                session: &session,
                bundle: bundle,
                reason: startReason,
                generation: generation,
                appendToExisting: true,
                phaseAfterStart: phaseAfterStart
            )
            eventQueue.append(.recoverySucceeded(generation: generation, session: session))
        } catch {
            let captureError = captureError(from: error)
            emit(.error, name: "voice.recovery_failed", message: "Voice recovery failed", metadata: [
                "session_id": session.sessionID,
                "capture_id": session.captureID,
                "reason": reason.rawValue,
                "generation": "\(generation)",
                "error": captureError.localizedDescription,
                "retry_class": recoveryRetryClass(captureError, reason: reason)?.rawValue ?? "none",
            ])
            if let retryClass = recoveryRetryClass(captureError, reason: reason) {
                eventQueue.append(.recoveryBlocked(
                    generation: generation,
                    reason: reason,
                    retryClass: retryClass,
                    error: captureError
                ))
            } else {
                eventQueue.append(.recoveryFailed(generation: generation, reason: reason, error: captureError))
            }
        }
    }

    private func runCommitRecoveredSession(
        session: VoiceSessionSnapshot,
        generation: VoiceOperationGeneration,
        proof: VoiceDestructiveProof
    ) async {
        guard let bundle = bundleForSessionID(session.sessionID) else {
            return
        }
        currentBundle = bundle
        currentSession = session
        currentRecorder = nil
        currentRecorderGeneration = nil

        guard assertDestructivePreconditions(proof: proof, session: session, generation: generation, action: "commit_recovered_session") else {
            return
        }

        var mutable = session
        do {
            let finalURL: URL
            if let relpath = mutable.finalBlobRelpath {
                finalURL = bundle.bundleURL.appendingPathComponent(relpath, isDirectory: false)
            } else {
                if mutable.phase != .finalizing {
                    try transition(session: &mutable, bundle: bundle, to: .finalizing, reason: "resume_deferred_finalize")
                }
                finalURL = try VoiceCAFMuxer.prepareSingleFileForCommit(
                    session: &mutable,
                    bundle: bundle,
                    store: try requireStore(),
                    repairer: repairer
                )
                try requireStore().persist(session: mutable, to: bundle)
                currentSession = mutable
                emit(.info, name: "voice.final_blob_ready", message: "Voice final CAF prepared", metadata: [
                    "session_id": mutable.sessionID,
                    "capture_id": mutable.captureID,
                    "final_blob_relpath": mutable.finalBlobRelpath ?? "",
                ])
            }
            let result = try await commitFinalArtifact(
                session: &mutable,
                bundle: bundle,
                finalURL: finalURL,
                generation: generation,
                proof: proof
            )
            lastScanResult = result
            eventQueue.append(.operationFinished(generation: generation, result: result, resultingSession: currentSession))
        } catch let captureError as VoiceCaptureError {
            switch captureError {
            case let .commitDeferred(deferredReason):
                let result = await deferPendingCommit(
                    session: &mutable,
                    bundle: bundle,
                    reason: deferredReason
                )
                lastScanResult = result
                eventQueue.append(.operationFinished(generation: generation, result: result, resultingSession: currentSession))
            default:
                let result = await handleFinalizeFailure(
                    captureError,
                    session: mutable,
                    bundle: bundle,
                    generation: generation,
                    proof: proof
                )
                lastScanResult = result
                eventQueue.append(.operationFinished(generation: generation, result: result, resultingSession: currentSession))
            }
        } catch {
            let result = await handleFinalizeFailure(
                error,
                session: mutable,
                bundle: bundle,
                generation: generation,
                proof: proof
            )
            lastScanResult = result
            eventQueue.append(.operationFinished(generation: generation, result: result, resultingSession: currentSession))
        }
    }

    private func removeRecoveredSession(
        session: VoiceSessionSnapshot,
        proof: VoiceDestructiveProof
    ) async {
        guard assertDestructivePreconditions(proof: proof, session: session, generation: nil, action: "remove_recovered_session"),
              let bundle = bundleForSessionID(session.sessionID)
        else {
            return
        }
        do {
            try requireStore().removeBundle(bundle)
            if currentBundle?.bundleURL == bundle.bundleURL {
                resetCurrentSessionHandles()
            }
            emit(.info, name: "voice.session_removed", message: "Removed terminal voice session bundle", metadata: [
                "session_id": session.sessionID,
                "capture_id": session.captureID,
                "phase": session.phase.rawValue,
            ])
        } catch {
            await recordError("voice_remove_session_failed", error: error)
        }
    }

    private func observeCurrentLiveness(
        generation: VoiceOperationGeneration,
        waitForDrain: Bool
    ) async {
        guard ensureCurrentGeneration(generation),
              let recorder = currentRecorder,
              currentRecorderGeneration == generation,
              var session = currentSession,
              let bundle = currentBundle,
              let store,
              let relpath = session.audioFile?.relpath
        else {
            return
        }

        let now = Date()
        let audioURL = bundle.bundleURL.appendingPathComponent(relpath, isDirectory: false)
        let fileBytes = store.fileSize(at: audioURL)
        let recorderTime = recorder.currentTime

        session.heartbeatAt = now
        session.updatedAt = now
        session.preferredInputUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid

        if var audioFile = session.audioFile {
            audioFile.bytes = fileBytes
            session.audioFile = audioFile
        }

        let previousBytes = currentAudioLastBytes
        let previousRecorderTime = currentAudioLastRecorderTime
        let hadProgressBeforeObservation = currentAudioLastProgressAt != nil
        if recorderTime > currentAudioLastRecorderTime || fileBytes > currentAudioLastBytes {
            currentAudioLastProgressAt = now
            session.lastProgressAt = now
            currentAudioLastBytes = max(currentAudioLastBytes, fileBytes)
            currentAudioLastRecorderTime = max(currentAudioLastRecorderTime, recorderTime)
            if !hadProgressBeforeObservation {
                emitStartupMilestone(sessionID: session.sessionID, milestone: "first_progress")
            }
        }

        do {
            try store.persist(session: session, to: bundle)
            currentSession = session
        } catch {
            await recordError("voice_monitor_persist_failed", error: error)
        }

        let event = VoiceKernelEvent.livenessObserved(
            generation: generation,
            session: session,
            observation: VoiceLivenessObservation(
                observedAt: now,
                startedAt: currentAudioStartedAt,
                lastProgressAt: currentAudioLastProgressAt,
                fileBytes: fileBytes,
                recorderTime: recorderTime,
                previousFileBytes: previousBytes,
                previousRecorderTime: previousRecorderTime
            )
        )

        if waitForDrain {
            await submitEventAndDrain(event)
        } else {
            eventQueue.append(event)
            startDrainerIfNeeded()
        }
    }

    private func handleRouteChange(_ note: Notification) async {
        let observation = Self.routeChangeObservation(from: note)
        let disposition = observation.map { kernel.classifyRouteChange($0) } ?? .ignoreUnknown
        var metadata = routeMetadata(note)
        metadata["action"] = disposition.rawValue
        if let inputRouteChanged = observation?.inputRouteChanged {
            metadata["input_route_changed"] = inputRouteChanged ? "true" : "false"
        } else {
            metadata["input_route_changed"] = "unknown"
        }
        if let generation = currentRecorderGeneration {
            metadata["generation"] = "\(generation)"
        }
        emit(.info, name: "voice.route_changed", message: "Audio route changed during recording", metadata: metadata)
        if currentSession?.phase == .blocked,
           currentSession?.blockerClearedAt == nil,
           currentRouteHasUsableInput()
        {
            await submitEventAndDrain(.blockedClearObserved(source: "route_available", observedAt: Date()))
        }
        guard let generation = currentRecorderGeneration,
              let observation
        else {
            return
        }
        refreshPreferredInputFromCurrentRoute(observation.currentInputUID)
        await submitEventAndDrain(.routeChanged(generation: generation, observation: observation, observedAt: Date()))
        await observeCurrentLiveness(generation: generation, waitForDrain: false)
    }

    private func handleInterruption(_ note: Notification) async {
        let typeValue = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
        let type = AVAudioSession.InterruptionType(rawValue: typeValue) ?? .began
        let reason = Self.interruptionReason(from: note)
        emit(.warning, name: "voice.interruption", message: "Audio interruption observed", metadata: [
            "type": type == .began ? "began" : "ended",
            "reason": reason.rawValue,
        ])
        if type == .began {
            guard currentRecorder != nil else {
                return
            }
            eventQueue.append(.interruptionBegan(reason: reason, observedAt: Date()))
            startDrainerIfNeeded()
            return
        }
        // Queue the clear observation even if the blocked transition has not drained yet.
        // Interruption ended can arrive back-to-back with interruption began, and gating on the
        // current snapshot here drops the unblock edge before the kernel records `blocked`.
        eventQueue.append(.blockedClearObserved(source: "interruption_ended", observedAt: Date()))
        startDrainerIfNeeded()
    }

    private func handleMediaServicesReset(_ note: Notification) async {
        _ = note
        emit(.warning, name: "voice.media_services_reset", message: "Audio media services reset observed", metadata: [:])
        monitorTask?.cancel()
        currentRecorder = nil
        currentRecorderGeneration = nil
        await submitEventAndDrain(.mediaServicesWereReset(observedAt: Date()))
    }

    private func handleUnexpectedRecorderStop(generation: VoiceOperationGeneration, reason: String) async {
        emit(.error, name: "voice.interruption", message: "Recorder stopped unexpectedly", metadata: [
            "reason": reason,
        ])
        eventQueue.append(.unexpectedRecorderStop(generation: generation, reason: reason, observedAt: Date()))
        startDrainerIfNeeded()
    }

    private func handleRecorderConfigurationChange(generation: VoiceOperationGeneration) async {
        emit(.warning, name: "voice.configuration_changed", message: "Audio engine configuration changed", metadata: [
            "generation": "\(generation)",
        ])
        refreshPreferredInputFromCurrentRoute()
        await submitEventAndDrain(.configurationChanged(generation: generation, observedAt: Date()))
        await observeCurrentLiveness(generation: generation, waitForDrain: false)
    }

    private func handleRecorderStopFinished(generation: VoiceOperationGeneration, successfully: Bool) async {
        if !successfully {
            emit(.warning, name: "voice.recorder_stop_finished", message: "Recorder stop completed unsuccessfully", metadata: [
                "generation": "\(generation)",
            ])
        }
        let waiters = recorderStopWaiters.removeValue(forKey: generation)
        if let waiters {
            for waiter in waiters {
                waiter.resume()
            }
        } else {
            recorderStopCompletions.insert(generation)
        }
    }

    private func loadActiveSessions() throws -> (
        sessions: [(bundle: VoiceSessionBundle, session: VoiceSessionSnapshot)],
        quarantinedCorruptBundleCount: Int
    ) {
        guard let store else {
            throw VoiceCaptureError.appGroupUnavailable
        }
        var loaded: [(bundle: VoiceSessionBundle, session: VoiceSessionSnapshot)] = []
        var quarantinedCorruptBundleCount = 0
        for bundle in try store.activeBundles() {
            do {
                loaded.append((bundle, try store.loadSession(from: bundle)))
            } catch {
                quarantinedCorruptBundleCount += 1
                lastError = error.localizedDescription
                emit(.error, name: "voice.recovery_bundle_corrupt", message: "Voice session bundle quarantined after scan decode failure", metadata: [
                    "bundle_path": bundle.bundleURL.path,
                    "session_path": bundle.sessionURL.path,
                    "error": error.localizedDescription,
                ])
                _ = try? store.moveToQuarantine(bundle)
            }
        }
        return (
            sessions: loaded.sorted { lhs, rhs in
                lhs.session.createdAt < rhs.session.createdAt
            },
            quarantinedCorruptBundleCount: quarantinedCorruptBundleCount
        )
    }

    // Seam cut (CaptureContextCollector): Serein declared collectContext /
    // collectContextValues here, backed by CaptureContextCollector (battery, network,
    // and a passive-location snapshot from SereinSensor's LocationEventJournal). Both
    // were already dead code in Serein — runStartReservedSession sets `context = [:]`
    // and nothing repopulated it. Requirement: Vo-Cal has no location subsystem and
    // P0 capture context is intentionally empty; the collector is not ported and the
    // session context stays `[:]`. Failure mode avoided: porting a passive-location
    // reader with no journal behind it, inviting an agent to "fix" it by building a
    // location pipeline onto the capture path (context is best-effort and must never
    // gate capture commit — INVARIANTS §11). Evidence: Vo-Cal AGENTS.md (no passive
    // location); phase plan C1 ("STUB the context to empty/minimal"); Serein source
    // shows zero call sites for collectContext.

    private func startAudioFile(
        session: inout VoiceSessionSnapshot,
        bundle: VoiceSessionBundle,
        reason: String,
        generation: VoiceOperationGeneration,
        appendToExisting: Bool,
        phaseAfterStart: VoiceCapturePhase = .recordingUnverified
    ) throws {
        guard let store else {
            throw VoiceCaptureError.appGroupUnavailable
        }
        guard ensureCurrentGeneration(generation) else {
            return
        }

        let audioURL = bundle.audioURL
        if !appendToExisting, fileManager.fileExists(atPath: audioURL.path) {
            try fileManager.removeItem(at: audioURL)
        }

        emitStartupMilestone(sessionID: session.sessionID, milestone: "recorder_create_started")
        let recorder = try recorderFactory.makeRecorder(
            fileURL: audioURL,
            appendToExisting: appendToExisting,
            onUnexpectedStop: { [weak self] error in
                Task {
                    await self?.handleUnexpectedRecorderStop(generation: generation, reason: error)
                }
            },
            onConfigurationChange: { [weak self] in
                Task {
                    await self?.handleRecorderConfigurationChange(generation: generation)
                }
            },
            onStopFinished: { [weak self] successfully in
                Task {
                    await self?.handleRecorderStopFinished(generation: generation, successfully: successfully)
                }
            }
        )
        emitStartupMilestone(sessionID: session.sessionID, milestone: "recorder_create_done")
        emitStartupMilestone(sessionID: session.sessionID, milestone: "record_call_started")
        guard recorder.record() else {
            recordStartupFailure(
                sessionID: session.sessionID,
                reason: "record_returned_false",
                extra: ["error": .string("record_returned_false")]
            )
            throw VoiceCaptureError.recorderFailed("record_returned_false")
        }
        emitStartupMilestone(sessionID: session.sessionID, milestone: "record_call_done")

        recoveryRetryTask?.cancel()
        recoveryRetryTask = nil
        currentRecorder = recorder
        currentRecorderGeneration = generation
        currentBundle = bundle

        let now = Date()
        let relpath = bundle.relativePath(for: audioURL)
        let openedAt = session.audioFile?.openedAt ?? now
        session.audioFile = VoiceAudioFileSnapshot(
            relpath: relpath,
            status: .open,
            openedAt: openedAt,
            closedAt: nil,
            bytes: store.fileSize(at: audioURL),
            repairStatus: .notNeeded,
            sealReason: nil
        )
        session.heartbeatAt = now
        session.updatedAt = now
        session.blockedReason = nil
        session.blockerClearedAt = nil
        session.blockedAutoFinalizeAt = nil
        session.preferredInputUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
        if phaseAfterStart != session.phase {
            try transition(session: &session, bundle: bundle, to: phaseAfterStart, reason: reason)
        } else {
            try requireStore().persist(session: session, to: bundle)
            currentSession = session
            currentBundle = bundle
            // Seam cut (Live Activity): activity sync not ported — foreground-only P0.
        }
        currentAudioStartedAt = now
        currentAudioLastBytes = session.audioFile?.bytes ?? 0
        currentAudioLastRecorderTime = recorder.currentTime
        currentAudioLastProgressAt = session.lastProgressAt
        // Voice captures are intentionally not treated like "only while unlocked" data.
        // We already persist the session ledger with .completeUntilFirstUserAuthentication,
        // and the Action Button UX depends on the user being able to start and stop capture
        // with the screen locked after the phone has been unlocked once since boot.
        //
        // The old policy left the live CAF at .completeUnlessOpen and then proactively
        // deferred finalization whenever UIApplication.protectedDataAvailable was false.
        // That created the confusing "Finishing when unlocked" state even when the capture
        // itself was not especially sensitive and the app had enough access to durably write
        // the session ledger. Keep the CAF at .completeUntilFirstUserAuthentication so the
        // closed file can be reopened and committed without waiting for another unlock.
        try? store.setProtection(.completeUntilFirstUserAuthentication, for: audioURL)

        emit(.info, name: "voice.audio_file_started", message: "Voice audio file opened", metadata: [
            "session_id": session.sessionID,
            "capture_id": session.captureID,
            "audio_relpath": relpath,
            "append": appendToExisting ? "true" : "false",
        ])
        emitStartupMilestone(sessionID: session.sessionID, milestone: "mic_active")
        // Seam cut (AppIntents): Serein published .captureIntentBegan here so the app
        // runtime could claim the background_voice_intent lane for an Action Button start.
        // Requirement: Vo-Cal P0 capture is foreground-only — VoiceCaptureIntent is not
        // ported and no background entry mode exists to claim. Failure mode avoided: a
        // lifecycle event that wakes transport/runtime subsystems from the mic-hot path
        // (the eager-startup coupling that consumed Serein's voice authorization window).
        // Evidence: Vo-Cal AGENTS.md foreground-only master decision + capture-path
        // isolation; Serein AGENTS.md (April 2026);
        // https://developer.apple.com/forums/thread/815725
        restartMonitoringTasks(generation: generation)
    }

    private func restartMonitoringTasks(generation: VoiceOperationGeneration) {
        monitorTask?.cancel()

        monitorTask = Task {
            while !Task.isCancelled {
                await self.observeCurrentLiveness(generation: generation, waitForDrain: false)
                do {
                    try await Task.sleep(for: self.currentPollInterval())
                } catch {
                    break
                }
            }
        }
    }

    private func currentPollInterval() -> Duration {
        if kernelState.current?.recentHint != nil || kernelState.current?.recoveryMode == .nominalInputFormatChange {
            return constants.transitionalPollInterval
        }
        guard let phase = currentSession?.phase else {
            return constants.steadyPollInterval
        }
        switch phase {
        case .starting, .recordingUnverified, .resuming, .recovering, .suspectedStall:
            return constants.transitionalPollInterval
        case .arming, .blocked, .recordingLive, .stopping, .finalizing, .commitDeferred, .committed, .lost:
            return constants.steadyPollInterval
        }
    }

    private func sealCurrentAudioFile(
        session: inout VoiceSessionSnapshot,
        bundle: VoiceSessionBundle,
        reason: VoiceSegmentSealReason,
        stopRecorder: Bool,
        generation: VoiceOperationGeneration
    ) async throws {
        guard let store else {
            throw VoiceCaptureError.appGroupUnavailable
        }
        guard ensureCurrentGeneration(generation) else {
            return
        }
        if stopRecorder {
            try await stopCurrentRecorderForRestart()
            guard ensureCurrentGeneration(generation) else {
                return
            }
        }

        guard var audioFile = session.audioFile
        else {
            return
        }

        let audioURL = bundle.bundleURL.appendingPathComponent(audioFile.relpath, isDirectory: false)
        let bytes = store.fileSize(at: audioURL)
        audioFile.bytes = bytes
        audioFile.closedAt = Date()
        audioFile.sealReason = reason
        audioFile.status = bytes > 0 ? .closed : .quarantined
        session.audioFile = audioFile
        session.updatedAt = Date()
        try store.persist(session: session, to: bundle)
        currentSession = session
        currentAudioStartedAt = nil
        currentAudioLastBytes = 0
        currentAudioLastRecorderTime = 0
        currentAudioLastProgressAt = nil

        emit(.info, name: "voice.audio_file_closed", message: "Voice audio file closed", metadata: [
            "session_id": session.sessionID,
            "capture_id": session.captureID,
            "audio_relpath": audioFile.relpath,
            "bytes": "\(bytes)",
            "close_reason": reason.rawValue,
        ])
    }

    private func stopCurrentRecorderForRestart() async throws {
        let recorder = currentRecorder
        let recorderGeneration = currentRecorderGeneration
        let recorderWasRecording = recorder?.isRecording ?? false
        currentRecorder = nil
        currentRecorderGeneration = nil
        monitorTask?.cancel()
        recorder?.stop()
        if recorderWasRecording, let recorderGeneration {
            await waitForRecorderStopCompletion(generation: recorderGeneration)
        }
    }

    private func waitForRecorderStopCompletion(generation: VoiceOperationGeneration) async {
        if recorderStopCompletions.remove(generation) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            recorderStopWaiters[generation, default: []].append(continuation)
        }
    }

    private func commitFinalArtifact(
        session: inout VoiceSessionSnapshot,
        bundle: VoiceSessionBundle,
        finalURL: URL,
        generation: VoiceOperationGeneration,
        proof: VoiceDestructiveProof
    ) async throws -> VoiceToggleResult {
        guard let outbox, let deviceID else {
            throw VoiceCaptureError.deviceIdentityUnavailable
        }

        guard ensureCurrentGeneration(generation) else {
            throw VoiceCaptureError.commitDeferred("stale_generation")
        }

        // Do not preflight on UIApplication.protectedDataAvailable here. The session ledger
        // and finalized voice CAF are both intentionally readable after first unlock since
        // boot, so commit should still be attempted while the screen is locked. If a lower
        // level file or outbox operation still proves that the capture cannot be committed
        // yet, the existing commitDeferred error path below preserves the session.
        let contextObject = session.context.mapValues { $0.toJSONObject() }
        let finalByteCount = try requireStore().fileSize(at: finalURL)
        let blob = CaptureBlobPayload(
            fileURL: finalURL,
            filename: "voice.caf",
            contentType: "audio/x-caf",
            byteCount: finalByteCount
        )
        let prepared = try CaptureManifestPreparer.prepare(
            manifestObject: [
                "capture_id": session.captureID,
                "kind": "voice",
                "source": session.sourceSurface,
                "captured_at": CaptureDateCodec.internetString(session.createdAt),
                "context": contextObject,
            ],
            deviceID: deviceID,
            blob: blob,
            sourceSurface: session.sourceSurface
        )
        let receipt = try outbox.enqueue(prepared: prepared, blob: blob)

        guard assertDestructivePreconditions(proof: proof, session: session, generation: generation, action: "remove_bundle_after_commit") else {
            throw VoiceCaptureError.commitDeferred("stale_generation")
        }

        session.pendingCommitReason = nil
        try transition(session: &session, bundle: bundle, to: .committed, reason: "outbox_enqueue_succeeded")
        try requireStore().persist(session: session, to: bundle)
        emit(.notice, name: "voice.outbox_committed", message: "Voice capture committed to outbox", metadata: [
            "session_id": session.sessionID,
            "capture_id": session.captureID,
            "blob_content_type": "audio/x-caf",
        ])
        emitStartupMilestone(sessionID: session.sessionID, milestone: "saved")
        removeStartupObservation(sessionID: session.sessionID)
        // Seam cut (Live Activity): Serein ended the recording Live Activity here. Not
        // ported — foreground-only P0. See the prerequisites seam why-comment.
        //
        // C4 attachment point: hand the durable commit receipt to the (no-op until C4)
        // commit observer. Fire-and-forget on purpose — "Saved" is already true at this
        // point and must never wait on transport. See CaptureCommitObserver's why-comment.
        let observer = commitObserver
        Task {
            await observer.captureCommitted(receipt)
        }
        try requireStore().removeBundle(bundle)
        resetCurrentSessionHandles()
        await audioSessionController.deactivate()
        return VoiceToggleResult(action: .finalized(captureID: session.captureID), sessionID: session.sessionID)
    }

    private func configureAudioSession(preferredInputUID: String?) async throws {
        let usesMixWithOthers = currentAudioSessionUsesMixWithOthers
        try await audioSessionController.configureForCapture(
            usesMixWithOthers: usesMixWithOthers,
            preferredInputUID: preferredInputUID
        )
    }

    private func recoveryRetryClass(
        _ error: VoiceCaptureError,
        reason: VoiceSegmentSealReason
    ) -> VoiceRetryClass? {
        guard reason == .routeChange || reason == .stallRecovery || reason == .interruption || reason == .inputFormatChange else {
            return nil
        }
        if reason == .inputFormatChange {
            return .selfHealing
        }
        guard case let .recorderFailed(rawReason) = error else {
            return .selfHealing
        }
        if rawReason.contains("NSOSStatusErrorDomain:560557684")
            || rawReason.contains("session_activation_failed")
            || rawReason.contains("osstatus_error_560557684")
            || rawReason.contains("!int")
            || rawReason.contains("app_was_suspended")
        {
            return .externalBlocker
        }
        return .selfHealing
    }

    private static func interruptionReason(from note: Notification) -> VoiceInterruptionReason {
        let rawValue = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.uintValue ?? 0
        switch rawValue {
        case 0:
            return .system
        case 1:
            return .appWasSuspended
        case 2:
            return .builtInMicMuted
        default:
            return .unknown
        }
    }

    private func deferPendingCommit(
        session: inout VoiceSessionSnapshot,
        bundle: VoiceSessionBundle,
        reason: String
    ) async -> VoiceToggleResult {
        session.pendingCommitReason = reason
        do {
            if session.phase == .commitDeferred {
                session.updatedAt = Date()
                session.heartbeatAt = session.updatedAt
                try requireStore().persist(session: session, to: bundle)
                currentSession = session
                currentBundle = bundle
                // Seam cut (Live Activity): activity sync not ported — foreground-only P0.
            } else {
                try transition(session: &session, bundle: bundle, to: .commitDeferred, reason: reason)
            }
        } catch {
            await recordError("voice_commit_deferred_persist_failed", error: error)
        }
        emit(.warning, name: "voice.commit_deferred", message: "Voice commit deferred until capture can be finalized", metadata: [
            "session_id": session.sessionID,
            "capture_id": session.captureID,
            "reason": reason,
            "final_blob_present": session.finalBlobRelpath == nil ? "false" : "true",
        ])
        currentSession = session
        currentBundle = bundle
        return VoiceToggleResult(action: .deferred(captureID: session.captureID), sessionID: session.sessionID)
    }

    private func transition(
        session: inout VoiceSessionSnapshot,
        bundle: VoiceSessionBundle,
        to phase: VoiceCapturePhase,
        reason: String
    ) throws {
        let previous = session.phase
        session.phase = phase
        session.updatedAt = Date()
        session.heartbeatAt = session.updatedAt
        try requireStore().persist(session: session, to: bundle)
        currentSession = session
        currentBundle = bundle
        recordPhase(session.captureID, phase: phase)
        emit(.notice, name: "voice.phase_changed", message: "Voice phase changed", metadata: [
            "session_id": session.sessionID,
            "capture_id": session.captureID,
            "from": previous.rawValue,
            "to": phase.rawValue,
            "reason": reason,
        ])
        // Seam cut (Live Activity): activity sync not ported — foreground-only P0.
    }

    private func handleStartFailure(
        _ error: VoiceCaptureError,
        generation: VoiceOperationGeneration,
        session: VoiceSessionSnapshot
    ) async {
        guard ensureCurrentGeneration(generation),
              let bundle = bundleForSessionID(session.sessionID)
        else {
            return
        }
        let previousPhase = currentSession?.phase ?? session.phase
        var lostSession = session
        lostSession.phase = .lost
        lostSession.failureReason = error.localizedDescription
        lostSession.updatedAt = Date()
        lostSession.heartbeatAt = lostSession.updatedAt

        do {
            try requireStore().persist(session: lostSession, to: bundle)
        } catch {
            await recordError("voice_start_failure_persist_failed", error: error)
        }

        recordPhase(lostSession.captureID, phase: lostSession.phase)
        emit(.notice, name: "voice.phase_changed", message: "Voice phase changed", metadata: [
            "session_id": lostSession.sessionID,
            "capture_id": lostSession.captureID,
            "from": previousPhase.rawValue,
            "to": lostSession.phase.rawValue,
            "reason": "startup_failed",
        ])
        emit(.error, name: "voice.start_failed", message: "Voice start failed", metadata: [
            "session_id": lostSession.sessionID,
            "capture_id": lostSession.captureID,
            "phase": previousPhase.rawValue,
            "reason": lostSession.failureReason ?? error.localizedDescription,
            "host_bundle_id": self.bundle.bundleIdentifier ?? "unknown",
            "host_process": ProcessInfo.processInfo.processName,
        ])
        // Seam cut (Live Activity): activity end not ported — foreground-only P0.
        _ = try? requireStore().moveToQuarantine(bundle)
        await audioSessionController.deactivate()
        resetCurrentSessionHandles()
    }

    private func handleFinalizeFailure(
        _ error: Error,
        session: VoiceSessionSnapshot,
        bundle: VoiceSessionBundle,
        generation: VoiceOperationGeneration,
        proof: VoiceDestructiveProof
    ) async -> VoiceToggleResult {
        guard assertDestructivePreconditions(proof: proof, session: session, generation: generation, action: "quarantine_failed_session") else {
            return VoiceToggleResult(action: .lost(captureID: session.captureID), sessionID: session.sessionID)
        }
        var lostSession = session
        lostSession.failureReason = error.localizedDescription
        if case .noRecoverableAudio = error as? VoiceCaptureError {
            assertImplication(
                true,
                (lostSession.audioFile?.bytes ?? 0) <= VoiceCAFMuxer.headerByteCount,
                message: "positive-byte audio file may not be lost as no_recoverable_audio",
                metadata: [
                    "session_id": lostSession.sessionID,
                    "capture_id": lostSession.captureID,
                    "generation": "\(generation)",
                ]
            )
        }
        do {
            try transition(session: &lostSession, bundle: bundle, to: .lost, reason: "no_recoverable_audio")
            try requireStore().persist(session: lostSession, to: bundle)
        } catch {
            await recordError("voice_quarantine_persist_failed", error: error)
        }
        // Seam cut (Live Activity): activity end not ported — foreground-only P0.
        _ = try? requireStore().moveToQuarantine(bundle)
        resetCurrentSessionHandles()
        await audioSessionController.deactivate()
        emit(.error, name: "voice.session_quarantined", message: "Voice session moved to quarantine", metadata: [
            "session_id": lostSession.sessionID,
            "capture_id": lostSession.captureID,
            "reason": error.localizedDescription,
        ])
        return VoiceToggleResult(action: .lost(captureID: lostSession.captureID), sessionID: lostSession.sessionID)
    }

    private func cancelObservationTasks() {
        monitorTask?.cancel()
        for task in observationTasks {
            task.cancel()
        }
        observationTasks.removeAll()
    }

    private func resetCurrentSessionHandles() {
        currentBundle = nil
        currentSession = nil
        currentRecorder = nil
        currentRecorderGeneration = nil
        currentAudioSessionUsesMixWithOthers = false
        currentAudioStartedAt = nil
        currentAudioLastBytes = 0
        currentAudioLastRecorderTime = 0
        currentAudioLastProgressAt = nil
        monitorTask?.cancel()
        recoveryRetryTask?.cancel()
        recoveryRetryTask = nil
    }

    private func syncCurrentSessionFromKernel() {
        currentSession = kernelState.current?.snapshot
        currentAudioSessionUsesMixWithOthers = kernelState.current?.mixWithOthers ?? false
        // Seam cut (Live Activity): Serein diffed the previous session here to sync or end
        // the Live Activity on kernel transitions. Not ported — foreground-only P0. See
        // the prerequisites seam why-comment.
    }

    private func microphonePermissionGranted() -> Bool {
        let permission = microphonePermissionOverride ?? liveMicrophonePermissionStatus()
        return permission == .granted
    }

    private func microphonePermissionStatusName() -> String {
        switch microphonePermissionOverride ?? liveMicrophonePermissionStatus() {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .undetermined:
            return "undetermined"
        @unknown default:
            return "unknown"
        }
    }

    private func liveMicrophonePermissionStatus() -> VoiceMicrophonePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .undetermined
        @unknown default:
            return .undetermined
        }
    }

    private func protectedDataAvailable() async -> Bool {
        if let protectedDataAvailabilityOverride {
            return protectedDataAvailabilityOverride
        }
        return await Self.currentProtectedDataAvailability()
    }

    @MainActor
    private static func currentProtectedDataAvailability() -> Bool {
        guard let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type else {
            return true
        }
        guard let application = applicationClass.value(forKey: "sharedApplication") as? NSObject else {
            return true
        }
        return (application.value(forKey: "protectedDataAvailable") as? Bool) ?? true
    }

    private func bundleForSessionID(_ sessionID: String?) -> VoiceSessionBundle? {
        guard let sessionID, let store else {
            return nil
        }
        let candidate = store.bundle(sessionID: sessionID)
        if fileManager.fileExists(atPath: candidate.bundleURL.path) {
            return candidate
        }
        return currentBundle?.bundleURL.lastPathComponent == sessionID ? currentBundle : nil
    }

    private func sessionOwnership(
        bundle: VoiceSessionBundle,
        session: VoiceSessionSnapshot
    ) -> VoiceSessionOwnership {
        guard currentBundle?.bundleURL == bundle.bundleURL,
              currentSession?.sessionID == session.sessionID
        else {
            return .unowned
        }
        return .ownedByCurrentProcess
    }

    private func ensureCurrentGeneration(_ generation: VoiceOperationGeneration?) -> Bool {
        guard let generation else {
            return true
        }
        return kernelState.current?.generation == generation
    }

    @discardableResult
    private func assertDestructivePreconditions(
        proof: VoiceDestructiveProof,
        session: VoiceSessionSnapshot,
        generation: VoiceOperationGeneration?,
        action: String
    ) -> Bool {
        if let expectedGeneration = proof.generation {
            assertImplication(
                true,
                generation == expectedGeneration,
                message: "destructive action generation proof mismatch",
                metadata: [
                    "session_id": session.sessionID,
                    "capture_id": session.captureID,
                    "action": action,
                    "expected_generation": "\(expectedGeneration)",
                    "actual_generation": "\(generation ?? 0)",
                ]
            )
            guard ensureCurrentGeneration(expectedGeneration) else {
                return false
            }
        }

        if proof.recoveryDecision == .staleOrOrphaned {
            assertImplication(
                true,
                proof.ownership != .ownedByCurrentProcess,
                message: "owned session may not be finalized as stale_or_orphaned",
                metadata: [
                    "session_id": session.sessionID,
                    "capture_id": session.captureID,
                    "action": action,
                ]
            )
        }

        if proof.reason == .recoveryCommit {
            assertImplication(
                true,
                session.finalBlobRelpath != nil || session.phase == .commitDeferred,
                message: "recovery resume requires deferred session state or final blob",
                metadata: [
                    "session_id": session.sessionID,
                    "capture_id": session.captureID,
                    "action": action,
                ]
            )
        }

        if let generation, proof.reason == .recoveryClassification {
            assertImplication(
                session.phase.isActiveRecording,
                currentRecorder == nil || currentRecorderGeneration == generation,
                message: "active recording phase must match recorder generation",
                metadata: [
                    "session_id": session.sessionID,
                    "capture_id": session.captureID,
                    "action": action,
                    "generation": "\(generation)",
                ]
            )
        }

        return true
    }

    private func requireCurrentGeneration(
        _ generation: VoiceOperationGeneration,
        proof: VoiceDestructiveProof,
        action: String
    ) throws {
        guard assertDestructivePreconditions(
            proof: proof,
            session: currentSession ?? VoiceSessionSnapshot(
                sessionID: proof.sessionID,
                captureID: "unknown",
                phase: .arming,
                sourceSurface: CaptureSourceSurface.nativeRecorder.rawValue,
                createdAt: Date(),
                updatedAt: Date(),
                heartbeatAt: Date(),
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
            ),
            generation: generation,
            action: action
        ) else {
            throw VoiceCaptureError.commitDeferred("stale_generation")
        }
    }

    private func assertImplication(
        _ antecedent: Bool,
        _ consequent: @autoclosure () -> Bool,
        message: String,
        metadata: [String: String]
    ) {
        guard antecedent else {
            return
        }
        guard consequent() else {
            emit(.error, name: "voice.kernel_assertion_failed", message: message, metadata: metadata)
            preconditionFailure(message)
        }
    }

    private func requireStore() throws -> VoiceSessionStore {
        guard let store else {
            throw VoiceCaptureError.appGroupUnavailable
        }
        return store
    }

    private func recordPhase(_ captureID: String, phase: VoiceCapturePhase) {
        var phases = phaseHistoryByCaptureID[captureID] ?? []
        if phases.last != phase {
            phases.append(phase)
        }
        phaseHistoryByCaptureID[captureID] = phases
    }

    private func shouldTrackStartupObservation(for phase: VoiceCapturePhase?) -> Bool {
        switch phase {
        case .some(let phase) where phase.isActiveRecording:
            return false
        case .some(.finalizing), .some(.commitDeferred):
            return false
        case .none, .some(.arming), .some(.starting), .some(.recordingUnverified), .some(.recordingLive), .some(.suspectedStall), .some(.blocked), .some(.resuming), .some(.recovering), .some(.stopping), .some(.committed), .some(.lost):
            return true
        }
    }

    private func makeStartupObservation(
        request: VoicePendingToggleRequest,
        executionMode: ObservabilityExecutionMode,
        processCold: Bool,
        voiceBootstrapCold: Bool,
        entryMode: AppEntryMode,
        runID: String?
    ) async -> VoiceStartupObservation {
        var baseAttributes: [String: ObservabilityScalar] = [
            "request_id": .string(request.requestID.uuidString.lowercased()),
            "source_surface": .string(request.sourceSurface),
            "reason": .string(request.reason),
            "execution_mode": .string(executionMode.rawValue),
            "process_cold": .bool(processCold),
            "voice_bootstrap_cold": .bool(voiceBootstrapCold),
            "entry_mode": .string(entryMode.rawValue),
            "lane": .string(RuntimeLane.voiceCapture.rawValue),
        ]
        if let runID, !runID.isEmpty {
            baseAttributes["run_id"] = .string(runID)
        }
        let existingSession = currentSession
        return VoiceStartupObservation(
            requestID: request.requestID,
            handle: await observabilityClient.beginOperation(
                name: "voice_startup",
                attributes: baseAttributes
            ),
            sessionID: existingSession?.sessionID ?? request.reservedSessionID,
            captureID: existingSession?.captureID ?? request.reservedCaptureID
        )
    }

    private func storeStartupObservation(_ observation: VoiceStartupObservation) {
        let operationID = observation.handle.operationID
        startupObservationsByOperationID[operationID] = observation
        startupOperationIDByRequestID[observation.requestID] = operationID
        if let sessionID = observation.sessionID {
            startupOperationIDBySessionID[sessionID] = operationID
        }
    }

    private func updateStartupObservationIdentity(
        requestID: UUID? = nil,
        sessionID: String? = nil,
        captureID: String? = nil
    ) {
        let operationID: String?
        if let requestID {
            operationID = startupOperationIDByRequestID[requestID]
        } else if let sessionID {
            operationID = startupOperationIDBySessionID[sessionID]
        } else {
            operationID = nil
        }
        guard let operationID,
              var observation = startupObservationsByOperationID[operationID]
        else {
            return
        }
        let previousSessionID = observation.sessionID
        if let sessionID {
            observation.sessionID = sessionID
        }
        if let captureID {
            observation.captureID = captureID
        }
        startupObservationsByOperationID[operationID] = observation
        if let requestID {
            startupOperationIDByRequestID[requestID] = operationID
        }
        if let previousSessionID, previousSessionID != observation.sessionID {
            startupOperationIDBySessionID.removeValue(forKey: previousSessionID)
        }
        if let sessionID = observation.sessionID {
            startupOperationIDBySessionID[sessionID] = operationID
        }
    }

    private func unlinkStartupObservationRequestID(_ requestID: UUID) {
        startupOperationIDByRequestID.removeValue(forKey: requestID)
    }

    private func emitStartupMilestone(
        requestID: UUID,
        milestone: String,
        extra: [String: ObservabilityScalar] = [:]
    ) {
        guard let operationID = startupOperationIDByRequestID[requestID],
              let observation = startupObservationsByOperationID[operationID]
        else {
            return
        }
        observation.handle.milestone(milestone, attributes: observation.attributes(extra: extra))
    }

    private func emitStartupMilestone(
        sessionID: String,
        milestone: String,
        extra: [String: ObservabilityScalar] = [:]
    ) {
        guard let operationID = startupOperationIDBySessionID[sessionID],
              let observation = startupObservationsByOperationID[operationID]
        else {
            return
        }
        observation.handle.milestone(milestone, attributes: observation.attributes(extra: extra))
    }

    @discardableResult
    private func removeStartupObservation(requestID: UUID? = nil, sessionID: String? = nil) -> VoiceStartupObservation? {
        let operationID: String?
        if let requestID {
            operationID = startupOperationIDByRequestID.removeValue(forKey: requestID)
        } else if let sessionID {
            operationID = startupOperationIDBySessionID.removeValue(forKey: sessionID)
        } else {
            operationID = nil
        }
        guard let operationID,
              let observation = startupObservationsByOperationID.removeValue(forKey: operationID)
        else {
            return nil
        }
        startupOperationIDByRequestID.removeValue(forKey: observation.requestID)
        if let sessionID = observation.sessionID {
            startupOperationIDBySessionID.removeValue(forKey: sessionID)
        }
        return observation
    }

    private func recordStartupFailure(
        requestID: UUID? = nil,
        sessionID: String? = nil,
        reason: String,
        extra: [String: ObservabilityScalar] = [:]
    ) {
        guard let observation = removeStartupObservation(requestID: requestID, sessionID: sessionID) else {
            return
        }
        var attributes = observation.attributes(extra: extra)
        attributes["failure_reason"] = .string(reason)
        observation.handle.milestone("start_failed", attributes: attributes)
    }

    private func refreshPreferredInputFromCurrentRoute(_ preferredInputUID: String? = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid) {
        if var session = currentSession {
            session.preferredInputUID = preferredInputUID
            currentSession = session
        }
        if var managed = kernelState.current {
            managed.snapshot.preferredInputUID = preferredInputUID
            kernelState.current = managed
        }
    }

    private func maybeEmitLiveConfirmation(
        previous: VoiceKernelManagedSession?,
        current: VoiceKernelManagedSession?
    ) async {
        guard let current,
              current.snapshot.phase == .recordingLive,
              previous?.snapshot.phase != .recordingLive,
              !(previous?.toggleRequestIDs.isEmpty ?? true)
        else {
            return
        }
        emitStartupMilestone(sessionID: current.snapshot.sessionID, milestone: "confirmed_listening")
        await emitLiveConfirmationHaptic()
    }

    @MainActor
    private func emitLiveConfirmationHaptic() {
        guard UIApplication.shared.connectedScenes.contains(where: { scene in
            scene.activationState == .foregroundActive
        }) else {
            return
        }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    private func routeMetadata(_ note: Notification) -> [String: String] {
        let observation = Self.routeChangeObservation(from: note)
        var metadata = [
            "reason": observation?.reason.rawValue ?? VoiceRouteChangeReason.unknown.rawValue,
            "reason_name": observation?.reason.rawValue ?? VoiceRouteChangeReason.unknown.rawValue,
        ]
        if let previousInputUID = observation?.previousInputUID {
            metadata["previous_input_uid"] = previousInputUID
        }
        if let currentInputUID = observation?.currentInputUID {
            metadata["current_input_uid"] = currentInputUID
        }
        return metadata
    }

    private func recordError(_ name: String, error: Error) async {
        lastError = error.localizedDescription
        emit(.error, name: name, message: error.localizedDescription)
    }

    private func captureError(from error: Error) -> VoiceCaptureError {
        if let typed = error as? VoiceCaptureError {
            return typed
        }
        return .recorderFailed(normalizedFailureReason(for: error))
    }

    private func normalizedFailureReason(for error: Error) -> String {
        let nsError = error as NSError
        let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactDescription = description.isEmpty ? "unknown" : description.replacingOccurrences(of: " ", with: "_").lowercased()
        return "\(nsError.domain):\(nsError.code):\(compactDescription)"
    }

    private func emit(
        _ level: CaptureDebugLevel = .info,
        name: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        CaptureDebugRecorder.shared.emit(
            level,
            name: name,
            message: message,
            metadata: metadata,
            appGroupRoot: debugLogRootOverride ?? appGroupRoot
        )
    }

    static func classifySessionRecovery(
        session: VoiceSessionSnapshot,
        trigger: VoiceRecoveryTrigger,
        ownership: VoiceSessionOwnership,
        now: Date,
        outboxCommitted: Bool,
        constants: VoiceCaptureConstants
    ) -> VoiceSessionRecoveryDecision {
        VoiceCoordinatorKernel(constants: constants).classifySessionRecovery(
            session: session,
            trigger: trigger,
            ownership: ownership,
            now: now,
            outboxCommitted: outboxCommitted
        )
    }

    static func classifyRouteChange(_ reason: AVAudioSession.RouteChangeReason?) -> VoiceRouteChangeDisposition {
        VoiceCoordinatorKernel(constants: .init()).classifyRouteChange(
            VoiceRouteChangeObservation(
                reason: mapRouteReason(reason),
                inputRouteChanged: nil
            )
        )
    }

    private static func mapRouteReason(_ reason: AVAudioSession.RouteChangeReason?) -> VoiceRouteChangeReason {
        guard let reason else {
            return .unknown
        }
        switch reason {
        case .newDeviceAvailable:
            return .newDeviceAvailable
        case .oldDeviceUnavailable:
            return .oldDeviceUnavailable
        case .override:
            return .override
        case .categoryChange:
            return .categoryChange
        case .routeConfigurationChange:
            return .routeConfigurationChange
        case .noSuitableRouteForCategory:
            return .noSuitableRouteForCategory
        case .wakeFromSleep:
            return .wakeFromSleep
        case .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private static func routeChangeObservation(from note: Notification) -> VoiceRouteChangeObservation? {
        let reasonValue = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        guard let reason else {
            return nil
        }
        let previousRoute = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        let previousInputUID = previousRoute?.inputs.first?.uid
        let currentInputUID = currentRoute.inputs.first?.uid
        return VoiceRouteChangeObservation(
            reason: mapRouteReason(reason),
            inputRouteChanged: previousInputUID.flatMap { previous in
                guard let currentInputUID else {
                    return true
                }
                return previous != currentInputUID
            },
            previousInputUID: previousInputUID,
            currentInputUID: currentInputUID
        )
    }

    private func captureAlreadyCommitted(captureID: String) throws -> Bool {
        guard let outbox else {
            return false
        }
        return try outbox.capture(captureID: captureID) != nil
    }

    private func currentRouteHasUsableInput() -> Bool {
        !AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty
    }

    private func shouldClearBlockedState(from source: String, reason: VoiceBlockedReason?) -> Bool {
        switch source {
        case "interruption_ended":
            return true
        case VoiceRecoveryTrigger.sceneActive.rawValue, VoiceRecoveryTrigger.protectedDataAvailable.rawValue:
            switch reason {
            case .interruption, .appWasSuspended, .builtInMicMuted, .audioSessionUnavailable:
                return true
            case .routeLoss, .noSuitableRoute, .none:
                return false
            }
        case "route_available":
            switch reason {
            case .routeLoss, .noSuitableRoute:
                return true
            case .interruption, .appWasSuspended, .builtInMicMuted, .audioSessionUnavailable, .none:
                return false
            }
        default:
            return false
        }
    }
}
