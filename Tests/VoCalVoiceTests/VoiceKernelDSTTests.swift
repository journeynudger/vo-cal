import Foundation
import VoCalCapture
import VoCalCore
import Testing
@testable import VoCalVoice

enum VoiceDSTSuiteGate {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VOICE_DST_ENABLED"] == "1"
    }
}

private enum VoiceSegmentStatus {
    case recording
    case sealed
    case quarantined
}

private enum VoiceSegmentRepairStatus {
    case notNeeded
    case repaired
    case failed
}

private struct VoiceSegmentSnapshot {
    var index: Int
    var relpath: String
    var status: VoiceSegmentStatus
    var openedAt: Date
    var sealedAt: Date?
    var bytes: Int64
    var repairStatus: VoiceSegmentRepairStatus
    var sealReason: VoiceSegmentSealReason?
}

private extension VoiceSegmentStatus {
    init(audioFileStatus: VoiceAudioFileStatus) {
        switch audioFileStatus {
        case .open:
            self = .recording
        case .closed:
            self = .sealed
        case .quarantined:
            self = .quarantined
        }
    }

    var audioFileStatus: VoiceAudioFileStatus {
        switch self {
        case .recording:
            return .open
        case .sealed:
            return .closed
        case .quarantined:
            return .quarantined
        }
    }
}

private extension VoiceSegmentRepairStatus {
    init(audioFileRepairStatus: VoiceAudioFileRepairStatus) {
        switch audioFileRepairStatus {
        case .notNeeded:
            self = .notNeeded
        case .repaired:
            self = .repaired
        case .failed:
            self = .failed
        }
    }

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

private extension VoiceSegmentSnapshot {
    init(audioFile: VoiceAudioFileSnapshot) {
        self.init(
            index: 1,
            relpath: audioFile.relpath,
            status: .init(audioFileStatus: audioFile.status),
            openedAt: audioFile.openedAt,
            sealedAt: audioFile.closedAt,
            bytes: audioFile.bytes,
            repairStatus: .init(audioFileRepairStatus: audioFile.repairStatus),
            sealReason: audioFile.sealReason
        )
    }

    func asAudioFile() -> VoiceAudioFileSnapshot {
        VoiceAudioFileSnapshot(
            relpath: relpath,
            status: status.audioFileStatus,
            openedAt: openedAt,
            closedAt: sealedAt,
            bytes: bytes,
            repairStatus: repairStatus.audioFileRepairStatus,
            sealReason: sealReason
        )
    }
}

private extension VoiceSessionSnapshot {
    init(
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
        currentSegmentIndex: Int? = nil,
        currentSegmentRelpath: String? = nil,
        segments: [VoiceSegmentSnapshot],
        finalBlobRelpath: String? = nil,
        pendingCommitReason: String? = nil,
        blockedReason: VoiceBlockedReason? = nil,
        blockerClearedAt: Date? = nil,
        blockedAutoFinalizeAt: Date? = nil,
        context: [String: CaptureJSONValue] = [:]
    ) {
        let activeSegment = segments.first(where: { $0.index == currentSegmentIndex })
            ?? segments.last
        let audioFile = activeSegment.map { segment in
            var file = segment.asAudioFile()
            if currentSegmentIndex != nil {
                file.status = .open
            }
            if let currentSegmentRelpath {
                file.relpath = currentSegmentRelpath
            }
            return file
        }
        self.init(
            sessionID: sessionID,
            captureID: captureID,
            phase: phase,
            sourceSurface: sourceSurface,
            createdAt: createdAt,
            updatedAt: updatedAt,
            heartbeatAt: heartbeatAt,
            lastProgressAt: lastProgressAt,
            failureReason: failureReason,
            recoveryCount: recoveryCount,
            preferredInputUID: preferredInputUID,
            audioFile: audioFile,
            finalBlobRelpath: finalBlobRelpath,
            pendingCommitReason: pendingCommitReason,
            blockedReason: blockedReason,
            blockerClearedAt: blockerClearedAt,
            blockedAutoFinalizeAt: blockedAutoFinalizeAt,
            context: context
        )
    }

    var currentSegmentIndex: Int? {
        get { audioFile?.status == .open ? 1 : nil }
        set {
            guard var audioFile else { return }
            if newValue == nil {
                if audioFile.status == .open {
                    audioFile.status = .closed
                }
            } else {
                audioFile.status = .open
            }
            self.audioFile = audioFile
        }
    }

    var currentSegmentRelpath: String? {
        get { audioFile?.status == .open ? audioFile?.relpath : nil }
        set {
            guard var audioFile else { return }
            if let newValue {
                audioFile.relpath = newValue
                self.audioFile = audioFile
            }
        }
    }

    var segments: [VoiceSegmentSnapshot] {
        get { audioFile.map { [VoiceSegmentSnapshot(audioFile: $0)] } ?? [] }
        set {
            self.audioFile = newValue.last.map { $0.asAudioFile() }
        }
    }
}

@Suite(.serialized)
struct VoiceKernelDSTTests {
    @Test("Voice kernel DST sweep")
    func voiceKernelDST() throws {
        let config = try VoiceDSTConfiguration.load()
        guard config.enabled else {
            return
        }

        let result = VoiceDSTHarness(configuration: config).run()
        try result.write(to: config.resultPath)

        guard let failure = result.failure else {
            return
        }

        Issue.record(
            """
            DST \(failure.category.rawValue) failure
            seed=\(failure.seed)
            summary=\(failure.summary)
            repro=bin/voice-dst --seed \(failure.seed)
            """
        )
    }
}

private struct VoiceDSTConfiguration: Sendable {
    let enabled: Bool
    let runID: String
    let seedCount: Int
    let chaosSteps: Int
    let settlingSteps: Int
    let stuckThreshold: Int
    let masterSeed: UInt64
    let replaySeed: UInt64?
    let resultPath: URL
    let traceDirectory: URL

    var enforceCoverageRatchets: Bool {
        replaySeed == nil
    }

    var seeds: [UInt64] {
        if let replaySeed {
            return [replaySeed]
        }

        var rng = DeterministicRNG(seed: masterSeed)
        return (0..<seedCount).map { _ in
            let seed = rng.next()
            return seed == 0 ? 0x9e3779b97f4a7c15 : seed
        }
    }

    static func load() throws -> VoiceDSTConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let enabled = environment["VOICE_DST_ENABLED"] == "1"
        let baseDirectory = URL(fileURLWithPath: environment["VOICE_DST_TRACE_DIR"] ?? "/tmp/voice-dst", isDirectory: true)
        let resultPath = URL(fileURLWithPath: environment["VOICE_DST_RESULT_PATH"] ?? "/tmp/voice-dst/result.json")
        let runID = environment["VOICE_DST_RUN_ID"] ?? "voice-dst"

        return VoiceDSTConfiguration(
            enabled: enabled,
            runID: runID,
            seedCount: parseInt(environment["VOICE_DST_SEED_COUNT"], defaultValue: 500),
            chaosSteps: parseInt(environment["VOICE_DST_CHAOS_STEPS"], defaultValue: 200),
            settlingSteps: parseInt(environment["VOICE_DST_SETTLING_STEPS"], defaultValue: 25),
            stuckThreshold: parseInt(environment["VOICE_DST_STUCK_THRESHOLD"], defaultValue: 25),
            masterSeed: parseUInt64(environment["VOICE_DST_MASTER_SEED"], defaultValue: 0x51EED5EED),
            replaySeed: environment["VOICE_DST_REPLAY_SEED"].flatMap(UInt64.init),
            resultPath: resultPath,
            traceDirectory: baseDirectory
        )
    }

    private static func parseInt(_ raw: String?, defaultValue: Int) -> Int {
        guard let raw, let value = Int(raw), value > 0 else {
            return defaultValue
        }
        return value
    }

    private static func parseUInt64(_ raw: String?, defaultValue: UInt64) -> UInt64 {
        guard let raw, let value = UInt64(raw) else {
            return defaultValue
        }
        return value
    }
}

private struct VoiceDSTHarness {
    let configuration: VoiceDSTConfiguration

