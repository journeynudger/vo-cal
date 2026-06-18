import AVFoundation
import Foundation
import VoCalCapture
import VoCalVoice
import SwiftUI
import Synchronization

// Port provenance: Serein apps/ios/SereinApp/Sources/VoiceSelfTestRuntime.swift,
// trimmed to Vo-Cal's foreground-only P0 and renamed (SereinCapture/SereinVoice →
// VoCalCapture/VoCalVoice; CaptureRelayDebugRecorder/Level → CaptureDebugRecorder/Level;
// serein:// → vocal://; entry flag --voice-self-test-run-id → --self-test-run-id to
// match the launch arg AppRuntimeCoordinator already keys on).
//
// This is the C3 runtime gate: it instantiates a *real* VoiceCaptureCoordinator (the
// committed C1/C2 port) backed by a deterministic in-process recorder harness, runs it
// through the failure-class scenarios, and asserts the claim ladder, the filesystem
// ledger, crash recovery, and the committed CAF never lie. It writes structured
// `voice.self_test.*` events to debug-events.jsonl, which bin/ios-sim-voice-test tails.
//
// Scenario trim vs Serein (requirement / what was dropped / why):
//   Requirement: Vo-Cal P0 capture is foreground-only — VoiceCaptureIntent and
//   VoiceLiveActivity are NOT ported (Vo-Cal AGENTS.md master decision; phase plan C3).
//   Dropped: Serein had no intent/Live-Activity *self-test* scenario in this file, so
//   nothing about ActivityKit cold-start is exercised here either way; what we drop are
//   the lifecycle/route *duplicates* that proved the same invariant Vo-Cal proves once.
//   Serein ran 11 scenarios: golden_path, hint_only_route_noise, audio_interruption,
//   category_change_route, old_device_unavailable, media_services_reset,
//   app_suspended_interruption, lock_unlock_lifecycle, process_death_recovery,
//   permission_missing, blocked_deadline_expiry. Vo-Cal keeps the 9 that map to the C3
//   acceptance list and consolidates the redundant route/lifecycle variants:
//     1. golden_path                ← Serein golden_path (direct)
//     2. audio_interruption         ← Serein audio_interruption (direct; pause→seal→
//                                      no-auto-resume→manual resume; INVARIANTS §3/§6)
//     3. route_change_resilience    ← Serein category_change_route (direct; a
//                                      .categoryChange route note is an observation, not
//                                      a teardown command — Serein paid 5 bugs for that)
//     4. process_death_recovery     ← Serein process_death_recovery (direct; recovery
//                                      runs on storage observations, never in-memory state)
//     5. permission_denial          ← Serein permission_missing (direct; fail fast, no
//                                      orphan active bundle)
//     6. blocked_deadline_finalize  ← Serein blocked_deadline_expiry (direct; 5-min →
//                                      1s override auto-finalize after blocker clears)
//     7. stall_detection            ← NEW: byte-flow stops with no recovery route; the
//                                      coordinator must detect the stall and converge
//                                      (suspectedStall → recover/seal), never wedge live.
//     8. caf_repair_on_recovery     ← NEW: plant an open/truncated CAF + live session
//                                      bundle, relaunch; recovery must repair + commit a
//                                      valid CAF (INVARIANTS §6 crash-during-recording).
//     9. quarantine_on_corruption   ← NEW: plant a corrupt session bundle; the scan must
//                                      quarantine it and surface the event — lost, but
//                                      never silent (INVARIANTS §4/§6).
//   Consolidated-away (each proved an invariant 7/3/4 already cover, and adding them
//   would only re-exercise the route classifier or the scene-active rescan path):
//   hint_only_route_noise, old_device_unavailable, media_services_reset,
//   app_suspended_interruption, lock_unlock_lifecycle.

private enum VoiceSelfTestScenario: String, CaseIterable, Sendable {
    case goldenPath = "golden_path"
    case audioInterruption = "audio_interruption"
    case routeChangeResilience = "route_change_resilience"
    case processDeathRecovery = "process_death_recovery"
    case permissionDenial = "permission_denial"
    case blockedDeadlineFinalize = "blocked_deadline_finalize"
    case stallDetection = "stall_detection"
    case cafRepairOnRecovery = "caf_repair_on_recovery"
    case quarantineOnCorruption = "quarantine_on_corruption"

    static let defaultScenarios: [VoiceSelfTestScenario] = [
        .goldenPath,
        .audioInterruption,
        .routeChangeResilience,
        .processDeathRecovery,
        .permissionDenial,
        .blockedDeadlineFinalize,
        .stallDetection,
        .cafRepairOnRecovery,
        .quarantineOnCorruption,
    ]
}

private struct VoiceSelfTestScenarioOutcome: Sendable {
    let captureID: String?
    let trace: String
}

private struct VoiceSelfTestScenarioFailure: LocalizedError {
    let reason: String
    let trace: String

    var errorDescription: String? { reason }
}

private let appWasSuspendedInterruptionReasonRawValue: UInt = 1

