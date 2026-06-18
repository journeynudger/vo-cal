import Foundation
import OSLog
import VoCalCapture

// Port provenance: Serein apps/ios/Shared/Sources/CaptureRelayDebugRecorder.swift.
// Renames: CaptureRelayDebugRecorder/Level/Event → CaptureDebug*; subsystem
// com.serein.app → com.vocal.app; category CaptureRelay → Capture; paths via
// VoCalCapturePaths. Behavior is otherwise verbatim: debug-events.jsonl is the
// best-effort runtime log and UI-synchronization channel (docs/VOICE_CAPTURE.md).

enum CaptureDebugLevel: String, Codable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
}

struct CaptureDebugEvent: Codable, Sendable {
    let timestamp: String
    let level: CaptureDebugLevel
    let subsystem: String
    let category: String
    let name: String
    let message: String
    let metadata: [String: String]
}

actor CaptureDebugRecorder {
    static let shared = CaptureDebugRecorder()

    private let subsystem = "com.vocal.app"
    private let category = "Capture"
    private let logger = Logger(subsystem: "com.vocal.app", category: "Capture")
    private let encoder = JSONEncoder()
    private var logFileURL: URL?
    private var fileManager: FileManager = .default

    init() {
        encoder.outputFormatting = [.sortedKeys]
    }

    nonisolated func emit(
        _ level: CaptureDebugLevel = .info,
        name: String,
        message: String,
        metadata: [String: String] = [:],
        appGroupRoot: URL? = nil
    ) {
        Task {
            await record(
                level,
                name: name,
                message: message,
                metadata: metadata,
                appGroupRoot: appGroupRoot
            )
        }
    }

    nonisolated static func appendDirect(
        _ level: CaptureDebugLevel = .info,
        name: String,
        message: String,
        metadata: [String: String] = [:],
        appGroupRoot: URL,
        fileManager: FileManager = .default
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let event = CaptureDebugEvent(
            timestamp: CaptureDateCodec.internetString(Date()),
            level: level,
            subsystem: "com.vocal.app",
            category: "Capture",
            name: name,
            message: message,
            metadata: metadata
        )
        guard let layout = try? VoCalCapturePaths.ensureInitialized(appGroupRoot: appGroupRoot, fileManager: fileManager),
              let data = try? encoder.encode(event)
        else {
            return
        }
        let logFileURL = layout.debugLogURL
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        } catch {
            fputs("{\"level\":\"error\",\"name\":\"debug_log.persist_failed\",\"message\":\"\(error.localizedDescription)\"}\n", stderr)
        }
    }

    func configure(
        appGroupRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let layout = try VoCalCapturePaths.ensureInitialized(
            appGroupRoot: appGroupRoot,
            fileManager: fileManager
        )
        logFileURL = layout.debugLogURL
        if !fileManager.fileExists(atPath: layout.debugLogURL.path) {
            fileManager.createFile(atPath: layout.debugLogURL.path, contents: nil)
        }
    }

    func resetLog(appGroupRoot: URL) throws {
        try configure(appGroupRoot: appGroupRoot, fileManager: fileManager)
        guard let logFileURL else {
            return
        }
        if fileManager.fileExists(atPath: logFileURL.path) {
            try Data().write(to: logFileURL, options: .atomic)
        }
    }

    private func record(
        _ level: CaptureDebugLevel,
        name: String,
        message: String,
        metadata: [String: String],
        appGroupRoot: URL?
    ) async {
        if logFileURL == nil, let appGroupRoot {
            try? configure(appGroupRoot: appGroupRoot, fileManager: fileManager)
        }

        let event = CaptureDebugEvent(
            timestamp: CaptureDateCodec.internetString(Date()),
            level: level,
            subsystem: subsystem,
            category: category,
            name: name,
            message: message,
            metadata: metadata
        )
        let line = (try? encodedLine(for: event)) ?? fallbackLine(for: event)

        switch level {
        case .debug:
            logger.debug("\(line, privacy: .public)")
        case .info:
            logger.info("\(line, privacy: .public)")
        case .notice:
            logger.notice("\(line, privacy: .public)")
        case .warning:
            logger.warning("\(line, privacy: .public)")
        case .error:
            logger.error("\(line, privacy: .public)")
        }
        fputs("\(line)\n", stderr)

        guard let logFileURL else {
            return
        }
        do {
            if !fileManager.fileExists(atPath: logFileURL.path) {
                fileManager.createFile(atPath: logFileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            logger.error("failed to persist capture debug event: \(error.localizedDescription, privacy: .public)")
            fputs("{\"level\":\"error\",\"name\":\"debug_log.persist_failed\",\"message\":\"\(error.localizedDescription)\"}\n", stderr)
        }
    }

    private func encodedLine(for event: CaptureDebugEvent) throws -> String {
        let data = try encoder.encode(event)
        return String(decoding: data, as: UTF8.self)
    }

    private func fallbackLine(for event: CaptureDebugEvent) -> String {
        let metadata = event.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return #"{"timestamp":"\#(event.timestamp)","level":"\#(event.level.rawValue)","name":"\#(event.name)","message":"\#(event.message)","metadata":"\#(metadata)"}"#
    }
}
