import Foundation
import VoCalCapture

// Port provenance: Serein apps/ios/Shared/Sources/CaptureRelayObservability.swift,
// verbatim with CaptureRelay* → Capture* renames and VoCalCapturePaths layout.
// observability.jsonl is a bounded, lossy, off-the-hot-path telemetry artifact for
// retrospective latency analysis — never a source of truth for user-facing claims
// (docs/VOICE_CAPTURE.md, Startup Observability). No seams were cut in this file.

actor CaptureObservabilityRelaySink: ObservabilitySink {
    private let maxBufferedRecords: Int
    private var downstream: (any ObservabilitySink)?
    private var bufferedRecords: [ObservabilityRecord] = []

    init(maxBufferedRecords: Int = 256) {
        self.maxBufferedRecords = maxBufferedRecords
    }

    func record(_ record: ObservabilityRecord) async throws {
        if let downstream {
            try await downstream.record(record)
            return
        }
        if bufferedRecords.count >= maxBufferedRecords {
            bufferedRecords.removeFirst()
        }
        bufferedRecords.append(record)
    }

    func installDownstream(_ downstream: any ObservabilitySink) async {
        self.downstream = downstream
        let pending = bufferedRecords
        bufferedRecords.removeAll(keepingCapacity: true)
        for record in pending {
            try? await downstream.record(record)
        }
    }
}

actor CaptureObservabilityFileSink: ObservabilitySink {
    static let defaultMaxSegmentBytes = 1_048_576
    static let defaultFlushThresholdBytes = 8_192
    static let defaultFlushInterval: Duration = .milliseconds(250)

    private let currentURL: URL
    private let archiveURL: URL
    private let fileManager: FileManager
    private let maxSegmentBytes: Int
    private let flushThresholdBytes: Int
    private let flushInterval: Duration
    private let encoder = JSONEncoder()

    private var pendingLines: [Data] = []
    private var pendingBytes = 0
    private var flushTask: Task<Void, Never>?

    init(
        appGroupRoot: URL,
        fileManager: FileManager = .default,
        maxSegmentBytes: Int = defaultMaxSegmentBytes,
        flushThresholdBytes: Int = defaultFlushThresholdBytes,
        flushInterval: Duration = defaultFlushInterval
    ) throws {
        let layout = try VoCalCapturePaths.ensureInitialized(appGroupRoot: appGroupRoot, fileManager: fileManager)
        self.currentURL = layout.observabilityLogURL
        self.archiveURL = layout.observabilityArchiveLogURL
        self.fileManager = fileManager
        self.maxSegmentBytes = maxSegmentBytes
        self.flushThresholdBytes = flushThresholdBytes
        self.flushInterval = flushInterval
        encoder.outputFormatting = [.sortedKeys]
    }

    func record(_ record: ObservabilityRecord) async throws {
        pendingLines.append(try encodedLine(for: record))
        pendingBytes += pendingLines.last?.count ?? 0
        if flushInterval == .zero || pendingBytes >= flushThresholdBytes {
            flushTask?.cancel()
            flushTask = nil
            try flushPending()
        } else {
            scheduleFlushIfNeeded()
        }
    }

    func flushForTesting() throws {
        flushTask?.cancel()
        flushTask = nil
        try flushPending()
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else {
            return
        }
        let interval = flushInterval
        flushTask = Task { [interval] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await self.flushScheduled()
        }
    }

    private func flushScheduled() async {
        flushTask = nil
        do {
            try flushPending()
        } catch {
            fputs("observability flush failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func flushPending() throws {
        guard pendingBytes > 0 else {
            return
        }
        let chunk = pendingLines.reduce(into: Data()) { partial, line in
            partial.append(line)
        }
        pendingLines.removeAll(keepingCapacity: true)
        pendingBytes = 0

        try ensureFileExists(at: currentURL)
        try rotateIfNeeded(appending: chunk.count)
        let handle = try FileHandle(forWritingTo: currentURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: chunk)
    }

    private func rotateIfNeeded(appending byteCount: Int) throws {
        let currentSize = try fileSize(at: currentURL)
        guard currentSize > 0, currentSize + byteCount > maxSegmentBytes else {
            return
        }
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        try fileManager.moveItem(at: currentURL, to: archiveURL)
        fileManager.createFile(atPath: currentURL.path, contents: nil)
    }

    private func ensureFileExists(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            fileManager.createFile(atPath: url.path, contents: nil)
        }
    }

    private func fileSize(at url: URL) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func encodedLine(for record: ObservabilityRecord) throws -> Data {
        var line = try encoder.encode(record)
        line.append(contentsOf: "\n".utf8)
        return line
    }
}

actor CaptureObservability {
    static let shared = CaptureObservability()

    private let relaySink = CaptureObservabilityRelaySink()
    nonisolated let client: ObservabilityClient
    private var configuredRootPath: String?

    init() {
        client = ObservabilityClient(sinks: [relaySink])
    }

    func configureIfNeeded(
        appGroupRoot: URL
    ) async {
        guard configuredRootPath != appGroupRoot.path else {
            return
        }
        do {
            let sink = try CaptureObservabilityFileSink(
                appGroupRoot: appGroupRoot
            )
            await relaySink.installDownstream(sink)
            configuredRootPath = appGroupRoot.path
        } catch {
            client.diagnostic(
                .error,
                name: "observability.configure_failed",
                message: error.localizedDescription,
                attributes: ["app_group_root": .string(appGroupRoot.path)]
            )
        }
    }
}
