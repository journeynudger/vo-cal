import Foundation
import Testing
@testable import VoCalCapture

private actor RecordingObservabilitySink: ObservabilitySink {
    private var records: [ObservabilityRecord] = []
    private let shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func record(_ record: ObservabilityRecord) async throws {
        if shouldThrow {
            throw TestError.synthetic
        }
        records.append(record)
    }

    func snapshot() -> [ObservabilityRecord] {
        records
    }
}

private enum TestError: Error {
    case synthetic
}

@Test("Observability scalar values round-trip through JSON")
func observabilityScalarsRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()

    let record = ObservabilityRecord(
        kind: .measurement,
        timestamp: "2026-03-30T12:00:00Z",
        name: "capture.refresh_telemetry_ms",
        unit: .milliseconds,
        value: .integer(42),
        attributes: [
            "execution_mode": .string("background_voice_intent"),
            "cold_start": .bool(true),
            "segment_count": .integer(3),
            "mean": .double(12.5),
        ]
    )

    let encoded = try encoder.encode(record)
    let decoded = try decoder.decode(ObservabilityRecord.self, from: encoded)

    #expect(decoded == record)
}

@Test("Observability milestones use monotonic elapsed timing")
func observabilityMilestonesUseMonotonicElapsedTiming() async throws {
    let sink = RecordingObservabilitySink()
    let client = ObservabilityClient(sinks: [sink])
    let handle = await client.beginOperation(
        name: "voice_startup",
        operationID: "voice-op",
        attributes: ["run_id": .string("run-monotonic")]
    )

    handle.milestone("accepted")
    try await Task.sleep(for: .milliseconds(20))
    handle.milestone("confirmed_listening")

    let records = try await waitForRecords(in: sink, count: 2)
        .sorted { ($0.elapsedMS ?? 0) < ($1.elapsedMS ?? 0) }

    #expect(records.compactMap(\.milestone) == ["accepted", "confirmed_listening"])
    #expect((records[0].elapsedMS ?? -1) >= 0)
    #expect((records[1].elapsedMS ?? -1) >= (records[0].elapsedMS ?? -1))
    #expect(records.allSatisfy { $0.attributes["run_id"] == .string("run-monotonic") })
    #expect(records.allSatisfy { $0.attributes["operation_started_at"] != nil })
}

@Test("Observability sink fan-out isolates failures")
func observabilitySinkFanOutIsolatesFailures() async throws {
    let goodSink = RecordingObservabilitySink()
    let failingSink = RecordingObservabilitySink(shouldThrow: true)
    let client = ObservabilityClient(sinks: [failingSink, goodSink])

    client.diagnostic(
        .warning,
        name: "observability.configure_failed",
        message: "synthetic failure",
        attributes: ["app_group_root": .string("/tmp/vocal")]
    )
    client.measurement(
        name: "app.did_finish_launch_ms",
        value: 12,
        unit: .milliseconds,
        attributes: ["cold_start": .bool(true)]
    )

    let records = try await waitForRecords(in: goodSink, count: 2)

    #expect(records.count == 2)
    #expect(records.map(\.kind) == [.diagnostic, .measurement])
    #expect(records[0].attributes["app_group_root"] == .string("/tmp/vocal"))
    #expect(records[1].value == .integer(12))
}

private func waitForRecords(
    in sink: RecordingObservabilitySink,
    count: Int,
    timeout: Duration = .seconds(1)
) async throws -> [ObservabilityRecord] {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        let records = await sink.snapshot()
        if records.count >= count {
            return records
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestError.synthetic
}
