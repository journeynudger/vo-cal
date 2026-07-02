import Foundation
import SwiftUI
import VoCalCapture

// Port provenance: Serein apps/ios/SereinApp/Sources/AppRuntimeCoordinator.swift,
// trimmed to Vo-Cal's foreground-only P0.
//
// Seam cuts (all three share the same shape — requirement, failure mode, evidence):
// - `backgroundVoiceIntent` entry mode + `captureIntentBegan` lifecycle event:
//   Requirement: Vo-Cal P0 capture is foreground-only — no AppIntents / Action Button
//   path is ported, so no background intent can ever claim a lane. Failure mode
//   avoided: dead entry modes invite an agent to "finish" the intent path, which on
//   cold background starts loses the intent execution context and ActivityKit rejects
//   the required Live Activity with target_is_not_foreground. Evidence: Vo-Cal
//   AGENTS.md (foreground-only master decision); Serein AGENTS.md (April 2026
//   authorization-window incident); https://developer.apple.com/forums/thread/815725
// - `locationRelaunch` / `locationBackgroundURLSession` entry modes and the location
//   lane: Requirement: Vo-Cal has no passive-location subsystem. Failure mode avoided:
//   a location lane with no runtime behind it — capture paths must not depend on or
//   wake subsystems serving a different concern. Evidence: Vo-Cal AGENTS.md
//   capture-path isolation; phase plan C1 ("no passive location").
// - `NetworkStatusMonitor` reachability + `withBackgroundAssertion`: consumed only by
//   Serein's relay upload runtime, which lands in task C4. Reintroduce them with the
//   upload worker, not before — eager transport services on launch are exactly the
//   coupling that consumed Serein's voice authorization window (Serein AGENTS.md,
//   April 2026).

enum AppEntryMode: String, Sendable {
    case foregroundScene = "foreground_scene"
    case selfTest = "self_test"
    case inspection = "inspection"
}

enum RuntimeLane: String, Hashable, Sendable {
    case voiceCapture = "voice_capture"
    case captureTransport = "capture_transport"
    case foregroundShell = "foreground_shell"
    case inspection = "inspection"
}

enum AppScenePhaseValue: String, Sendable {
    case active
    case inactive
    case background

    init(_ phase: ScenePhase) {
        switch phase {
        case .active:
            self = .active
        case .background:
            self = .background
        case .inactive:
            self = .inactive
        @unknown default:
            self = .inactive
        }
    }
}

enum AppLifecycleEvent: Sendable {
    case appLaunch(reason: String)
    case scenePhaseChanged(AppScenePhaseValue)
}

@MainActor
final class AppRuntimeCoordinator {
    static let shared = AppRuntimeCoordinator()

    private var foregroundSceneObserved = false
    private var firstVoiceRequestObserved = false

    private(set) var entryModes: Set<AppEntryMode> = []
    private(set) var lanes: Set<RuntimeLane> = []

    @discardableResult
    func observeLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Set<RuntimeLane> {
        if arguments.contains("--self-test-run-id") {
            claim(.selfTest)
        }
        publish(.appLaunch(reason: "app_launch"))
        return lanes
    }

    @discardableResult
    func claim(_ mode: AppEntryMode) -> Set<RuntimeLane> {
        entryModes.insert(mode)
        lanes.formUnion(Self.lanes(for: mode))
        if mode == .foregroundScene || mode == .inspection {
            foregroundSceneObserved = true
        }
        return lanes
    }

    func hasLane(_ lane: RuntimeLane) -> Bool {
        lanes.contains(lane)
    }

    func shouldRunForegroundShellTasks() -> Bool {
        hasLane(.foregroundShell) || hasLane(.inspection)
    }

    func prepareVoiceStartup(executionMode: ObservabilityExecutionMode) -> (entryMode: AppEntryMode, processCold: Bool) {
        let entryMode = Self.entryMode(for: executionMode)
        let processCold = !foregroundSceneObserved && !firstVoiceRequestObserved
        firstVoiceRequestObserved = true
        claim(entryMode)
        return (entryMode: entryMode, processCold: processCold)
    }

    /// Fold a lifecycle event into runtime state. Currently only the scene-active claim has an
    /// effect; the event is a typed input so new lifecycle reactions land here. (The earlier
    /// AsyncStream broadcast was removed — it had no subscribers.)
    func publish(_ event: AppLifecycleEvent) {
        switch event {
        case let .scenePhaseChanged(phase):
            if phase == .active {
                claim(.foregroundScene)
            }
        case .appLaunch:
            break
        }
    }

    private static func entryMode(for executionMode: ObservabilityExecutionMode) -> AppEntryMode {
        switch executionMode {
        case .foregroundApp:
            return .foregroundScene
        case .inspection:
            return .inspection
        case .selfTest, .unknown:
            return .selfTest
        // The SPM observability vocabulary keeps the background_voice_intent case
        // (port discipline: the enum is shared with the ported kernel and telemetry).
        // No Vo-Cal P0 surface can produce it — if it ever arrives, classify it as a
        // foreground scene rather than inventing a background entry mode that the
        // foreground-only build cannot honor (Vo-Cal AGENTS.md master decision).
        case .backgroundVoiceIntent:
            return .foregroundScene
        }
    }

    private static func lanes(for mode: AppEntryMode) -> Set<RuntimeLane> {
        switch mode {
        case .foregroundScene:
            return [.foregroundShell, .captureTransport]
        case .selfTest:
            return [.captureTransport]
        case .inspection:
            return [.inspection, .foregroundShell]
        }
    }
}