    func run() -> VoiceDTRunResult {
        var aggregatePropertyCounts = VoiceDSTCounterSet<VoiceDSTProperty>()
        var aggregateScaryCounts = VoiceDSTCounterSet<VoiceDSTScaryState>()
        var summaries: [VoiceDSTSeedSummary] = []
        var failure: VoiceDSTFailure?

        for seed in configuration.seeds {
            let first = VoiceDSTSeedRunner(configuration: configuration, seed: seed).run()
            let second = VoiceDSTSeedRunner(configuration: configuration, seed: seed).run()

            aggregatePropertyCounts.merge(first.propertyCounts)
            aggregateScaryCounts.merge(first.scaryCounts)

            let determinismMismatch = first.trace != second.trace
                || first.finalState != second.finalState
                || first.propertyCounts != second.propertyCounts
                || first.scaryCounts != second.scaryCounts

            if determinismMismatch {
                let tracePath = writeTrace(entries: first.trace, seed: seed)
                failure = VoiceDSTFailure(
                    category: .harnessIntegrity,
                    seed: seed,
                    summary: "double-run determinism mismatch",
                    tracePath: tracePath.path
                )
            } else if let seedFailure = first.failure {
                let tracePath = writeTrace(entries: first.trace, seed: seed)
                failure = VoiceDSTFailure(
                    category: seedFailure.category,
                    seed: seed,
                    summary: seedFailure.summary,
                    tracePath: tracePath.path
                )
            }

            if let failure {
                print("CATEGORY=\(failure.category.rawValue.uppercased()) SEED=\(seed) REPRO=bin/voice-dst --seed \(seed)")
                summaries.append(VoiceDSTSeedSummary(seed: seed, status: "FAILED", category: failure.category.rawValue))
                break
            }

            print("SEED=\(seed) PASSED")
            summaries.append(VoiceDSTSeedSummary(seed: seed, status: "PASSED", category: nil))
        }

        if failure == nil && configuration.enforceCoverageRatchets {
            if let deadProperty = aggregatePropertyCounts.zeroKeys(allCases: VoiceDSTProperty.allCases).first {
                failure = VoiceDSTFailure(
                    category: .harnessIntegrity,
                    seed: configuration.seeds.first ?? 0,
                    summary: "property applicability never fired: \(deadProperty.rawValue)",
                    tracePath: nil
                )
            } else if let deadScaryState = aggregateScaryCounts.zeroKeys(allCases: VoiceDSTScaryState.allCases).first {
                failure = VoiceDSTFailure(
                    category: .harnessIntegrity,
                    seed: configuration.seeds.first ?? 0,
                    summary: "scary-state coverage never fired: \(deadScaryState.rawValue)",
                    tracePath: nil
                )
            }
        }

        return VoiceDTRunResult(
            runID: configuration.runID,
            success: failure == nil,
            failure: failure,
            seedSummaries: summaries,
            propertyCounts: aggregatePropertyCounts.dictionary(),
            scaryCounts: aggregateScaryCounts.dictionary()
        )
    }

    private func writeTrace(entries: [VoiceDSTTraceEntry], seed: UInt64) -> URL {
        let path = configuration.traceDirectory.appendingPathComponent("seed-\(seed).json", isDirectory: false)
        try? FileManager.default.createDirectory(at: configuration.traceDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.voiceDST.encode(entries) {
            try? data.write(to: path, options: .atomic)
        }
        return path
    }
}

private struct VoiceDSTSeedRunner {
    let configuration: VoiceDSTConfiguration
    let seed: UInt64

    private let kernel = VoiceCoordinatorKernel(constants: VoiceCaptureConstants())

    func run() -> VoiceDSTSeedRunResult {
        var state = VoiceKernelState()
        var rng = DeterministicRNG(seed: seed)
        var world = VoiceDSTWorld(now: Date(timeIntervalSince1970: 1_742_566_400 + TimeInterval(seed % 1024)))
        var trace: [VoiceDSTTraceEntry] = []
        var propertyCounts = VoiceDSTCounterSet<VoiceDSTProperty>()
        var scaryCounts = VoiceDSTCounterSet<VoiceDSTScaryState>()
        var operations: [VoiceDSTOperation] = []
        var failure: VoiceDSTStepFailure?
        var stepNumber = 0

        while stepNumber < configuration.chaosSteps && failure == nil {
            stepNumber += 1
            world.advanceTime(rng: &rng, settling: false)

            let materialized = materializeChaosInput(
                state: state,
                world: &world,
                rng: &rng,
                stepNumber: stepNumber,
                operations: operations,
                scaryCounts: scaryCounts
            )

            let stepResult = apply(
                materialized,
                state: &state,
                world: &world,
                operations: &operations,
                trace: &trace,
                propertyCounts: &propertyCounts,
                scaryCounts: &scaryCounts,
                stepNumber: stepNumber
            )
            failure = stepResult
        }

        var settlingSteps = 0
        while failure == nil && settlingSteps < configuration.settlingSteps && (!world.pendingEffects.isEmpty || operations.contains(where: \.resolved.negated)) {
            settlingSteps += 1
            stepNumber += 1
            world.advanceTime(rng: &rng, settling: true)

            guard let materialized = materializeSettlingInput(
                state: state,
                world: &world,
                rng: &rng,
                stepNumber: stepNumber
            ) else {
                failure = VoiceDSTStepFailure(category: .livenessViolation, summary: "settling exhausted with unresolved work")
                break
            }

            let stepResult = apply(
                materialized,
                state: &state,
                world: &world,
                operations: &operations,
                trace: &trace,
                propertyCounts: &propertyCounts,
                scaryCounts: &scaryCounts,
                stepNumber: stepNumber
            )
            failure = stepResult
        }

        if failure == nil, operations.contains(where: \.resolved.negated) {
            failure = VoiceDSTStepFailure(category: .livenessViolation, summary: "accepted operation unresolved after settling")
        }

        return VoiceDSTSeedRunResult(
            trace: trace,
            finalState: VoiceDSTStateSummary.make(from: state),
            propertyCounts: propertyCounts,
            scaryCounts: scaryCounts,
            failure: failure
        )
    }

    private func materializeChaosInput(
        state: VoiceKernelState,
        world: inout VoiceDSTWorld,
        rng: inout DeterministicRNG,
        stepNumber: Int,
        operations: [VoiceDSTOperation],
        scaryCounts: VoiceDSTCounterSet<VoiceDSTScaryState>
    ) -> VoiceDSTMaterializedInput {
        if scaryCounts.count(for: .toggleDuringFinalization) == 0,
           isFinalizationPathActive(state: state, world: world) {
            return world.makeToggleInput(
                state: state,
                rng: &rng,
                seed: seed,
                scaryOverride: .toggleDuringFinalization
            )
        }

        if let urgent = world.selectUrgentPendingEffect(stepNumber: stepNumber, operations: operations, threshold: configuration.stuckThreshold) {
            return world.completePendingEffect(at: urgent, rng: &rng, currentGeneration: state.current?.generation)
        }

        let canComplete = !world.pendingEffects.isEmpty
        let canReplay = !world.replayableEvents.isEmpty

        if canComplete && rng.nextBool(probabilityPercent: 62) {
            let index = rng.nextInt(upperBound: world.pendingEffects.count)
            return world.completePendingEffect(at: index, rng: &rng, currentGeneration: state.current?.generation)
        }

        if canReplay && rng.nextBool(probabilityPercent: 18) {
            return world.replayStaleEvent(rng: &rng, currentGeneration: state.current?.generation)
        }

        return world.makeExternalInput(state: state, rng: &rng, seed: seed)
    }

    private func materializeSettlingInput(
        state: VoiceKernelState,
        world: inout VoiceDSTWorld,
        rng: inout DeterministicRNG,
        stepNumber: Int
    ) -> VoiceDSTMaterializedInput? {
        if !world.pendingEffects.isEmpty {
            let index = world.selectUrgentPendingEffect(stepNumber: stepNumber, operations: [], threshold: configuration.stuckThreshold)
                ?? 0
            return world.completePendingEffect(at: index, rng: &rng, currentGeneration: state.current?.generation)
        }

        if !world.replayableEvents.isEmpty, rng.nextBool(probabilityPercent: 20) {
            return world.replayStaleEvent(rng: &rng, currentGeneration: state.current?.generation)
        }

        return nil
    }

    private func isFinalizationPathActive(state: VoiceKernelState, world: VoiceDSTWorld) -> Bool {
        guard let current = state.current else {
            return false
        }

        if current.snapshot.phase == .finalizing {
            return true
        }

        if case .finalize = current.pendingSealContinuation {
            return true
        }

        return world.pendingEffects.contains { pending in
            guard pending.generation == current.generation else {
                return false
            }

            if case .finalizeCurrentSession = pending.effect {
                return true
            }
            return false
        }
    }

    private func apply(
        _ input: VoiceDSTMaterializedInput,
        state: inout VoiceKernelState,
        world: inout VoiceDSTWorld,
        operations: inout [VoiceDSTOperation],
        trace: inout [VoiceDSTTraceEntry],
        propertyCounts: inout VoiceDSTCounterSet<VoiceDSTProperty>,
        scaryCounts: inout VoiceDSTCounterSet<VoiceDSTScaryState>,
        stepNumber: Int
    ) -> VoiceDSTStepFailure? {
        let stateBefore = state
        let pendingBefore = world.pendingEffects

        for scaryState in input.scaryStates {
            scaryCounts.increment(scaryState)
        }

        let effects = kernel.step(state: &state, event: input.event)
        world.syncCurrentSession(from: state)
        world.recordReplayableEvent(input)

        updateOperations(
            for: input.event,
            effects: effects,
            state: state,
            operations: &operations,
            stepNumber: stepNumber
        )
        world.applyImmediateEffects(effects, state: state, stepNumber: stepNumber, operations: &operations)

        if let failure = checkProperties(
            input: input,
            stateBefore: stateBefore,
            stateAfter: state,
            pendingBefore: pendingBefore,
            effects: effects,
            operations: operations,
            propertyCounts: &propertyCounts,
            stepNumber: stepNumber
        ) {
            trace.append(
                VoiceDSTTraceEntry(
                    step: stepNumber,
                    input: input.summary,
                    event: VoiceDSTNormalizer.describe(event: input.event),
                    effects: effects.map(VoiceDSTNormalizer.describe(effect:)),
                    state: VoiceDSTStateSummary.make(from: state)
                )
            )
            return failure
        }

        trace.append(
            VoiceDSTTraceEntry(
                step: stepNumber,
                input: input.summary,
                event: VoiceDSTNormalizer.describe(event: input.event),
                effects: effects.map(VoiceDSTNormalizer.describe(effect:)),
                state: VoiceDSTStateSummary.make(from: state)
            )
        )
        return nil
    }

