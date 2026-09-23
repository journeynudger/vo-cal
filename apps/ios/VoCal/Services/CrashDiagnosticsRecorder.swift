import Foundation
import MetricKit
import VoCalCapture

/// The phone writes its own crash reports where a later session can read them.
///
/// Requirement (restructure Phase 3.1, F10): a crash in the field arrived as words in a
/// message and nothing else; App Store Connect's reports lag and never reach an agent.
/// MetricKit hands the app its crash, hang and disk-write-exception diagnostics on the next
/// launch after they happen; this subscriber writes each payload's JSON into a bounded ring
/// under the app group (`vocal/local/diagnostics/`, DiagnosticsRing keeps the newest 20).
/// Settings > About offers the files through the share sheet when any exist, so Lorenzo can
/// send a report from the device in two taps. Off the capture path: registration happens
/// after the shell is up, and MetricKit delivers on its own queue.
/// Payloads carry call stacks and OS versions, never user content (MUST-NOT #5 holds).
///
/// No shared mutable state: the ring is derived from the app group root wherever it is
/// needed, so MetricKit's delivery (nonisolated, its own queue) and the main actor never
/// meet, and the class needs no lock and no `@unchecked Sendable` (TIDY-CONC-003).
@MainActor
final class CrashDiagnosticsRecorder: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnosticsRecorder()

    private var started = false

    /// Subscribe. Idempotent; safe to call late.
    func start() {
        guard !started else { return }
        MXMetricManager.shared.add(self)
        started = true
    }

    /// The reports on disk, newest first; empty when nothing has crashed.
    func entries() -> [URL] {
        (try? Self.ring()?.entries()) ?? []
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let ring = Self.ring() else { return }
        for payload in payloads {
            let kind = payload.crashDiagnostics?.isEmpty == false ? "crash"
                : payload.hangDiagnostics?.isEmpty == false ? "hang"
                : "diagnostic"
            _ = try? ring.write(payload.jsonRepresentation(), name: kind)
        }
    }

    // Metric payloads (battery, launch times) are not kept: they are large, daily, and
    // nothing here reads them.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {}

    private nonisolated static func ring(fileManager: FileManager = .default) -> DiagnosticsRing? {
        guard let root = try? AppGroupConfig.sharedContainerURL(fileManager: fileManager, bundle: .main) else { return nil }
        return DiagnosticsRing(directory: VoCalCapturePaths.diagnosticsRoot(appGroupRoot: root))
    }
}
