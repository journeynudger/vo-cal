import Foundation
import Testing
@testable import VoCalCapture

@Suite("CaptureOutcomeLedger")
struct CaptureOutcomeLedgerTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("outcome-ledger-\(UUID().uuidString)", isDirectory: true)
    }

    private func outcome(_ id: String, _ kind: CaptureOutcome.Kind, at seconds: TimeInterval = 0, mealID: String? = nil, reason: String? = nil) -> CaptureOutcome {
        CaptureOutcome(captureID: id, kind: kind, at: Date(timeIntervalSince1970: 1_700_000_000 + seconds), mealID: mealID, reason: reason)
    }

    @Test("The last record for a capture wins")
    func lastRecordWins() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = CaptureOutcomeLedger(directory: directory)
        try ledger.append(outcome("a", .dismissed, at: 1, reason: "empty_transcript"))
        try ledger.append(outcome("b", .logged, at: 2, mealID: "meal-1"))
        try ledger.append(outcome("a", .logged, at: 3, mealID: "meal-2"))
        let outcomes = try ledger.outcomes()
        #expect(outcomes.count == 2)
        #expect(outcomes["a"] == outcome("a", .logged, at: 3, mealID: "meal-2"))
        #expect(outcomes["b"] == outcome("b", .logged, at: 2, mealID: "meal-1"))
    }

    // INCIDENT class: a crash mid-append leaves a torn last line; the ledger must still read
    // every whole record and accept the next append.
    @Test("A torn tail line is skipped, not fatal")
    func tornTailIsSkipped() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = CaptureOutcomeLedger(directory: directory)
        try ledger.append(outcome("a", .logged, mealID: "meal-1"))
        let handle = try FileHandle(forWritingTo: ledger.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"captureID\":\"b\",\"kin".utf8))
        try handle.close()
        #expect(try ledger.records().map(\.captureID) == ["a"])
        try ledger.append(outcome("c", .dismissed, reason: "user"))
        #expect(try ledger.records().map(\.captureID) == ["a", "c"])
    }

    @Test("Past the byte threshold the ledger keeps only the newest records")
    func compactionIsBounded() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = CaptureOutcomeLedger(directory: directory, compactAboveBytes: 400, keepNewest: 3)
        for index in 0..<8 {
            try ledger.append(outcome("capture-\(index)", .logged, at: TimeInterval(index), mealID: "meal-\(index)"))
        }
        let ids = try ledger.records().map(\.captureID)
        #expect(ids.count <= 4)
        #expect(ids.last == "capture-7")
        #expect(!ids.contains("capture-0"))
    }

    @Test("A missing ledger is simply empty")
    func missingLedger() throws {
        let ledger = CaptureOutcomeLedger(directory: temporaryDirectory())
        #expect(try ledger.outcomes().isEmpty)
    }
}