    private func updateOperations(
        for event: VoiceKernelEvent,
        effects: [VoiceKernelEffect],
        state: VoiceKernelState,
        operations: inout [VoiceDSTOperation],
        stepNumber: Int
    ) {
        for effect in effects {
            switch effect {
            case let .startReservedSession(_, generation, _):
                if !operations.contains(where: { $0.kind == .start && $0.generation == generation && !$0.resolved }) {
                    operations.append(.init(kind: .start, generation: generation, acceptedAtStep: stepNumber, lastProgressStep: stepNumber))
                }
            case let .sealCurrentSegment(generation, reason):
                if reason == .userStop,
                   !operations.contains(where: { $0.kind == .stop && $0.generation == generation && !$0.resolved }) {
                    operations.append(.init(kind: .stop, generation: generation, acceptedAtStep: stepNumber, lastProgressStep: stepNumber))
                }
            case let .finalizeCurrentSession(generation, _, _),
                 let .recoverCurrentSession(generation, _),
                 let .scheduleRecoveryRetry(generation, _),
                 let .persistCurrentSession(generation, _, _, _):
                markProgress(for: generation, operations: &operations, stepNumber: stepNumber)
            case .scanActiveSessions,
                 .observeStartPrerequisites,
                 .commitRecoveredSession,
                 .removeRecoveredSession,
                 .resolveToggleResult,
                 .failToggle:
                break
            }
        }

        switch event {
        case let .startSucceeded(generation, _), let .startFailed(generation, _):
            markProgress(for: generation, operations: &operations, stepNumber: stepNumber)
            resolveFirst(kind: .start, generation: generation, operations: &operations)
        case let .segmentSealed(generation, _),
             let .segmentSealFailed(generation, _, _),
             let .recoverySucceeded(generation, _),
             let .recoveryBlocked(generation, _, _, _),
             let .recoveryFailed(generation, _, _),
             let .recoveryRetryRequested(generation),
             let .operationFinished(generation, _, _),
             let .livenessObserved(generation, _, _),
             let .routeChanged(generation, _, _),
             let .configurationChanged(generation, _),
             let .unexpectedRecorderStop(generation, _, _):
            markProgress(for: generation, operations: &operations, stepNumber: stepNumber)
            if case let .operationFinished(_, result, _) = event,
               result.action.isTerminalOrDeferredStopResult {
                resolveFirst(kind: .stop, generation: generation, operations: &operations)
            }
        case .toggleRequested,
             .recoveryScanRequested,
             .recoveryScanCompleted,
             .startPrerequisitesObserved,
             .interruptionBegan,
             .blockedClearObserved,
             .blockedDeadlineObservedExpired,
             .mediaServicesWereReset:
            break
        }

        if let current = state.current {
            markProgress(for: current.generation, operations: &operations, stepNumber: stepNumber)
        }
    }

    private func markProgress(
        for generation: VoiceOperationGeneration,
        operations: inout [VoiceDSTOperation],
        stepNumber: Int
    ) {
        for index in operations.indices where operations[index].generation == generation && !operations[index].resolved {
            operations[index].lastProgressStep = stepNumber
        }
    }

    private func resolveFirst(
        kind: VoiceDSTOperationKind,
        generation: VoiceOperationGeneration,
        operations: inout [VoiceDSTOperation]
    ) {
        if let index = operations.firstIndex(where: { $0.kind == kind && $0.generation == generation && !$0.resolved }) {
            operations[index].resolved = true
        }
    }

    private func checkProperties(
        input: VoiceDSTMaterializedInput,
        stateBefore: VoiceKernelState,
        stateAfter: VoiceKernelState,
        pendingBefore: [VoiceDSTPendingEffect],
        effects: [VoiceKernelEffect],
        operations: [VoiceDSTOperation],
        propertyCounts: inout VoiceDSTCounterSet<VoiceDSTProperty>,
        stepNumber: Int
    ) -> VoiceDSTStepFailure? {
        if input.ownedLifecycleScan {
            propertyCounts.increment(.ownershipCoherence)
            let illegal = effects.contains {
                switch $0 {
                case let .finalizeCurrentSession(_, _, proof):
                    return proof.ownership == .ownedByCurrentProcess
                case let .removeRecoveredSession(_, proof):
                    return proof.ownership == .ownedByCurrentProcess
                default:
                    return false
                }
            }
            if illegal {
                return .init(category: .propertyViolation, summary: "owned lifecycle scan emitted destructive recovery effect")
            }
        }

        let destructiveEffects = effects.compactMap(VoiceDSTDestructiveEffect.init)
        if !destructiveEffects.isEmpty {
            propertyCounts.increment(.destructiveProof)
            for destructive in destructiveEffects where !destructive.isValid(against: stateAfter) {
                return .init(category: .propertyViolation, summary: "destructive proof mismatch: \(destructive.summary)")
            }
        }

        if operations.contains(where: \.resolved.negated) {
            propertyCounts.increment(.acceptedIntentResolution)
            if let stalled = operations.first(where: { !$0.resolved && stepNumber - $0.lastProgressStep >= configuration.stuckThreshold }) {
                return .init(category: .livenessViolation, summary: "accepted \(stalled.kind.rawValue) generation \(stalled.generation) stalled for \(stepNumber - stalled.lastProgressStep) steps")
            }
        }

        if input.informationalNoise {
            propertyCounts.increment(.informationalEventsInert)
            let destructive = effects.contains {
                switch $0 {
                case .sealCurrentSegment, .recoverCurrentSession, .finalizeCurrentSession, .commitRecoveredSession, .removeRecoveredSession:
                    return true
                default:
                    return false
                }
            }
            if destructive {
                return .init(category: .propertyViolation, summary: "informational event emitted destructive effect")
            }
        }

        if effects.contains(where: {
            if case let .resolveToggleResult(_, result) = $0, case .started = result.action {
                return true
            }
            return false
        }) {
            propertyCounts.increment(.startedResolutionRequiresLiveEvidence)
            if stateAfter.current?.snapshot.phase != .recordingLive {
                return .init(category: .propertyViolation, summary: "started resolved before recording_live")
            }
        }

        if input.ownedLifecycleScan {
            propertyCounts.increment(.lifecycleDoesNotFinalizeLiveSessions)
            let illegal = effects.contains {
                switch $0 {
                case .sealCurrentSegment, .finalizeCurrentSession, .removeRecoveredSession:
                    return true
                default:
                    return false
                }
            }
            if illegal {
                return .init(category: .propertyViolation, summary: "lifecycle scan finalized or sealed owned live session")
            }
        }

        if input.staleGenerationEvent {
            propertyCounts.increment(.staleGenerationIgnored)
            if !effects.isEmpty || stateBefore != stateAfter {
                return .init(category: .propertyViolation, summary: "stale-generation event mutated state or emitted effects")
            }
        }

        let pendingSealGenerations = Set(pendingBefore.compactMap(\.sealGeneration))
        let pendingRecoverGenerations = Set(pendingBefore.compactMap(\.recoverGeneration))
        if !pendingSealGenerations.isEmpty || !pendingRecoverGenerations.isEmpty {
            propertyCounts.increment(.causalOrdering)
            for effect in effects {
                switch effect {
                case let .recoverCurrentSession(generation, _):
                    if pendingSealGenerations.contains(generation) {
                        return .init(category: .propertyViolation, summary: "recover emitted before seal completion for generation \(generation)")
                    }
                case let .finalizeCurrentSession(generation, _, _):
                    if pendingSealGenerations.contains(generation) {
                        return .init(category: .propertyViolation, summary: "finalize emitted before seal completion for generation \(generation)")
                    }
                    if pendingRecoverGenerations.contains(generation) {
                        return .init(category: .propertyViolation, summary: "finalize emitted before recovery completion for generation \(generation)")
                    }
                default:
                    break
                }
            }
        }

        if let current = stateAfter.current,
           current.snapshot.phase == .blocked {
            propertyCounts.increment(.blockedStateHasEventDrivenExit)
            var probeState = stateAfter
            let probeEffects: [VoiceKernelEffect]
            if current.snapshot.blockerClearedAt == nil {
                probeEffects = kernel.step(
                    state: &probeState,
                    event: .blockedClearObserved(
                        source: "scene_active",
                        observedAt: Date(timeIntervalSince1970: TimeInterval(stepNumber))
                    )
                )
            } else {
                probeEffects = kernel.step(
                    state: &probeState,
                    event: .toggleRequested(
                        VoicePendingToggleRequest(
                            requestID: UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID(),
                            sourceSurface: CaptureSourceSurface.nativeRecorder.rawValue,
                            reason: "probe",
                            requestedAt: Date(timeIntervalSince1970: TimeInterval(stepNumber)),
                            reservedSessionID: "probe-session",
                            reservedCaptureID: "voice_probe"
                        )
                    )
                )
            }
            if probeEffects.isEmpty && probeState == stateAfter {
                return .init(category: .propertyViolation, summary: "blocked state lacked an event-driven exit")
            }
        }

        return nil
    }
}

private struct VoiceDSTWorld {
    var now: Date
    var requestOrdinal = 0
    var pendingEffects: [VoiceDSTPendingEffect] = []
    var replayableEvents: [VoiceDSTMaterializedInput] = []
    var currentSession: VoiceSessionSnapshot?
    var currentSegmentStartedAt: Date?
    var currentSegmentBytes: Int64 = 0
    var currentRecorderTime: TimeInterval = 0

    mutating func advanceTime(rng: inout DeterministicRNG, settling: Bool) {
        let milliseconds = settling ? 50 + rng.nextInt(upperBound: 120) : 100 + rng.nextInt(upperBound: 900)
        now = now.addingTimeInterval(TimeInterval(milliseconds) / 1000)
    }

