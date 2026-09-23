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
/// after the shell is up, at utility priority, and MetricKit delivers on its own queue.
/// Payloads carry call stacks and OS versions, never user content (MUST-NOT #5 holds).
final class CrashDiagnosticsRecorder: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashDiagnosticsRecorder()

    private let lock = NSLock()
    private var ring: DiagnosticsRing?
    private var started = false

    /// Resolve the ring's directory and subscribe. Idempotent; safe to call late.
    func start(fileManager: FileManager = .default) {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        guard let root = try? AppGroupConfig.sharedContainerURL(fileManager: fileManager, bundle: .main) else { return }
        ring = DiagnosticsRing(directory: VoCalCapturePaths.diagnosticsRoot(appGroupRoot: root))
        MXMetricManager.shared.add(self)
        started = true
    }

    /// The reports on disk, newest first; empty when nothing has crashed.
    func entries() -> [URL] {
        lock.lock()
        let ring = self.ring
        lock.unlock()
        return (try? ring?.entries()) ?? []
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        lock.lock()
        let ring = self.ring
        lock.unlock()
        guard let ring else { return }
        for payload in payloads {
            let kind = payload.crashDiagnostics?.isEmpty == false ? "crash"
                : payload.hangDiagnostics?.isEmpty == false ? "hang"
                : "diagnostic"
            _ = try? ring.write(payload.jsonRepresentation(), name: kind)
        }
    }

    // Metric payloads (battery, launch times) are not kept: they are large, daily, and
    // nothing here reads them.
    func didReceive(_ payloads: [MXMetricPayload]) {}
}