actor VoiceSelfTestRuntime {
    static let shared = VoiceSelfTestRuntime()

    private let bundle: Bundle
    private let notificationCenter: NotificationCenter
    private let clock = ContinuousClock()
    private var runTask: Task<Void, Never>?

    init(
        bundle: Bundle = .main,
        notificationCenter: NotificationCenter = .default
    ) {
        self.bundle = bundle
        self.notificationCenter = notificationCenter
    }

    nonisolated func startIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let flagIndex = arguments.firstIndex(of: "--self-test-run-id") else {
            return
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else {
            return
        }
        let runID = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runID.isEmpty else {
            return
        }
        let scenarios = Self.parseScenarioList(
            arguments: arguments,
            flag: "--self-test-scenarios"
        ) ?? VoiceSelfTestScenario.defaultScenarios
        Task {
            await self.start(runID: runID, source: "launch_argument", scenarios: scenarios)
        }
    }

    @discardableResult
    nonisolated func handleOpenURL(_ url: URL) -> Bool {
        guard let request = Self.request(from: url) else {
            return false
        }
        Task {
            await self.start(runID: request.runID, source: "url_scheme", scenarios: request.scenarios)
        }
        return true
    }

    private func start(
        runID: String,
        source: String,
        scenarios: [VoiceSelfTestScenario] = VoiceSelfTestScenario.defaultScenarios
    ) async {
        runTask?.cancel()
        runTask = Task {
            await self.runSelfTest(runID: runID, source: source, scenarios: scenarios)
        }
        await runTask?.value
    }

    private func runSelfTest(
        runID: String,
        source: String,
        scenarios: [VoiceSelfTestScenario]
    ) async {
        do {
            let fileManager = FileManager()
            let sharedRoot = try AppGroupConfig.sharedContainerURL(fileManager: fileManager, bundle: bundle)
            let deviceID = try DeviceIdentityStore.loadOrCreateDeviceID(bundle: bundle)
            try await CaptureDebugRecorder.shared.configure(appGroupRoot: sharedRoot)

            emit(
                name: "voice.self_test.started",
                message: "Voice self-test run started",
                metadata: [
                    "run_id": runID,
                    "source": source,
                    "scenarios": scenarios.map(\.rawValue).joined(separator: ","),
                ],
                appGroupRoot: sharedRoot
            )

            var passedCount = 0
            var failedCount = 0

            for scenario in scenarios {
                guard !Task.isCancelled else {
                    return
                }
                emit(
                    name: "voice.self_test.scenario_started",
                    message: "Voice self-test scenario started",
                    metadata: [
                        "run_id": runID,
                        "scenario": scenario.rawValue,
                    ],
                    appGroupRoot: sharedRoot
                )

                do {
                    let outcome = try await executeScenario(
                        scenario,
                        runID: runID,
                        sharedRoot: sharedRoot,
                        deviceID: deviceID
                    )
                    passedCount += 1
                    emit(
                        level: .notice,
                        name: "voice.self_test.scenario_passed",
                        message: "Voice self-test scenario passed",
                        metadata: [
                            "run_id": runID,
                            "scenario": scenario.rawValue,
                            "capture_id": outcome.captureID ?? "",
                            "trace": outcome.trace,
                        ],
                        appGroupRoot: sharedRoot
                    )
                } catch {
                    failedCount += 1
                    let failure: VoiceSelfTestScenarioFailure
                    if let typedFailure = error as? VoiceSelfTestScenarioFailure {
                        failure = typedFailure
                    } else {
                        failure = VoiceSelfTestScenarioFailure(
                            reason: error.localizedDescription,
                            trace: "none"
                        )
                    }
                    emit(
                        level: .error,
                        name: "voice.self_test.scenario_failed",
                        message: "Voice self-test scenario failed",
                        metadata: [
                            "run_id": runID,
                            "scenario": scenario.rawValue,
                            "reason": failure.reason,
                            "trace": failure.trace,
                        ],
                        appGroupRoot: sharedRoot
                    )
                }
            }

            emit(
                level: failedCount == 0 ? .notice : .error,
                name: "voice.self_test.completed",
                message: "Voice self-test run completed",
                metadata: [
                    "run_id": runID,
                    "scenarios": scenarios.map(\.rawValue).joined(separator: ","),
                    "passed_count": "\(passedCount)",
                    "failed_count": "\(failedCount)",
                    "result": failedCount == 0 ? "pass" : "fail",
                ],
                appGroupRoot: sharedRoot
            )
        } catch {
            fputs("voice self-test failed before logging could start: \(error.localizedDescription)\n", stderr)
        }
    }

    private func executeScenario(
        _ scenario: VoiceSelfTestScenario,
        runID: String,
        sharedRoot: URL,
        deviceID: String
    ) async throws -> VoiceSelfTestScenarioOutcome {
        let isolatedRoot = try prepareScenarioRoot(sharedRoot: sharedRoot, runID: runID, scenario: scenario)
        let constants: VoiceCaptureConstants
        switch scenario {
        case .blockedDeadlineFinalize:
            constants = VoiceCaptureConstants(blockedAutoFinalizeInterval: .seconds(1))
        case .stallDetection:
            // Tighten the stall windows so the scenario converges in test time instead
            // of the dogfood defaults (1.5s suspected / 3s hard). The *behavior* under
            // test is unchanged — only the deadlines shrink.
            constants = VoiceCaptureConstants(
                suspectedStallAfter: .milliseconds(300),
                hardStallAfter: .milliseconds(800)
            )
        default:
            constants = VoiceCaptureConstants()
        }
        // Each scenario gets its OWN NotificationCenter, not .default. Requirement:
        // scenarios run sequentially in one process, and audio interruption / route
        // notifications are posted to the singleton AVAudioSession; if every scenario's
        // coordinator observed the same center, a posted interruption in one scenario
        // would also be delivered to prior coordinators whose `for await` observation had
        // not finished cancelling — cross-scenario interference that hung audio_interruption
        // intermittently (observed 2026-06-18: run passed once, then wedged after
        // golden_path on rerun). Isolating the center decouples scenarios completely, the
        // same way each scenario already gets an isolated app-group root. The production
        // coordinator is unchanged — it correctly uses the injected center.
        let scenarioCenter = NotificationCenter()
        let recorderHarness = VoiceSelfTestRecorderHarness()
        let coordinator = VoiceCaptureCoordinator(
            bundle: bundle,
            fileManager: FileManager(),
            notificationCenter: scenarioCenter,
            constants: constants,
            recorderFactory: VoiceSelfTestRecorderFactory(harness: recorderHarness),
            configureSharedObservability: false,
            explicitAppGroupRoot: isolatedRoot,
            explicitDeviceID: deviceID,
            debugLogRootOverride: sharedRoot
        )
        let outbox = try CaptureOutbox(appGroupRoot: isolatedRoot, fileManager: FileManager())

        // caf_repair_on_recovery and quarantine_on_corruption plant filesystem state
        // *before* the coordinator bootstraps, then let crash recovery discover it.
        switch scenario {
        case .cafRepairOnRecovery:
            try plantTruncatedRecoverableSession(root: isolatedRoot)
        case .quarantineOnCorruption:
            try plantCorruptSession(root: isolatedRoot)
        default:
            break
        }
        _ = deviceID

        await coordinator.applicationDidFinishLaunching()

        var captureID: String?
        do {
            switch scenario {
            case .goldenPath:
                captureID = try await runGoldenPath(coordinator: coordinator, outbox: outbox, runID: runID)
            case .audioInterruption:
                captureID = try await runAudioInterruption(
                    coordinator: coordinator,
                    outbox: outbox,
                    notificationCenter: scenarioCenter,
                    runID: runID
                )
            case .routeChangeResilience:
                captureID = try await runRouteChangeResilience(
                    coordinator: coordinator,
                    outbox: outbox,
                    recorderHarness: recorderHarness,
                    notificationCenter: scenarioCenter,
                    runID: runID
                )
            case .processDeathRecovery:
                captureID = try await runProcessDeathRecovery(
                    coordinator: coordinator,
                    outbox: outbox,
                    recorderHarness: recorderHarness,
                    runID: runID
                )
            case .permissionDenial:
                captureID = try await runPermissionDenial(coordinator: coordinator, runID: runID)
            case .blockedDeadlineFinalize:
                captureID = try await runBlockedDeadlineFinalize(
                    coordinator: coordinator,
                    outbox: outbox,
                    notificationCenter: scenarioCenter,
                    runID: runID
                )
            case .stallDetection:
                captureID = try await runStallDetection(
                    coordinator: coordinator,
                    outbox: outbox,
                    recorderHarness: recorderHarness,
                    runID: runID
                )
            case .cafRepairOnRecovery:
                captureID = try await runCAFRepairOnRecovery(coordinator: coordinator, outbox: outbox)
            case .quarantineOnCorruption:
                captureID = try await runQuarantineOnCorruption(coordinator: coordinator, root: isolatedRoot)
            }
            let trace = await traceString(captureID: captureID, coordinator: coordinator)
            await coordinator.shutdownForTesting()
            return VoiceSelfTestScenarioOutcome(captureID: captureID, trace: trace)
        } catch {
            let trace = await traceString(captureID: captureID, coordinator: coordinator)
            await coordinator.shutdownForTesting()
            throw VoiceSelfTestScenarioFailure(
                reason: error.localizedDescription,
                trace: trace
            )
        }
    }

    private func runGoldenPath(
        coordinator: VoiceCaptureCoordinator,
        outbox: CaptureOutbox,
        runID: String
    ) async throws -> String {
        let captureID = try await startRecording(coordinator: coordinator, runID: runID)
        _ = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { $0.phase == .recordingLive }
        try await Task.sleep(for: .seconds(5))
        try await stopRecording(coordinator: coordinator, captureID: captureID, runID: runID)
        let record = try await waitForCapture(outbox: outbox, captureID: captureID, timeout: .seconds(10))
        try validateCommittedCAF(record: record, minimumBytes: 32_768)
        let trace = await traceString(captureID: captureID, coordinator: coordinator)
        try require(
            trace == "arming>starting>recording_unverified>recording_live>stopping>finalizing>committed",
            "golden_path_trace_mismatch:\(trace)"
        )
        return captureID
    }

    private func runAudioInterruption(
        coordinator: VoiceCaptureCoordinator,
        outbox: CaptureOutbox,
        notificationCenter: NotificationCenter,
        runID: String
    ) async throws -> String {
        let captureID = try await startRecording(coordinator: coordinator, runID: runID)
        let live = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { $0.phase == .recordingLive }
        let sessionID = live.sessionID
        try await Task.sleep(for: .seconds(2))
        notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.began.rawValue),
            ]
        )
        let blocked = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { session in
            session.phase == .blocked &&
                session.sessionID == sessionID &&
                session.blockedReason == .interruption &&
                session.audioFile?.sealReason == .interruption &&
                session.audioFile?.status == .closed
        }
        try require(blocked.sessionID == sessionID, "audio_interruption_wrong_session")
        notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
            ]
        )
        _ = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { session in
            session.phase == .blocked &&
                session.sessionID == sessionID &&
                session.blockerClearedAt != nil &&
                session.blockedAutoFinalizeAt != nil
        }
        try await Task.sleep(for: .seconds(1))
        let stillBlocked = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(2)
        ) { session in
            session.phase == .blocked &&
                session.sessionID == sessionID &&
                session.blockerClearedAt != nil
        }
        try require(stillBlocked.phase == .blocked, "audio_interruption_auto_resumed")
        try await resumeBlockedRecording(
            coordinator: coordinator,
            captureID: captureID,
            sessionID: sessionID,
            runID: runID
        )
        try await stopRecording(coordinator: coordinator, captureID: captureID, runID: runID)
        let record = try await waitForCapture(outbox: outbox, captureID: captureID, timeout: .seconds(10))
        try validateCommittedCAF(record: record, minimumBytes: 4_096)
        let trace = await traceString(captureID: captureID, coordinator: coordinator)
        try require(trace.contains("recording_live>blocked"), "audio_interruption_trace_missing_blocked:\(trace)")
        try require(trace.contains("blocked>resuming>recording_unverified>recording_live"), "audio_interruption_trace_missing_resume:\(trace)")
        return captureID
    }

    private func runRouteChangeResilience(
        coordinator: VoiceCaptureCoordinator,
        outbox: CaptureOutbox,
        recorderHarness: VoiceSelfTestRecorderHarness,
        notificationCenter: NotificationCenter,
        runID: String
    ) async throws -> String {
        let captureID = try await startRecording(coordinator: coordinator, runID: runID)
        _ = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { $0.phase == .recordingLive }
        try await Task.sleep(for: .seconds(2))
        let recorder = try await requireRecorderRuntime(recorderHarness, label: "route_change_resilience")
        // A .categoryChange route note means the audio category changed — the hardware
        // is fine. The coordinator must NOT tear the session down (observation, not
        // command). Byte flow keeps going (stall: false) so the session stays live.
        recorder.triggerConfigurationChange(stall: false)
        notificationCenter.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey: NSNumber(value: AVAudioSession.RouteChangeReason.categoryChange.rawValue),
            ]
        )
        try await Task.sleep(for: .seconds(1))
        let session = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(2)
        ) { $0.phase == .recordingLive }
        try require(session.phase == .recordingLive, "route_change_resilience_not_live")
        try await stopRecording(coordinator: coordinator, captureID: captureID, runID: runID)
        let record = try await waitForCapture(outbox: outbox, captureID: captureID, timeout: .seconds(10))
        try validateCommittedCAF(record: record, minimumBytes: 4_096)
        let trace = await traceString(captureID: captureID, coordinator: coordinator)
        try require(!trace.contains("blocked"), "route_change_resilience_blocked:\(trace)")
        try require(!trace.contains("recovering"), "route_change_resilience_recovering:\(trace)")
        return captureID
    }

    private func runProcessDeathRecovery(
        coordinator: VoiceCaptureCoordinator,
        outbox: CaptureOutbox,
        recorderHarness: VoiceSelfTestRecorderHarness,
        runID: String
    ) async throws -> String {
        let captureID = try await startRecording(coordinator: coordinator, runID: runID)
        let live = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { $0.phase == .recordingLive }
        let originalRelpath = try requireValue(live.audioFile?.relpath, "process_death_recovery_missing_audio_relpath")
        try await Task.sleep(for: .seconds(2))
        // Drop the live recorder without a clean stop (stall: true cancels byte flow)
        // so the on-disk CAF is whatever was last flushed — exactly the crash shape.
        let recorder = try await requireRecorderRuntime(recorderHarness, label: "process_death_recovery")
        recorder.triggerConfigurationChange(stall: true)
        try await Task.sleep(for: .seconds(1))
        // simulateProcessDeathForTesting throws away all in-memory session state; the
        // bundle remains on the filesystem ledger. Recovery must operate on storage
        // observations alone (INVARIANTS §4) — there is no session object to consult.
        await coordinator.simulateProcessDeathForTesting()
        await coordinator.applicationDidFinishLaunching()
        let record = try await waitForCapture(outbox: outbox, captureID: captureID, timeout: .seconds(12))
        try validateCommittedCAF(record: record, minimumBytes: 4_096)
        try require(record.blobPath?.isEmpty == false, "process_death_recovery_missing_blob")
        _ = originalRelpath
        let activeSessions = try await coordinator.activeSessionsForTesting()
        try require(activeSessions.isEmpty, "process_death_recovery_active_bundle_left_behind")
        return captureID
    }

    private func runPermissionDenial(
        coordinator: VoiceCaptureCoordinator,
        runID: String
    ) async throws -> String? {
        await coordinator.setMicrophonePermissionOverrideForTesting(.denied)
        do {
            _ = try await toggle(coordinator: coordinator, runID: runID)
            throw VoiceSelfTestScenarioFailure(reason: "permission_denial_should_fail_fast", trace: "none")
        } catch {
            try require(
                error.localizedDescription == VoiceCaptureError.microphonePermissionMissing.localizedDescription,
                "permission_denial_wrong_error:\(error.localizedDescription)"
            )
        }
        let sessions = try await coordinator.activeSessionsForTesting()
        try require(sessions.isEmpty, "permission_denial_left_active_bundle")
        return nil
    }

    private func runBlockedDeadlineFinalize(
        coordinator: VoiceCaptureCoordinator,
        outbox: CaptureOutbox,
        notificationCenter: NotificationCenter,
        runID: String
    ) async throws -> String {
        let captureID = try await startRecording(coordinator: coordinator, runID: runID)
        let live = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { $0.phase == .recordingLive }
        try await Task.sleep(for: .seconds(2))
        notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.began.rawValue),
            ]
        )
        _ = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { session in
            session.phase == .blocked &&
                session.sessionID == live.sessionID &&
                session.blockedReason == .interruption
        }
        notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
            ]
        )
        _ = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { session in
            session.phase == .blocked &&
                session.blockerClearedAt != nil &&
                session.blockedAutoFinalizeAt != nil
        }
        // blockedAutoFinalizeInterval is overridden to 1s for this scenario; after the
        // deadline passes, the next scene-active scan must auto-finalize the partial
        // capture rather than wait for a resume that never comes (INVARIANTS §3/§6).
        try await Task.sleep(for: .seconds(2))
        await coordinator.handleScenePhaseChange(.active)
        let record = try await waitForCapture(outbox: outbox, captureID: captureID, timeout: .seconds(10))
        try validateCommittedCAF(record: record, minimumBytes: 4_096)
        let trace = await traceString(captureID: captureID, coordinator: coordinator)
        try require(trace.contains("blocked>finalizing>committed"), "blocked_deadline_trace_missing_finalize:\(trace)")
        try require(!trace.contains("resuming"), "blocked_deadline_should_not_resume:\(trace)")
        return captureID
    }

    private func runStallDetection(
        coordinator: VoiceCaptureCoordinator,
        outbox: CaptureOutbox,
        recorderHarness: VoiceSelfTestRecorderHarness,
        runID: String
    ) async throws -> String {
        let captureID = try await startRecording(coordinator: coordinator, runID: runID)
        _ = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { $0.phase == .recordingLive }
        try await Task.sleep(for: .seconds(1))
        // Stall: cancel the recorder's progress loop with NO route/interruption note.
        // From the coordinator's view, byte flow simply stops. The single most
        // trust-eroding failure is the user speaking into dead air while the app implies
        // healthy capture — the coordinator must DETECT this (suspectedStall) and
        // converge (recover/seal), never sit live forever (VOICE_CAPTURE.md failure
        // priority; INVARIANTS §6 audio stall).
        let recorder = try await requireRecorderRuntime(recorderHarness, label: "stall_detection")
        recorder.stall()
        // Drive liveness observations; the monitor would do this on its own cadence, but
        // pollNowForTesting makes the convergence deterministic instead of timing-fragile.
        var detected = false
        let deadline = clock.now + .seconds(8)
        while clock.now < deadline {
            try await coordinator.pollNowForTesting()
            let sessions = try await coordinator.activeSessionsForTesting()
            if let session = sessions.first(where: { $0.captureID == captureID }) {
                if session.phase == .suspectedStall || session.phase == .recovering {
                    detected = true
                }
                if session.phase == .committed {
                    break
                }
            } else {
                // Bundle gone from active ⇒ it already finalized/committed and removed.
                detected = true
                break
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        let trace = await traceString(captureID: captureID, coordinator: coordinator)
        try require(
            detected || trace.contains("suspected_stall") || trace.contains("recovering"),
            "stall_detection_not_detected:\(trace)"
        )
        // The stall must converge: either it self-heals back to live (and we stop it) or
        // it seals. Either way the capture must end durably committed, never wedged.
        if let session = try await coordinator.activeSessionsForTesting().first(where: { $0.captureID == captureID }),
           session.phase == .recordingLive {
            try await stopRecording(coordinator: coordinator, captureID: captureID, runID: runID)
        }
        let record = try await waitForCapture(outbox: outbox, captureID: captureID, timeout: .seconds(12))
        try validateCommittedCAF(record: record, minimumBytes: 4_096)
        return captureID
    }

    private func runCAFRepairOnRecovery(
        coordinator: VoiceCaptureCoordinator,
        outbox: CaptureOutbox
    ) async throws -> String {
        // The bundle was planted before bootstrap with an OPEN (un-finalized, "crashed
        // mid-record") CAF header. applicationDidFinishLaunching already ran the recovery
        // scan in executeScenario; recovery must have repaired the CAF (closed the data
        // chunk) and committed a valid file. The captureID is the one we planted.
        let captureID = plantedCaptureID
        let record = try await waitForCapture(outbox: outbox, captureID: captureID, timeout: .seconds(12))
        try validateCommittedCAF(record: record, minimumBytes: 4_096)
        let activeSessions = try await coordinator.activeSessionsForTesting()
        try require(
            !activeSessions.contains(where: { $0.captureID == captureID }),
            "caf_repair_active_bundle_left_behind"
        )
        return captureID
    }

    private func runQuarantineOnCorruption(
        coordinator: VoiceCaptureCoordinator,
        root: URL
    ) async throws -> String? {
        // The corrupt bundle was planted before bootstrap. The launch scan must have
        // quarantined it: no active bundle survives, and the corrupt bundle is now under
        // the quarantine root. The capture is lost — but surfaced, never silent
        // (INVARIANTS §4/§6).
        let activeSessions = try await coordinator.activeSessionsForTesting()
        try require(activeSessions.isEmpty, "quarantine_on_corruption_active_bundle_survived")

        let quarantineRoot = VoCalCapturePaths.voiceSessionsQuarantineRoot(appGroupRoot: root)
        let fileManager = FileManager()
        let entries = (try? fileManager.contentsOfDirectory(
            at: quarantineRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        try require(!entries.isEmpty, "quarantine_on_corruption_nothing_quarantined")
        return nil
    }

    private func toggle(coordinator: VoiceCaptureCoordinator, runID: String) async throws -> VoiceToggleResult {
        try await coordinator.toggle(
            sourceSurface: .nativeRecorder,
            reason: "self_test",
            executionMode: .selfTest,
            runID: runID
        )
    }

    private func startRecording(coordinator: VoiceCaptureCoordinator, runID: String) async throws -> String {
        let result = try await toggle(coordinator: coordinator, runID: runID)
        guard case let .started(captureID) = result.action else {
            throw VoiceSelfTestScenarioFailure(
                reason: "voice_start_expected_started:\(describe(result.action))",
                trace: "none"
            )
        }
        return captureID
    }

    private func stopRecording(
        coordinator: VoiceCaptureCoordinator,
        captureID: String,
        runID: String
    ) async throws {
        let result = try await toggle(coordinator: coordinator, runID: runID)
        guard case let .finalized(finalCaptureID) = result.action, finalCaptureID == captureID else {
            throw VoiceSelfTestScenarioFailure(
                reason: "voice_stop_expected_finalized:\(describe(result.action))",
                trace: await traceString(captureID: captureID, coordinator: coordinator)
            )
        }
    }

    private func resumeBlockedRecording(
        coordinator: VoiceCaptureCoordinator,
        captureID: String,
        sessionID: String,
        runID: String
    ) async throws {
        let result = try await toggle(coordinator: coordinator, runID: runID)
        guard case let .started(resumedCaptureID) = result.action, resumedCaptureID == captureID else {
            throw VoiceSelfTestScenarioFailure(
                reason: "voice_resume_expected_started:\(describe(result.action))",
                trace: await traceString(captureID: captureID, coordinator: coordinator)
            )
        }
        let resumed = try await waitForSession(
            coordinator: coordinator,
            captureID: captureID,
            timeout: .seconds(12)
        ) { session in
            session.phase == .recordingLive &&
                session.sessionID == sessionID &&
                session.audioFile?.status == .open
        }
        try require(resumed.sessionID == sessionID, "voice_resume_wrong_session")
    }

    private func waitForSession(
        coordinator: VoiceCaptureCoordinator,
        captureID: String,
        timeout: Duration,
        predicate: @escaping (VoiceSessionSnapshot) -> Bool
    ) async throws -> VoiceSessionSnapshot {
        try await waitUntil(timeout: timeout, label: "session_\(captureID)") {
            let sessions = try await coordinator.activeSessionsForTesting()
            return sessions.first(where: { $0.captureID == captureID && predicate($0) })
        }
    }

    private func waitForCapture(
        outbox: CaptureOutbox,
        captureID: String,
        timeout: Duration
    ) async throws -> LocalCaptureRecord {
        try await waitUntil(timeout: timeout, label: "capture_\(captureID)") {
            try outbox.capture(captureID: captureID)
        }
    }

    private func waitUntil<T>(
        timeout: Duration,
        label: String,
        poll: Duration = .milliseconds(100),
        operation: @escaping () async throws -> T?
    ) async throws -> T {
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if Task.isCancelled {
                throw CancellationError()
            }
            if let value = try await operation() {
                return value
            }
            try await Task.sleep(for: poll)
        }
        throw VoiceSelfTestScenarioFailure(reason: "timed_out:\(label)", trace: "none")
    }

    private func requireRecorderRuntime(
        _ harness: VoiceSelfTestRecorderHarness,
        label: String
    ) async throws -> VoiceSelfTestRecorderRuntime {
        guard let session = await harness.lastRuntime() else {
            throw VoiceSelfTestScenarioFailure(reason: "missing_recorder_session:\(label)", trace: "none")
        }
        return session
    }

    private func validateCommittedCAF(
        record: LocalCaptureRecord,
        minimumBytes: Int64
    ) throws {
        try require(record.blobContentType == "audio/x-caf", "unexpected_blob_content_type:\(record.blobContentType)")
        try require(record.blobSize >= minimumBytes, "blob_too_small:\(record.blobSize)")
        guard let blobPath = record.blobPath else {
            throw VoiceSelfTestScenarioFailure(reason: "missing_blob_path", trace: "none")
        }
        let blobURL = URL(fileURLWithPath: blobPath, isDirectory: false)
        guard let analysis = CAFRepairer().analyze(fileURL: blobURL), analysis.status == .valid else {
            throw VoiceSelfTestScenarioFailure(reason: "caf_validation_failed", trace: "none")
        }
    }

    private func traceString(
        captureID: String?,
        coordinator: VoiceCaptureCoordinator
    ) async -> String {
        guard let captureID else {
            return "none"
        }
        let trace = await coordinator.phaseTraceForTesting(captureID: captureID)
        guard !trace.isEmpty else {
            return "none"
        }
        return trace.map(\.rawValue).joined(separator: ">")
    }

    private func prepareScenarioRoot(
        sharedRoot: URL,
        runID: String,
        scenario: VoiceSelfTestScenario
    ) throws -> URL {
        let root = sharedRoot
            .appendingPathComponent("self-test", isDirectory: true)
            .appendingPathComponent("voice", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent(scenario.rawValue, isDirectory: true)
        let fileManager = FileManager()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Filesystem-ledger planting (recovery scenarios)

    private static let plantedSessionID = "voice_selftest_recovery"
    private var plantedCaptureID = "cap_voice_selftest_recovery"

    /// Writes an active session bundle that looks like a crash mid-record: a live-phase
    /// snapshot + an OPEN (un-finalized) CAF with real PCM. Recovery must repair the open
    /// CAF (close the data chunk) and commit a valid file. Mirrors the on-disk shape the
    /// AVAudioEngine backend leaves behind when the process dies while recording.
    private func plantTruncatedRecoverableSession(root: URL) throws {
        let fileManager = FileManager()
        _ = try VoCalCapturePaths.ensureInitialized(appGroupRoot: root, fileManager: fileManager)
        let store = VoiceSessionStore(appGroupRoot: root, fileManager: fileManager)
        let bundle = try store.createActiveBundle(sessionID: Self.plantedSessionID)

        // Open-segment header + ~2s of PCM, then NO close — the data chunk size stays the
        // open-ended sentinel, which is precisely what CAFRepairer.repair fixes.
        try VoiceCAFMuxer.writeOpenSegmentHeader(to: bundle.audioURL)
        let pcm = voiceSelfTestPCMBytes(sampleCount: Int(VoiceCAFMuxer.sampleRate) * 2)
        try VoiceCAFMuxer.appendPCMData(pcm, toOpenSegment: bundle.audioURL)

        let now = Date()
        let relpath = bundle.relativePath(for: bundle.audioURL)
        let audioFile = VoiceAudioFileSnapshot(
            relpath: relpath,
            status: .open,
            openedAt: now,
            closedAt: nil,
            bytes: store.fileSize(at: bundle.audioURL),
            repairStatus: .notNeeded
        )
        let session = VoiceSessionSnapshot(
            sessionID: Self.plantedSessionID,
            captureID: plantedCaptureID,
            phase: .recordingLive,
            sourceSurface: CaptureSourceSurface.nativeRecorder.rawValue,
            createdAt: now,
            updatedAt: now,
            heartbeatAt: now,
            lastProgressAt: now,
            recoveryCount: 0,
            audioFile: audioFile
        )
        try store.persist(session: session, to: bundle)
    }

    /// Writes an active bundle whose session.json is undecodable. The scan must quarantine
    /// it (loadSession throws → moveToQuarantine) and surface a `voice.recovery_bundle_corrupt`
    /// event, leaving nothing in the active root.
    private func plantCorruptSession(root: URL) throws {
        let fileManager = FileManager()
        _ = try VoCalCapturePaths.ensureInitialized(appGroupRoot: root, fileManager: fileManager)
        let store = VoiceSessionStore(appGroupRoot: root, fileManager: fileManager)
        let bundle = try store.createActiveBundle(sessionID: "voice_selftest_corrupt")
        try Data("{ this is not valid session json".utf8).write(to: bundle.sessionURL, options: .atomic)
    }

    private func emit(
        level: CaptureDebugLevel = .info,
        name: String,
        message: String,
        metadata: [String: String],
        appGroupRoot: URL
    ) {
        CaptureDebugRecorder.shared.emit(
            level,
            name: name,
            message: message,
            metadata: metadata,
            appGroupRoot: appGroupRoot
        )
    }

    private func require(_ condition: Bool, _ reason: String) throws {
        guard condition else {
            throw VoiceSelfTestScenarioFailure(reason: reason, trace: "none")
        }
    }

    private func requireValue<T>(_ value: T?, _ reason: String) throws -> T {
        guard let value else {
            throw VoiceSelfTestScenarioFailure(reason: reason, trace: "none")
        }
        return value
    }

    private func describe(_ action: VoiceToggleResult.Action) -> String {
        switch action {
        case let .started(captureID):
            return "started:\(captureID)"
        case let .blocked(captureID):
            return "blocked:\(captureID)"
        case let .stopping(captureID):
            return "stopping:\(captureID)"
        case let .finalized(captureID):
            return "finalized:\(captureID)"
        case let .deferred(captureID):
            return "deferred:\(captureID)"
        case let .lost(captureID):
            return "lost:\(captureID)"
        }
    }

    private static func request(from url: URL) -> (runID: String, scenarios: [VoiceSelfTestScenario])? {
        guard url.scheme?.lowercased() == "vocal" else {
            return nil
        }
        let host = url.host?.lowercased() ?? ""
        let pathComponents = url.path
            .split(separator: "/")
            .map { String($0).lowercased() }
        let matchesVoiceSelfTest =
            (host == "self-test" && pathComponents == ["voice"]) ||
            pathComponents == ["self-test", "voice"]
        guard matchesVoiceSelfTest else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let runID = components?
            .queryItems?
            .first(where: { $0.name == "run_id" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scenarios = parseScenarioCSV(
            components?
                .queryItems?
                .first(where: { $0.name == "scenarios" })?
                .value
        ) ?? VoiceSelfTestScenario.defaultScenarios
        return (
            runID: (runID?.isEmpty == false) ? runID! : defaultRunID(),
            scenarios: scenarios
        )
    }

    private static func parseScenarioList(
        arguments: [String],
        flag: String
    ) -> [VoiceSelfTestScenario]? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }
        return parseScenarioCSV(arguments[valueIndex])
    }

    private static func parseScenarioCSV(_ csv: String?) -> [VoiceSelfTestScenario]? {
        guard let csv else {
            return nil
        }
        let values = csv
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else {
            return nil
        }
        let scenarios = values.compactMap(VoiceSelfTestScenario.init(rawValue:))
        guard scenarios.count == values.count else {
            return nil
        }
        return scenarios
    }

    private static func defaultRunID() -> String {
        "voice_\(CaptureDateCodec.captureIDTimestamp(Date()))"
    }
}

private actor VoiceSelfTestRecorderHarness {
    private var runtimes: [VoiceSelfTestRecorderRuntime] = []

    func record(_ runtime: VoiceSelfTestRecorderRuntime) {
        runtimes.append(runtime)
    }

    func lastRuntime() -> VoiceSelfTestRecorderRuntime? {
        runtimes.last
    }
}

private final class VoiceSelfTestRecorderFactory: VoiceRecorderFactory, Sendable {
    private let harness: VoiceSelfTestRecorderHarness

    init(harness: VoiceSelfTestRecorderHarness) {
        self.harness = harness
    }

    func makeRecorder(
        fileURL: URL,
        appendToExisting: Bool,
        onUnexpectedStop: @escaping @Sendable (String) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void,
        onStopFinished: @escaping @Sendable (Bool) -> Void
    ) throws -> VoiceRecorderSession {
        let runtime = VoiceSelfTestRecorderRuntime(
            fileURL: fileURL,
            appendToExisting: appendToExisting,
            onUnexpectedStop: onUnexpectedStop,
            onConfigurationChange: onConfigurationChange,
            onStopFinished: onStopFinished
        )
        let session = VoiceSelfTestRecorderSession(runtime: runtime)
        Task {
            await harness.record(runtime)
        }
        return session
    }
}

private final class VoiceSelfTestRecorderRuntime: Sendable {
    private struct RecorderState: Sendable {
        var isRecording = false
        var fileURL: URL
        var accumulatedPCM = Data()
        var currentTime: TimeInterval = 0
        var progressGeneration: UInt64 = 0
    }

    private let onUnexpectedStop: @Sendable (String) -> Void
    private let onConfigurationChange: @Sendable () -> Void
    private let onStopFinished: @Sendable (Bool) -> Void
    private let lock: Mutex<RecorderState>
    private let progressChunk = voiceSelfTestPCMBytes(sampleCount: 1_200)
    private let progressInterval: Duration = .milliseconds(40)
    private let progressTask = Mutex<Task<Void, Never>?>(nil)

    init(
        fileURL: URL,
        appendToExisting: Bool,
        onUnexpectedStop: @escaping @Sendable (String) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void,
        onStopFinished: @escaping @Sendable (Bool) -> Void
    ) {
        self.onUnexpectedStop = onUnexpectedStop
        self.onConfigurationChange = onConfigurationChange
        self.onStopFinished = onStopFinished
        let existingPCM = Self.loadExistingPCM(fileURL: fileURL, appendToExisting: appendToExisting)
        let frames = existingPCM.count / Int(VoiceCAFMuxer.bytesPerFrame)
        self.lock = Mutex(RecorderState(
            isRecording: false,
            fileURL: fileURL,
            accumulatedPCM: existingPCM,
            currentTime: Double(frames) / VoiceCAFMuxer.sampleRate
        ))
    }

    deinit {
        cancelProgressTask()
    }

    var fileURL: URL {
        lock.withLock { state in
            state.fileURL
        }
    }

    var currentTime: TimeInterval {
        lock.withLock { state in
            state.currentTime
        }
    }

    var isRecording: Bool {
        lock.withLock { state in
            state.isRecording
        }
    }

    func record() -> Bool {
        let generation = lock.withLock { state in
            state.isRecording = true
            state.progressGeneration += 1
            return state.progressGeneration
        }
        appendProgressChunk(generation: generation, failureReasonPrefix: "self_test_write_failed")
        startProgressLoop(generation: generation)
        return true
    }

    func stop() {
        cancelProgressTask()
        let shouldFinish = lock.withLock { state in
            guard state.isRecording else {
                return false
            }
            state.isRecording = false
            return true
        }
        guard shouldFinish else {
            return
        }
        onStopFinished(true)
    }

    func triggerConfigurationChange(stall: Bool) {
        if stall {
            cancelProgressTask()
        }
        onConfigurationChange()
    }

    /// Silently cancels byte flow while the recorder still reports `isRecording == true`
    /// and posts no notification. This is the dead-air shape: the coordinator's only
    /// signal is that the file stops growing.
    func stall() {
        cancelProgressTask()
    }

    private func startProgressLoop(generation: UInt64) {
        progressTask.withLock { task in
            task?.cancel()
            task = Task { [weak self] in
                guard let self else {
                    return
                }
                while !Task.isCancelled {
                    try? await Task.sleep(for: self.progressInterval)
                    if Task.isCancelled {
                        return
                    }
                    guard self.appendProgressChunk(generation: generation, failureReasonPrefix: "self_test_write_failed") else {
                        return
                    }
                }
            }
        }
    }

    @discardableResult
    private func appendProgressChunk(
        generation: UInt64,
        failureReasonPrefix: String
    ) -> Bool {
        let snapshot = lock.withLock { state -> (fileURL: URL, payload: Data)? in
            guard state.isRecording, state.progressGeneration == generation else {
                return nil
            }
            state.accumulatedPCM.append(progressChunk)
            let frames = state.accumulatedPCM.count / Int(VoiceCAFMuxer.bytesPerFrame)
            state.currentTime = Double(frames) / VoiceCAFMuxer.sampleRate
            return (state.fileURL, state.accumulatedPCM)
        }
        guard let snapshot else {
            return false
        }
        do {
            try VoiceCAFMuxer.writeClosedSegment(snapshot.payload, to: snapshot.fileURL)
        } catch {
            lock.withLock { state in
                state.isRecording = false
            }
            onUnexpectedStop("\(failureReasonPrefix):\(error.localizedDescription)")
            return false
        }
        return true
    }

    private func cancelProgressTask() {
        progressTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private static func loadExistingPCM(fileURL: URL, appendToExisting: Bool) -> Data {
        guard appendToExisting,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return Data()
        }

        let repairer = CAFRepairer()
        guard var analysis = repairer.analyze(fileURL: fileURL) else {
            return Data()
        }
        if analysis.status == .needsRepair {
            _ = repairer.repair(analysis: analysis)
            guard let repaired = repairer.analyze(fileURL: fileURL) else {
                return Data()
            }
            analysis = repaired
        }
        guard let dataChunk = analysis.dataChunk,
              let data = try? Data(contentsOf: fileURL)
        else {
            return Data()
        }
        return data.subdata(in: dataChunk.dataOffset..<data.count)
    }
}

private final class VoiceSelfTestRecorderSession: VoiceRecorderSession {
    private let runtime: VoiceSelfTestRecorderRuntime

    init(runtime: VoiceSelfTestRecorderRuntime) {
        self.runtime = runtime
    }

    var fileURL: URL {
        runtime.fileURL
    }

    var currentTime: TimeInterval {
        runtime.currentTime
    }

    var isRecording: Bool {
        runtime.isRecording
    }

    func record() -> Bool {
        runtime.record()
    }

    func stop() {
        runtime.stop()
    }
}

private func voiceSelfTestPCMBytes(sampleCount: Int) -> Data {
    var data = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
    for index in 0..<sampleCount {
        var sample = Int16(index % 200).littleEndian
        data.append(Data(bytes: &sample, count: MemoryLayout<Int16>.size))
    }
    return data
}