    mutating func syncCurrentSession(from state: VoiceKernelState) {
        if let snapshot = state.current?.snapshot {
            currentSession = sanitizedActiveSession(snapshot)
        } else {
            currentSession = nil
        }
        if currentSession?.currentSegmentIndex == nil {
            currentSegmentStartedAt = nil
            currentSegmentBytes = 0
            currentRecorderTime = 0
        }
    }

    private func sanitizedActiveSession(_ session: VoiceSessionSnapshot) -> VoiceSessionSnapshot {
        guard session.phase.isActiveRecording || session.currentSegmentIndex != nil else {
            return session
        }

        var sanitized = session
        sanitized.finalBlobRelpath = nil
        sanitized.pendingCommitReason = nil
        return sanitized
    }

    func selectUrgentPendingEffect(
        stepNumber: Int,
        operations: [VoiceDSTOperation],
        threshold: Int
    ) -> Int? {
        let urgentGenerations = Set(
            operations
                .filter { !$0.resolved && stepNumber - $0.lastProgressStep >= max(threshold - 2, 1) }
                .map(\.generation)
        )

        guard !urgentGenerations.isEmpty else {
            return nil
        }

        return pendingEffects.firstIndex { effect in
            if let generation = effect.generation {
                return urgentGenerations.contains(generation)
            }
            return false
        }
    }

    mutating func applyImmediateEffects(
        _ effects: [VoiceKernelEffect],
        state: VoiceKernelState,
        stepNumber: Int,
        operations: inout [VoiceDSTOperation]
    ) {
        _ = stepNumber
        for effect in effects {
            switch effect {
            case .scanActiveSessions, .observeStartPrerequisites, .startReservedSession, .sealCurrentSegment, .scheduleRecoveryRetry, .finalizeCurrentSession, .recoverCurrentSession, .commitRecoveredSession:
                pendingEffects.append(.init(effect: effect, scheduledAt: now))
            case let .persistCurrentSession(_, session, _, _):
                currentSession = session
                if session.currentSegmentIndex == nil {
                    currentSegmentBytes = 0
                    currentRecorderTime = 0
                }
            case .resolveToggleResult:
                if let index = operations.firstIndex(where: { !$0.resolved }) {
                    operations[index].resolved = true
                }
            case .failToggle:
                if let index = operations.firstIndex(where: { $0.kind == .start && !$0.resolved }) ?? operations.firstIndex(where: { !$0.resolved }) {
                    operations[index].resolved = true
                }
            case let .removeRecoveredSession(session, _):
                if currentSession?.sessionID == session.sessionID {
                    currentSession = nil
                    currentSegmentBytes = 0
                    currentRecorderTime = 0
                }
            }
        }

        syncCurrentSession(from: state)
    }

    mutating func recordReplayableEvent(_ input: VoiceDSTMaterializedInput) {
        if input.canReplayAsStale {
            replayableEvents.append(input)
            if replayableEvents.count > 32 {
                replayableEvents.removeFirst(replayableEvents.count - 32)
            }
        }
    }

    mutating func completePendingEffect(
        at index: Int,
        rng: inout DeterministicRNG,
        currentGeneration: VoiceOperationGeneration?
    ) -> VoiceDSTMaterializedInput {
        let pending = pendingEffects.remove(at: index)
        switch pending.effect {
        case let .scanActiveSessions(trigger, request):
            let sessions = makeRecoveryObservations(trigger: trigger, request: request, rng: &rng)
            let ownedLifecycleScan = sessions.contains(where: {
                $0.ownership == .ownedByCurrentProcess && $0.session.phase.isActiveRecording
            }) && (trigger == .sceneActive || trigger == .protectedDataAvailable)
            let quarantinedCorruptBundleCount = rng.nextBool(probabilityPercent: sessions.isEmpty ? 10 : 20) ? 1 : 0
            let scaryStates: [VoiceDSTScaryState]
            var scaryStatesBuffer: [VoiceDSTScaryState] = []
            if quarantinedCorruptBundleCount > 0 && !sessions.isEmpty {
                scaryStatesBuffer.append(.corruptScanCoexistsWithValidBundle)
            }
            if sessions.contains(where: { $0.outboxCommitted }) {
                scaryStatesBuffer.append(.duplicateCommitLeftoverCleanup)
            }
            if sessions.contains(where: { $0.session.phase == .blocked }) {
                scaryStatesBuffer.append(.blockedSessionSurvivesProcessDeath)
            }
            if ownedLifecycleScan && currentSession?.phase == .arming {
                scaryStatesBuffer.append(.protectedDataDuringArming)
            }
            scaryStates = scaryStatesBuffer
            return VoiceDSTMaterializedInput(
                summary: "complete.scan.\(trigger.rawValue)",
                event: .recoveryScanCompleted(
                    trigger: trigger,
                    request: request,
                    sessions: sessions,
                    quarantinedCorruptBundleCount: quarantinedCorruptBundleCount
                ),
                staleGenerationEvent: false,
                informationalNoise: ownedLifecycleScan,
                ownedLifecycleScan: ownedLifecycleScan,
                scaryStates: scaryStates
            )
        case let .observeStartPrerequisites(request):
            return VoiceDSTMaterializedInput(
                summary: "complete.start_prereqs",
                event: .startPrerequisitesObserved(
                    request: request,
                    prerequisites: VoiceStartPrerequisites(
                        bootstrapReady: !rng.nextBool(probabilityPercent: 4),
                        microphonePermissionGranted: !rng.nextBool(probabilityPercent: 6),
                        liveActivityEnabled: !rng.nextBool(probabilityPercent: 5)
                    )
                ),
                staleGenerationEvent: false,
                informationalNoise: false,
                ownedLifecycleScan: false,
                scaryStates: []
            )
        case let .startReservedSession(session, generation, _):
            if rng.nextBool(probabilityPercent: 12) {
                return VoiceDSTMaterializedInput(
                    summary: "complete.start.failure",
                    event: .startFailed(generation: generation, error: .recorderFailed("simulated_start_failure")),
                    staleGenerationEvent: false,
                    informationalNoise: false,
                    ownedLifecycleScan: false,
                    scaryStates: []
                )
            }
            let started = makeStartedSession(from: session)
            currentSession = started
            return VoiceDSTMaterializedInput(
                summary: "complete.start.success",
                event: .startSucceeded(generation: generation, session: started),
                staleGenerationEvent: false,
                informationalNoise: false,
                ownedLifecycleScan: false,
                scaryStates: []
            )
        case let .sealCurrentSegment(generation, reason):
            if rng.nextBool(probabilityPercent: 10) {
                return VoiceDSTMaterializedInput(
                    summary: "complete.seal.failure.\(reason.rawValue)",
                    event: .segmentSealFailed(generation: generation, reason: reason, error: .recorderFailed("simulated_seal_failure")),
                    staleGenerationEvent: false,
                    informationalNoise: false,
                    ownedLifecycleScan: false,
                    scaryStates: [.delayedSealBeforeFinalize]
                )
            }
            let session = makeSealedSession(reason: reason)
            currentSession = session
            return VoiceDSTMaterializedInput(
                summary: "complete.seal.success.\(reason.rawValue)",
                event: .segmentSealed(generation: generation, session: session),
                staleGenerationEvent: false,
                informationalNoise: false,
                ownedLifecycleScan: false,
                scaryStates: [.delayedSealBeforeFinalize]
            )
        case let .scheduleRecoveryRetry(generation, after):
            return VoiceDSTMaterializedInput(
                summary: "complete.recovery_retry.\(after.components.seconds)",
                event: .recoveryRetryRequested(generation: generation),
                staleGenerationEvent: false,
                informationalNoise: false,
                ownedLifecycleScan: false,
                scaryStates: [.recoveryFailureAndRetry]
            )
        case let .recoverCurrentSession(generation, reason):
            if rng.nextBool(probabilityPercent: 25) {
                return VoiceDSTMaterializedInput(
                    summary: "complete.recovery.blocked.\(reason.rawValue)",
                    event: .recoveryBlocked(
                        generation: generation,
                        reason: reason,
                        retryClass: .externalBlocker,
                        error: .recorderFailed(recoveryBlockedReason)
                    ),
                    staleGenerationEvent: false,
                    informationalNoise: false,
                    ownedLifecycleScan: false,
                    scaryStates: [.recoveryFailureAndRetry]
                )
            }
            if rng.nextBool(probabilityPercent: 10) {
                return VoiceDSTMaterializedInput(
                    summary: "complete.recovery.self_healing.\(reason.rawValue)",
                    event: .recoveryBlocked(
                        generation: generation,
                        reason: reason,
                        retryClass: .selfHealing,
                        error: .recorderFailed("simulated_engine_glitch")
                    ),
                    staleGenerationEvent: false,
                    informationalNoise: false,
                    ownedLifecycleScan: false,
                    scaryStates: [.recoveryFailureAndRetry]
                )
            }
            if rng.nextBool(probabilityPercent: 12) {
                return VoiceDSTMaterializedInput(
                    summary: "complete.recovery.failed.\(reason.rawValue)",
                    event: .recoveryFailed(generation: generation, reason: reason, error: .recorderFailed("simulated_recovery_failure")),
                    staleGenerationEvent: false,
                    informationalNoise: false,
                    ownedLifecycleScan: false,
                    scaryStates: [.recoveryFailureAndRetry]
                )
            }
            let session = makeRecoveredSession(reason: reason)
            currentSession = session
            return VoiceDSTMaterializedInput(
                summary: "complete.recovery.success.\(reason.rawValue)",
                event: .recoverySucceeded(generation: generation, session: session),
                staleGenerationEvent: false,
                informationalNoise: false,
                ownedLifecycleScan: false,
                scaryStates: []
            )
        case let .finalizeCurrentSession(generation, _, _):
            let result = makeFinalizationResult(rng: &rng)
            return VoiceDSTMaterializedInput(
                summary: "complete.finalize.\(result.result.action.label)",
                event: .operationFinished(generation: generation, result: result.result, resultingSession: result.session),
                staleGenerationEvent: false,
                informationalNoise: false,
                ownedLifecycleScan: false,
                scaryStates: []
            )
        case let .commitRecoveredSession(_, generation, _):
            let result = makeFinalizationResult(rng: &rng)
            return VoiceDSTMaterializedInput(
                summary: "complete.commit_recovered.\(result.result.action.label)",
                event: .operationFinished(generation: generation, result: result.result, resultingSession: result.session),
                staleGenerationEvent: false,
                informationalNoise: false,
                ownedLifecycleScan: false,
                scaryStates: []
            )
        case .removeRecoveredSession, .resolveToggleResult, .failToggle, .persistCurrentSession:
            fatalError("non-pending effect completed through pending queue")
        }
    }

