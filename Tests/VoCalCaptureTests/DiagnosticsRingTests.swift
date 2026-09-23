import Foundation
import Testing
@testable import VoCalCapture

@Suite("DiagnosticsRing")
struct DiagnosticsRingTests {
    // INCIDENT class (Phase 3.1): a device that crashes on every launch must not fill its
    // app group with reports; the ring keeps the newest `keep` and nothing else.
    @Test("The ring keeps only the newest entries, newest first")
    func ringIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-ring-\(UUID().uuidString)", isDirectory: true)
        let ring = DiagnosticsRing(directory: directory, keep: 3)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<5 {
            try ring.write(Data("{\"n\": \(index)}".utf8), name: "crash report/\(index)", at: start.addingTimeInterval(Double(index)))
        }
        let entries = try ring.entries()
        #expect(entries.count == 3)
        #expect(entries.map { String(data: (try? Data(contentsOf: $0)) ?? Data(), encoding: .utf8) } == ["{\"n\": 4}", "{\"n\": 3}", "{\"n\": 2}"])
        #expect(entries.allSatisfy { !$0.lastPathComponent.contains("/") && $0.pathExtension == "json" })
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("An empty or missing directory is simply empty")
    func missingDirectory() throws {
        let ring = DiagnosticsRing(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(try ring.entries().isEmpty)
    }
}
