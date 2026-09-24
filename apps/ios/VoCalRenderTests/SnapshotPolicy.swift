import SnapshotTesting
import UIKit
import XCTest

/// Rule 4 of docs/UI_VERIFICATION.md, in code: goldens are read-only. The record mode is
/// `.never` unless the process carries RECORD_SNAPSHOTS=1 (passed through xcodebuild as
/// TEST_RUNNER_RECORD_SNAPSHOTS=1), so a golden can only change on purpose, from a command
/// that says so. A missing golden fails the test rather than silently recording one.
class SnapshotPolicyTestCase: XCTestCase {
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
    }

    /// The fraction of pixels that must stay within the perceptual threshold, and that
    /// threshold. Measured 2026-09-24 (docs/UI_VERIFICATION.md, "Noise floor"): the result
    /// screen rendered twice differs in 480 to 709 pixels (0.01 percent) of its Liquid Glass
    /// close button, by a few levels, so identity (`precision: 1`) failed both result goldens
    /// in three verify runs of three. A 4 pt shift, a truncated label or a zeroed number moves
    /// tens of thousands of pixels by far more than the threshold (the proof in the same doc).
    static let precision: Float = 0.999
    static let perceptualPrecision: Float = 0.98

    override func invokeTest() {
        if Self.isRecording { GoldenRuntime.record() }
        withSnapshotTesting(record: Self.isRecording ? .all : .never) {
            super.invokeTest()
        }
    }
}

/// Goldens are only meaningful on the iOS runtime that drew them: glyph rasterization and
/// SwiftUI layout metrics move between iOS releases, and a golden compared on another runtime
/// fails for the wrong reason or, worse, passes for one. Recording writes the runtime next to
/// the goldens; verifying on any other runtime skips the golden assertions out loud (the CI
/// runner carries a different Xcode than the pinned simulator) while every non-golden test
/// still runs.
enum GoldenRuntime {
    static var file: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__/RUNTIME.txt")
    }

    static var current: String {
        "iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.name) · \(Int(RenderHarness.scale))x"
    }

    static func record() {
        try? current.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Nil when this runtime is the one the goldens were recorded on (or none are recorded
    /// yet, in which case the missing golden fails on its own); otherwise the reason to skip.
    static func mismatch() -> String? {
        guard let recorded = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = recorded.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordedVersion = trimmed.components(separatedBy: " · ").first ?? trimmed
        let currentVersion = "iOS \(UIDevice.current.systemVersion)"
        return recordedVersion == currentVersion ? nil : "goldens were recorded on \(trimmed); this runtime is \(current)"
    }
}