    mutating func replayStaleEvent(
        rng: inout DeterministicRNG,
        currentGeneration: VoiceOperationGeneration?
    ) -> VoiceDSTMaterializedInput {
        let original = replayableEvents[rng.nextInt(upperBound: replayableEvents.count)]
        let staleEvent = VoiceDSTNormalizer.makeStale(event: original.event, currentGeneration: currentGeneration, observedAt: now)
        return VoiceDSTMaterializedInput(
            summary: "replay.stale.\(original.summary)",
            event: staleEvent,
            staleGenerationEvent: VoiceDSTNormalizer.hasGeneration(event: staleEvent),
            informationalNoise: false,
            ownedLifecycleScan: false,
            scaryStates: [.staleGenerationReplay]
        )
    }

    mutating func makeExternalInput(
        state: VoiceKernelState,
        rng: inout DeterministicRNG,
        seed: UInt64
    ) -> VoiceDSTMaterializedInput {
        let currentGeneration = state.current?.generation
        let currentPhase = state.current?.snapshot.phase
        var candidates: [VoiceDSTMaterializedInput] = []

        candidates.append(makeToggleInput(state: state, rng: &rng, seed: seed))
        candidates.append(
            VoiceDSTMaterializedInput(
                summary: "external.scan.scene_active",
                event: .recoveryScanRequested(trigger: .sceneActive),
                staleGenerationEvent: false,
                informationalNoise: currentPhase?.isActiveRecording == true,
                ownedLifecycleScan: false,
                scaryStates: currentPhase == .recovering ? [.duplicateLifecycleDuringRoll] : []
            )
        )
        candidates.append(
            VoiceDSTMaterializedInput(
                summary: "external.scan.protected_data",
                event: .recoveryScanRequested(trigger: .protectedDataAvailable),
                staleGenerationEvent: false,
                informationalNoise: currentPhase?.isActiveRecording == true,
                ownedLifecycleScan: false,
                scaryStates: currentPhase == .arming ? [.protectedDataDuringArming] : (currentPhase == .recovering ? [.duplicateLifecycleDuringRoll] : [])
            )
        )

        if let currentGeneration {
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.route.new_device_available",
                    event: .routeChanged(
                        generation: currentGeneration,
                        observation: VoiceRouteChangeObservation(reason: .newDeviceAvailable, inputRouteChanged: true),
                        observedAt: now
                    ),
                    staleGenerationEvent: false,
                    informationalNoise: true,
                    ownedLifecycleScan: false,
                    scaryStates: currentPhase?.isActiveRecording == true ? [.informationalRouteNoiseDuringRecording] : []
                )
            )
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.route.category_change",
                    event: .routeChanged(
                        generation: currentGeneration,
                        observation: VoiceRouteChangeObservation(reason: .categoryChange, inputRouteChanged: false),
                        observedAt: now
                    ),
                    staleGenerationEvent: false,
                    informationalNoise: true,
                    ownedLifecycleScan: false,
                    scaryStates: currentPhase == .recovering ? [.informationalRouteNoiseDuringRecording] : []
                )
            )
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.route.override",
                    event: .routeChanged(
                        generation: currentGeneration,
                        observation: VoiceRouteChangeObservation(reason: .override, inputRouteChanged: false),
                        observedAt: now
                    ),
                    staleGenerationEvent: false,
                    informationalNoise: true,
                    ownedLifecycleScan: false,
                    scaryStates: currentPhase?.isActiveRecording == true ? [.informationalRouteNoiseDuringRecording] : []
                )
            )
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.route.old_device_unavailable",
                    event: .routeChanged(
                        generation: currentGeneration,
                        observation: VoiceRouteChangeObservation(reason: .oldDeviceUnavailable, inputRouteChanged: true),
                        observedAt: now
                    ),
                    staleGenerationEvent: false,
                    informationalNoise: true,
                    ownedLifecycleScan: false,
                    scaryStates: currentPhase?.isActiveRecording == true ? [.informationalRouteNoiseDuringRecording] : []
                )
            )
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.configuration_changed",
                    event: .configurationChanged(generation: currentGeneration, observedAt: now),
                    staleGenerationEvent: false,
                    informationalNoise: true,
                    ownedLifecycleScan: false,
                    scaryStates: [.routeChangeFollowedByConfigurationChange]
                )
            )
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.unexpected_stop.current",
                    event: .unexpectedRecorderStop(generation: currentGeneration, reason: "simulated", observedAt: now),
                    staleGenerationEvent: false,
                    informationalNoise: false,
                    ownedLifecycleScan: false,
                    scaryStates: []
                )
            )

            let staleGeneration = currentGeneration > 1 ? currentGeneration - 1 : 0
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.route.stale",
                    event: .routeChanged(
                        generation: staleGeneration,
                        observation: VoiceRouteChangeObservation(reason: .oldDeviceUnavailable, inputRouteChanged: true),
                        observedAt: now
                    ),
                    staleGenerationEvent: true,
                    informationalNoise: true,
                    ownedLifecycleScan: false,
                    scaryStates: [.staleGenerationReplay]
                )
            )
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.unexpected_stop.stale",
                    event: .unexpectedRecorderStop(generation: staleGeneration, reason: "stale", observedAt: now),
                    staleGenerationEvent: true,
                    informationalNoise: false,
                    ownedLifecycleScan: false,
                    scaryStates: [.staleGenerationReplay]
                )
            )
        }

        if let session = currentSession, session.phase == .blocked {
            if session.blockerClearedAt == nil {
                candidates.append(
                    VoiceDSTMaterializedInput(
                        summary: "external.blocked_clear.scene_active",
                        event: .blockedClearObserved(source: "scene_active", observedAt: now),
                        staleGenerationEvent: false,
                        informationalNoise: false,
                        ownedLifecycleScan: false,
                        scaryStates: [.blockedAwaitingUserResume]
                    )
                )
            } else {
                candidates.append(
                    VoiceDSTMaterializedInput(
                        summary: "external.blocked_deadline.observe",
                        event: .blockedDeadlineObservedExpired(observedAt: now),
                        staleGenerationEvent: false,
                        informationalNoise: false,
                        ownedLifecycleScan: false,
                        scaryStates: [.blockedDeadlineObservedOnScan]
                    )
                )
            }
        }

        if let session = currentSession,
           let generation = currentGeneration,
           session.phase == .recordingUnverified || session.phase == .recordingLive || session.phase == .suspectedStall {
            candidates.append(makeLivenessInput(session: session, generation: generation, rng: &rng, hadProgress: true))
            candidates.append(makeLivenessInput(session: session, generation: generation, rng: &rng, hadProgress: false))
        }

        if currentSession != nil, currentGeneration != nil {
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.interruption.current",
                    event: .interruptionBegan(reason: .system, observedAt: now),
                    staleGenerationEvent: false,
                    informationalNoise: false,
                    ownedLifecycleScan: false,
                    scaryStates: []
                )
            )
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.interruption.app_suspended",
                    event: .interruptionBegan(reason: .appWasSuspended, observedAt: now),
                    staleGenerationEvent: false,
                    informationalNoise: false,
                    ownedLifecycleScan: false,
                    scaryStates: []
                )
            )
            candidates.append(
                VoiceDSTMaterializedInput(
                    summary: "external.media_services_reset",
                    event: .mediaServicesWereReset(observedAt: now),
                    staleGenerationEvent: false,
                    informationalNoise: false,
                    ownedLifecycleScan: false,
                    scaryStates: []
                )
            )

            if let session = currentSession,
               let generation = currentGeneration,
               session.phase == .recordingUnverified || session.phase == .recordingLive || session.phase == .suspectedStall {
                let staleGeneration = generation > 1 ? generation - 1 : 0
                candidates.append(makeLivenessInput(session: session, generation: staleGeneration, rng: &rng, hadProgress: false, stale: true))
            }
        }

        return candidates[rng.nextInt(upperBound: candidates.count)]
    }

    mutating func makeToggleInput(
        state: VoiceKernelState,
        rng: inout DeterministicRNG,
        seed: UInt64,
        scaryOverride: VoiceDSTScaryState? = nil
    ) -> VoiceDSTMaterializedInput {
        requestOrdinal += 1
        let requestTime = now
        let requestID = deterministicUUID(rng: &rng)
        let reservedSessionID = "dst-session-\(seed)-\(requestOrdinal)"
        let reservedCaptureID = "voice_\(CaptureDateCodec.captureIDTimestamp(requestTime))_\(String(format: "%03d", requestOrdinal))"
        let request = VoicePendingToggleRequest(
            requestID: requestID,
            sourceSurface: CaptureSourceSurface.nativeRecorder.rawValue,
            reason: "app_intent",
            requestedAt: requestTime,
            reservedSessionID: reservedSessionID,
            reservedCaptureID: reservedCaptureID
        )
        let scaryState = scaryOverride ?? {
            switch state.current?.snapshot.phase {
            case .finalizing:
                return .toggleDuringFinalization
            case .arming, .starting:
                return .rapidDoubleToggleDuringStartup
            case .stopping, .recovering:
                return .toggleDuringRecoveryOrStop
            default:
                return nil
            }
        }()
        return VoiceDSTMaterializedInput(
            summary: "external.toggle",
            event: .toggleRequested(request),
            staleGenerationEvent: false,
            informationalNoise: false,
            ownedLifecycleScan: false,
            scaryStates: scaryState.map { [$0] } ?? []
        )
    }

    private mutating func makeLivenessInput(
        session: VoiceSessionSnapshot,
        generation: VoiceOperationGeneration,
        rng: inout DeterministicRNG,
        hadProgress: Bool,
        stale: Bool = false
    ) -> VoiceDSTMaterializedInput {
        var updated = sanitizedActiveSession(session)
        let observedAt = now
        let previousBytes = currentSegmentBytes
        let previousRecorderTime = currentRecorderTime

        if hadProgress {
            currentSegmentBytes += Int64(512 + rng.nextInt(upperBound: 4096))
            currentRecorderTime += TimeInterval(1 + rng.nextInt(upperBound: 4))
            updated.lastProgressAt = observedAt
            if let segmentIndex = updated.currentSegmentIndex,
               let index = updated.segments.firstIndex(where: { $0.index == segmentIndex }) {
                updated.segments[index].bytes = currentSegmentBytes
            }
        }

        updated.updatedAt = observedAt
        updated.heartbeatAt = observedAt
        let actualGeneration = stale ? (generation > 1 ? generation - 1 : 0) : generation

        return VoiceDSTMaterializedInput(
            summary: stale ? "external.liveness.stale" : (hadProgress ? "external.liveness.progress" : "external.liveness.no_progress"),
            event: .livenessObserved(
                generation: actualGeneration,
                session: updated,
                observation: VoiceLivenessObservation(
                    observedAt: observedAt,
                    startedAt: currentSegmentStartedAt,
                    lastProgressAt: hadProgress ? observedAt : updated.lastProgressAt,
                    fileBytes: currentSegmentBytes,
                    recorderTime: currentRecorderTime,
                    previousFileBytes: previousBytes,
                    previousRecorderTime: previousRecorderTime
                )
            ),
            staleGenerationEvent: stale,
            informationalNoise: false,
            ownedLifecycleScan: false,
            scaryStates: hadProgress ? [] : []
        )
    }

    private func makeRecoveryObservations(
        trigger: VoiceRecoveryTrigger,
        request: VoicePendingToggleRequest?,
        rng: inout DeterministicRNG
    ) -> [VoiceRecoveryObservation] {
        _ = request
        guard let currentSession else {
            return []
        }
        let session = sanitizedActiveSession(currentSession)
        return [
            VoiceRecoveryObservation(
                session: session,
                ownership: .ownedByCurrentProcess,
                observedAt: now,
                outboxCommitted: session.finalBlobRelpath != nil && rng.nextBool(probabilityPercent: 35)
            )
        ]
    }

    private mutating func makeStartedSession(from session: VoiceSessionSnapshot) -> VoiceSessionSnapshot {
        var started = session
        started.phase = .recordingUnverified
        started.updatedAt = now
        started.heartbeatAt = now
        started.audioFile = VoiceAudioFileSnapshot(
            relpath: "voice.caf",
            status: .open,
            openedAt: now,
            closedAt: nil,
            bytes: 0,
            repairStatus: .notNeeded,
            sealReason: nil
        )
        currentSegmentStartedAt = now
        currentSegmentBytes = 0
        currentRecorderTime = 0
        return started
    }

    private mutating func makeRecoveredSession(reason: VoiceSegmentSealReason) -> VoiceSessionSnapshot {
        guard var session = currentSession else {
            return makeStartedSession(
                from: VoiceSessionSnapshot(
                    sessionID: "dst-recovery-missing",
                    captureID: "voice_dst_recovery_missing",
                    phase: .recovering,
                    sourceSurface: CaptureSourceSurface.nativeRecorder.rawValue,
                    createdAt: now,
                    updatedAt: now,
                    heartbeatAt: now,
                    lastProgressAt: nil,
                    failureReason: nil,
                    recoveryCount: 0,
                    preferredInputUID: nil,
                    currentSegmentIndex: nil,
                    currentSegmentRelpath: nil,
                    segments: [],
                    finalBlobRelpath: nil,
                    pendingCommitReason: nil,
                    blockedReason: nil,
                    blockerClearedAt: nil,
                    blockedAutoFinalizeAt: nil,
                    context: [:]
                )
            )
        }

        let relpath = session.audioFile?.relpath ?? "voice.caf"
        let openedAt = session.audioFile?.openedAt ?? now
        let preservedBytes = max(currentSegmentBytes, session.audioFile?.bytes ?? 0)
        session.phase = reason == .inputFormatChange ? .recordingLive : .recordingUnverified
        session.finalBlobRelpath = nil
        session.pendingCommitReason = nil
        session.updatedAt = now
        session.heartbeatAt = now
        session.audioFile = VoiceAudioFileSnapshot(
            relpath: relpath,
            status: .open,
            openedAt: openedAt,
            closedAt: nil,
            bytes: preservedBytes,
            repairStatus: .notNeeded,
            sealReason: nil
        )
        currentSegmentStartedAt = now
        currentSegmentBytes = preservedBytes
        return session
    }

    private mutating func makeSealedSession(reason: VoiceSegmentSealReason) -> VoiceSessionSnapshot {
        guard var session = currentSession else {
            return VoiceSessionSnapshot(
                sessionID: "dst-seal-missing",
                captureID: "voice_dst_seal_missing",
                phase: .finalizing,
                sourceSurface: CaptureSourceSurface.nativeRecorder.rawValue,
                createdAt: now,
                updatedAt: now,
                heartbeatAt: now,
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
        }

        if var audioFile = session.audioFile {
            audioFile.status = currentSegmentBytes > 0 ? .closed : .quarantined
            audioFile.bytes = currentSegmentBytes
            audioFile.closedAt = now
            audioFile.sealReason = reason
            session.audioFile = audioFile
        }
        session.updatedAt = now
        session.heartbeatAt = now
        currentSegmentStartedAt = nil
        currentSegmentBytes = 0
        currentRecorderTime = 0
        return session
    }

    private mutating func makeFinalizationResult(rng: inout DeterministicRNG) -> (result: VoiceToggleResult, session: VoiceSessionSnapshot?) {
        guard var session = currentSession else {
            let result = VoiceToggleResult(action: .lost(captureID: "voice_missing"), sessionID: nil)
            return (result, nil)
        }

        let hasDurableAudio = (session.audioFile?.bytes ?? 0) > 0
        if hasDurableAudio && currentSession?.finalBlobRelpath == nil {
            session.finalBlobRelpath = session.audioFile?.relpath ?? "voice.caf"
        }

        if hasDurableAudio && session.pendingCommitReason == nil && !rng.nextBool(probabilityPercent: 40) {
            let result = VoiceToggleResult(action: .finalized(captureID: session.captureID), sessionID: session.sessionID)
            currentSession = nil
            currentSegmentBytes = 0
            currentRecorderTime = 0
            return (result, nil)
        }

        if hasDurableAudio {
            session.phase = .commitDeferred
            session.pendingCommitReason = "protected_data_unavailable"
            session.updatedAt = now
            session.heartbeatAt = now
            currentSession = session
            let result = VoiceToggleResult(action: .deferred(captureID: session.captureID), sessionID: session.sessionID)
            return (result, session)
        }

        session.phase = .lost
        session.failureReason = VoiceCaptureError.noRecoverableAudio.localizedDescription
        session.updatedAt = now
        session.heartbeatAt = now
        currentSession = nil
        let result = VoiceToggleResult(action: .lost(captureID: session.captureID), sessionID: session.sessionID)
        return (result, nil)
    }

    private mutating func deterministicUUID(rng: inout DeterministicRNG) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let lhs = rng.next()
        let rhs = rng.next()
        withUnsafeBytes(of: lhs.bigEndian) { bytes.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: rhs.bigEndian) { bytes.replaceSubrange(8..<16, with: $0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private enum VoiceDSTProperty: String, CaseIterable {
    case ownershipCoherence = "ownership_coherence"
    case destructiveProof = "destructive_proof"
    case acceptedIntentResolution = "accepted_intent_resolution"
    case informationalEventsInert = "informational_events_inert"
    case startedResolutionRequiresLiveEvidence = "started_resolution_requires_live_evidence"
    case lifecycleDoesNotFinalizeLiveSessions = "lifecycle_does_not_finalize_live_sessions"
    case staleGenerationIgnored = "stale_generation_ignored"
    case causalOrdering = "causal_ordering"
    case blockedStateHasEventDrivenExit = "blocked_state_has_event_driven_exit"
}

private enum VoiceDSTScaryState: String, CaseIterable {
    case protectedDataDuringArming = "protected_data_during_arming"
    case toggleDuringFinalization = "toggle_during_finalization"
    case toggleDuringRecoveryOrStop = "toggle_during_recovery_or_stop"
    case informationalRouteNoiseDuringRecording = "informational_route_noise_during_recording"
    case staleGenerationReplay = "stale_generation_replay"
    case delayedSealBeforeFinalize = "delayed_seal_before_finalize"
    case recoveryFailureAndRetry = "recovery_failure_and_retry"
    case duplicateLifecycleDuringRoll = "duplicate_lifecycle_during_roll"
    case corruptScanCoexistsWithValidBundle = "corrupt_scan_coexists_with_valid_bundle"
    case routeChangeFollowedByConfigurationChange = "route_change_followed_by_configuration_change"
    case blockedAwaitingUserResume = "blocked_awaiting_user_resume"
    case blockedDeadlineObservedOnScan = "blocked_deadline_observed_on_scan"
    case blockedSessionSurvivesProcessDeath = "blocked_session_survives_process_death"
    case duplicateCommitLeftoverCleanup = "duplicate_commit_leftover_cleanup"
    case rapidDoubleToggleDuringStartup = "rapid_double_toggle_during_startup"
}

private enum VoiceDSTFailureCategory: String, Codable {
    case propertyViolation = "property"
    case livenessViolation = "liveness"
    case harnessIntegrity = "harness_integrity"
}

private struct VoiceDSTFailure: Codable {
    let category: VoiceDSTFailureCategory
    let seed: UInt64
    let summary: String
    let tracePath: String?
}

private struct VoiceDSTStepFailure {
    let category: VoiceDSTFailureCategory
    let summary: String
}

private struct VoiceDSTSeedSummary: Codable {
    let seed: UInt64
    let status: String
    let category: String?
}

private struct VoiceDTRunResult: Codable {
    let runID: String
    let success: Bool
    let failure: VoiceDSTFailure?
    let seedSummaries: [VoiceDSTSeedSummary]
    let propertyCounts: [String: Int]
    let scaryCounts: [String: Int]

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.voiceDST.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

private struct VoiceDSTSeedRunResult {
    let trace: [VoiceDSTTraceEntry]
    let finalState: VoiceDSTStateSummary
    let propertyCounts: VoiceDSTCounterSet<VoiceDSTProperty>
    let scaryCounts: VoiceDSTCounterSet<VoiceDSTScaryState>
    let failure: VoiceDSTStepFailure?
}

private struct VoiceDSTTraceEntry: Codable, Equatable {
    let step: Int
    let input: String
    let event: String
    let effects: [String]
    let state: VoiceDSTStateSummary
}

private struct VoiceDSTStateSummary: Codable, Equatable {
    let nextGeneration: VoiceOperationGeneration
    let recoveryAttempts: Int
    let currentGeneration: VoiceOperationGeneration?
    let currentPhase: String?
    let sessionID: String?
    let captureID: String?
    let currentSegmentIndex: Int?
    let sealedPositiveByteSegments: Int
    let finalBlobPresent: Bool
    let pendingCommitReason: String?
    let pendingSealContinuation: String?
    let blockedRecoveryReason: String?
    let blockedRecoveryRetryClass: String?
    let recoveryRetryCount: Int
    let toggleRequestCount: Int

    static func make(from state: VoiceKernelState) -> VoiceDSTStateSummary {
        VoiceDSTStateSummary(
            nextGeneration: state.nextGeneration,
            recoveryAttempts: state.recoveryAttempts.count,
            currentGeneration: state.current?.generation,
            currentPhase: state.current?.snapshot.phase.rawValue,
            sessionID: state.current?.snapshot.sessionID,
            captureID: state.current?.snapshot.captureID,
            currentSegmentIndex: state.current?.snapshot.currentSegmentIndex,
            sealedPositiveByteSegments: state.current?.snapshot.segments.filter { $0.status == .sealed && $0.bytes > 0 }.count ?? 0,
            finalBlobPresent: state.current?.snapshot.finalBlobRelpath != nil,
            pendingCommitReason: state.current?.snapshot.pendingCommitReason,
            pendingSealContinuation: state.current?.pendingSealContinuation.map(VoiceDSTNormalizer.describe(continuation:)),
            blockedRecoveryReason: state.current?.blockedRecoveryReason?.rawValue,
            blockedRecoveryRetryClass: state.current?.blockedRecoveryRetryClass?.rawValue,
            recoveryRetryCount: state.current?.recoveryRetryCount ?? 0,
            toggleRequestCount: state.current?.toggleRequestIDs.count ?? 0
        )
    }
}

private struct VoiceDSTMaterializedInput {
    let summary: String
    let event: VoiceKernelEvent
    let staleGenerationEvent: Bool
    let informationalNoise: Bool
    let ownedLifecycleScan: Bool
    let scaryStates: [VoiceDSTScaryState]

    var canReplayAsStale: Bool {
        VoiceDSTNormalizer.hasGeneration(event: event)
    }
}

private struct VoiceDSTPendingEffect {
    let effect: VoiceKernelEffect
    let scheduledAt: Date

    var generation: VoiceOperationGeneration? {
        switch effect {
        case let .startReservedSession(_, generation, _),
             let .persistCurrentSession(generation, _, _, _),
             let .sealCurrentSegment(generation, _),
             let .scheduleRecoveryRetry(generation, _),
             let .finalizeCurrentSession(generation, _, _),
             let .recoverCurrentSession(generation, _),
             let .commitRecoveredSession(_, generation, _):
            return generation
        case .scanActiveSessions, .observeStartPrerequisites, .removeRecoveredSession, .resolveToggleResult, .failToggle:
            return nil
        }
    }

    var sealGeneration: VoiceOperationGeneration? {
        if case let .sealCurrentSegment(generation, _) = effect {
            return generation
        }
        return nil
    }

    var recoverGeneration: VoiceOperationGeneration? {
        if case let .recoverCurrentSession(generation, _) = effect {
            return generation
        }
        return nil
    }
}

private enum VoiceDSTOperationKind: String {
    case start
    case stop
}

private struct VoiceDSTOperation {
    let kind: VoiceDSTOperationKind
    let generation: VoiceOperationGeneration
    let acceptedAtStep: Int
    var lastProgressStep: Int
    var resolved = false
}

private struct VoiceDSTCounterSet<Key: Hashable & CaseIterable & RawRepresentable>: Equatable where Key.RawValue == String {
    private var storage: [Key: Int] = [:]

    mutating func increment(_ key: Key) {
        storage[key, default: 0] += 1
    }

    mutating func merge(_ other: VoiceDSTCounterSet<Key>) {
        for (key, value) in other.storage {
            storage[key, default: 0] += value
        }
    }

    func dictionary() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: Key.allCases.map { key in
            (key.rawValue, storage[key, default: 0])
        })
    }

    func count(for key: Key) -> Int {
        storage[key, default: 0]
    }

    func zeroKeys(allCases: [Key]) -> [Key] {
        allCases.filter { storage[$0, default: 0] == 0 }
    }
}

private struct VoiceDSTDestructiveEffect {
    let sessionID: String?
    let generation: VoiceOperationGeneration?
    let proof: VoiceDestructiveProof
    let summary: String

    init?(_ effect: VoiceKernelEffect) {
        switch effect {
        case let .finalizeCurrentSession(generation, reason, proof):
            self.sessionID = nil
            self.generation = generation
            self.proof = proof
            self.summary = "finalize:\(reason.rawValue)"
        case let .commitRecoveredSession(session, generation, proof):
            self.sessionID = session.sessionID
            self.generation = generation
            self.proof = proof
            self.summary = "commit_recovered:\(session.sessionID)"
        case let .removeRecoveredSession(session, proof):
            self.sessionID = session.sessionID
            self.generation = nil
            self.proof = proof
            self.summary = "remove_recovered:\(session.sessionID)"
        default:
            return nil
        }
    }

    func isValid(against state: VoiceKernelState) -> Bool {
        if let generation, proof.generation != generation {
            return false
        }
        if let sessionID, proof.sessionID != sessionID {
            return false
        }
        if sessionID == nil,
           let current = state.current,
           proof.sessionID != current.snapshot.sessionID {
            return false
        }
        if proof.reason == .recoveryClassification && proof.recoveryDecision == nil {
            return false
        }
        if proof.reason == .recoveryCommit && proof.recoveryDecision != .commitDeferred {
            return false
        }
        if proof.reason == .terminalCleanup && proof.recoveryDecision != .terminalCleanup {
            return false
        }
        return true
    }
}

private enum VoiceDSTNormalizer {
    static func describe(event: VoiceKernelEvent) -> String {
        switch event {
        case let .toggleRequested(request):
            return "toggleRequested:\(request.requestID.uuidString.lowercased()):\(request.reason):\(request.reservedSessionID)"
        case let .recoveryScanRequested(trigger):
            return "recoveryScanRequested:\(trigger.rawValue)"
        case let .recoveryScanCompleted(trigger, request, sessions, quarantinedCorruptBundleCount):
            let requestTag = request?.requestID.uuidString.lowercased() ?? "none"
            let sessionTag = sessions.map {
                "\($0.session.sessionID):\($0.ownership.rawValue):\($0.session.phase.rawValue):\($0.outboxCommitted)"
            }.joined(separator: ",")
            return "recoveryScanCompleted:\(trigger.rawValue):\(requestTag):\(quarantinedCorruptBundleCount):[\(sessionTag)]"
        case let .startPrerequisitesObserved(request, prerequisites):
            return "startPrerequisitesObserved:\(request.requestID.uuidString.lowercased()):\(prerequisites.bootstrapReady):\(prerequisites.microphonePermissionGranted):\(prerequisites.liveActivityEnabled)"
        case let .startSucceeded(generation, session):
            return "startSucceeded:\(generation):\(session.sessionID):\(session.phase.rawValue)"
        case let .startFailed(generation, error):
            return "startFailed:\(generation):\(error.localizedDescription)"
        case let .livenessObserved(generation, session, observation):
            return "livenessObserved:\(generation):\(session.phase.rawValue):\(observation.fileBytes):\(observation.recorderTime)"
        case let .routeChanged(generation, observation, observedAt):
            let routeChange = switch observation.inputRouteChanged {
            case .some(true):
                "true"
            case .some(false):
                "false"
            case .none:
                "unknown"
            }
            return "routeChanged:\(generation):\(observation.reason.rawValue):\(routeChange):\(CaptureDateCodec.internetString(observedAt))"
        case let .configurationChanged(generation, observedAt):
            return "configurationChanged:\(generation):\(CaptureDateCodec.internetString(observedAt))"
        case let .interruptionBegan(reason, observedAt):
            return "interruptionBegan:\(reason.rawValue):\(CaptureDateCodec.internetString(observedAt))"
        case let .blockedClearObserved(source, observedAt):
            return "blockedClearObserved:\(source):\(CaptureDateCodec.internetString(observedAt))"
        case let .blockedDeadlineObservedExpired(observedAt):
            return "blockedDeadlineObservedExpired:\(CaptureDateCodec.internetString(observedAt))"
        case let .mediaServicesWereReset(observedAt):
            return "mediaServicesWereReset:\(CaptureDateCodec.internetString(observedAt))"
        case let .unexpectedRecorderStop(generation, reason, observedAt):
            return "unexpectedRecorderStop:\(generation):\(reason):\(CaptureDateCodec.internetString(observedAt))"
        case let .segmentSealed(generation, session):
            return "segmentSealed:\(generation):\(session.sessionID):\(session.audioFile?.bytes ?? 0)"
        case let .segmentSealFailed(generation, reason, error):
            return "segmentSealFailed:\(generation):\(reason.rawValue):\(error.localizedDescription)"
        case let .recoverySucceeded(generation, session):
            return "recoverySucceeded:\(generation):\(session.sessionID):\(session.audioFile?.bytes ?? 0)"
        case let .recoveryBlocked(generation, reason, retryClass, error):
            return "recoveryBlocked:\(generation):\(reason.rawValue):\(retryClass.rawValue):\(error.localizedDescription)"
        case let .recoveryFailed(generation, reason, error):
            return "recoveryFailed:\(generation):\(reason.rawValue):\(error.localizedDescription)"
        case let .recoveryRetryRequested(generation):
            return "recoveryRetryRequested:\(generation)"
        case let .operationFinished(generation, result, resultingSession):
            return "operationFinished:\(generation):\(result.action.label):\(resultingSession?.phase.rawValue ?? "none")"
        }
    }

    static func describe(effect: VoiceKernelEffect) -> String {
        switch effect {
        case let .scanActiveSessions(trigger, request):
            return "scanActiveSessions:\(trigger.rawValue):\(request?.requestID.uuidString.lowercased() ?? "none")"
        case let .observeStartPrerequisites(request):
            return "observeStartPrerequisites:\(request.requestID.uuidString.lowercased())"
        case let .startReservedSession(session, generation, mixWithOthers):
            return "startReservedSession:\(session.sessionID):\(generation):\(mixWithOthers)"
        case let .persistCurrentSession(generation, session, previousPhase, reason):
            return "persistCurrentSession:\(generation):\(session.phase.rawValue):\(previousPhase.rawValue):\(reason)"
        case let .sealCurrentSegment(generation, reason):
            return "sealCurrentSegment:\(generation):\(reason.rawValue)"
        case let .scheduleRecoveryRetry(generation, after):
            return "scheduleRecoveryRetry:\(generation):\(after.components.seconds)"
        case let .finalizeCurrentSession(generation, reason, proof):
            return "finalizeCurrentSession:\(generation):\(reason.rawValue):\(proof.reason.rawValue)"
        case let .recoverCurrentSession(generation, reason):
            return "recoverCurrentSession:\(generation):\(reason.rawValue)"
        case let .commitRecoveredSession(session, generation, proof):
            return "commitRecoveredSession:\(session.sessionID):\(generation):\(proof.reason.rawValue)"
        case let .removeRecoveredSession(session, proof):
            return "removeRecoveredSession:\(session.sessionID):\(proof.reason.rawValue)"
        case let .resolveToggleResult(requestIDs, result):
            return "resolveToggleResult:\(requestIDs.count):\(result.action.label)"
        case let .failToggle(requestIDs, error):
            return "failToggle:\(requestIDs.count):\(error.localizedDescription)"
        }
    }

    static func describe(continuation: VoicePendingSealContinuation) -> String {
        switch continuation {
        case let .recover(reason):
            return "recover:\(reason.rawValue)"
        case let .finalize(reason, proof):
            return "finalize:\(reason.rawValue):\(proof.reason.rawValue)"
        }
    }

    static func hasGeneration(event: VoiceKernelEvent) -> Bool {
        switch event {
        case .toggleRequested, .recoveryScanRequested, .recoveryScanCompleted, .startPrerequisitesObserved, .interruptionBegan, .blockedClearObserved, .blockedDeadlineObservedExpired, .mediaServicesWereReset:
            return false
        case .startSucceeded, .startFailed, .livenessObserved, .routeChanged, .configurationChanged, .unexpectedRecorderStop, .segmentSealed, .segmentSealFailed, .recoverySucceeded, .recoveryBlocked, .recoveryFailed, .recoveryRetryRequested, .operationFinished:
            return true
        }
    }

    static func makeStale(
        event: VoiceKernelEvent,
        currentGeneration: VoiceOperationGeneration?,
        observedAt: Date
    ) -> VoiceKernelEvent {
        let staleGeneration = staleGeneration(relativeTo: currentGeneration)
        switch event {
        case let .startSucceeded(_, session):
            return .startSucceeded(generation: staleGeneration, session: session)
        case let .startFailed(_, error):
            return .startFailed(generation: staleGeneration, error: error)
        case let .livenessObserved(_, session, observation):
            var staleObservation = observation
            staleObservation.observedAt = observedAt
            return .livenessObserved(generation: staleGeneration, session: session, observation: staleObservation)
        case let .routeChanged(_, observation, _):
            return .routeChanged(generation: staleGeneration, observation: observation, observedAt: observedAt)
        case .configurationChanged:
            return .configurationChanged(generation: staleGeneration, observedAt: observedAt)
        case let .unexpectedRecorderStop(_, reason, _):
            return .unexpectedRecorderStop(generation: staleGeneration, reason: reason, observedAt: observedAt)
        case let .segmentSealed(_, session):
            return .segmentSealed(generation: staleGeneration, session: session)
        case let .segmentSealFailed(_, reason, error):
            return .segmentSealFailed(generation: staleGeneration, reason: reason, error: error)
        case let .recoverySucceeded(_, session):
            return .recoverySucceeded(generation: staleGeneration, session: session)
        case let .recoveryBlocked(_, reason, retryClass, error):
            return .recoveryBlocked(generation: staleGeneration, reason: reason, retryClass: retryClass, error: error)
        case let .recoveryFailed(_, reason, error):
            return .recoveryFailed(generation: staleGeneration, reason: reason, error: error)
        case .recoveryRetryRequested:
            return .recoveryRetryRequested(generation: staleGeneration)
        case let .operationFinished(_, result, resultingSession):
            return .operationFinished(generation: staleGeneration, result: result, resultingSession: resultingSession)
        case .toggleRequested, .recoveryScanRequested, .recoveryScanCompleted, .startPrerequisitesObserved, .interruptionBegan, .blockedClearObserved, .blockedDeadlineObservedExpired, .mediaServicesWereReset:
            return event
        }
    }

    private static func staleGeneration(relativeTo currentGeneration: VoiceOperationGeneration?) -> VoiceOperationGeneration {
        guard let currentGeneration, currentGeneration > 1 else {
            return 0
        }
        return currentGeneration - 1
    }
}

private let recoveryBlockedReason = "NSOSStatusErrorDomain:560557684:session_activation_failed"

private extension JSONEncoder {
    static var voiceDST: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension Bool {
    var negated: Bool { !self }
}

private extension VoiceToggleResult.Action {
    var label: String {
        switch self {
        case .started:
            return "started"
        case .blocked:
            return "blocked"
        case .stopping:
            return "stopping"
        case .finalized:
            return "finalized"
        case .deferred:
            return "deferred"
        case .lost:
            return "lost"
        }
    }

    var captureID: String {
        switch self {
        case let .started(captureID),
             let .blocked(captureID),
             let .stopping(captureID),
             let .finalized(captureID),
             let .deferred(captureID),
             let .lost(captureID):
            return captureID
        }
    }

    var isTerminalOrDeferredStopResult: Bool {
        switch self {
        case .finalized, .deferred, .lost:
            return true
        case .started, .blocked, .stopping:
            return false
        }
    }
}
