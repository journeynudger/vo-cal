import Foundation

public actor CaptureOutboxMonitor {
    public typealias ChangeHandler = @MainActor @Sendable (String) -> Void

    private struct Signature: Equatable {
        let exists: Bool
        let size: UInt64
        let modifiedAt: TimeInterval
    }

    private let databaseURL: URL
    private let extraMonitoredURLs: [URL]
    private let handler: ChangeHandler
    private let pollInterval: Duration

    private var lastSnapshot: [String: Signature] = [:]
    private var monitorTask: Task<Void, Never>?

    public init(
        databaseURL: URL,
        extraMonitoredURLs: [URL] = [],
        pollInterval: Duration = .milliseconds(250),
        handler: @escaping ChangeHandler
    ) {
        self.databaseURL = databaseURL
        self.extraMonitoredURLs = extraMonitoredURLs
        self.pollInterval = pollInterval
        self.handler = handler
    }

    public func start() {
        guard monitorTask == nil else {
            return
        }
        lastSnapshot = captureSnapshot()
        monitorTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private var monitoredURLs: [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            databaseURL.deletingLastPathComponent(),
        ] + extraMonitoredURLs
    }

    private func runLoop() async {
        repeat {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else {
                return
            }
            let snapshot = captureSnapshot()
            guard snapshot != lastSnapshot else {
                continue
            }
            lastSnapshot = snapshot
            await handler("signature_poll")
        } while !Task.isCancelled
    }

    private func captureSnapshot() -> [String: Signature] {
        var snapshot: [String: Signature] = [:]
        for url in monitoredURLs {
            snapshot[url.path] = signature(for: url)
        }
        return snapshot
    }

    private func signature(for url: URL) -> Signature {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        else {
            return Signature(exists: false, size: 0, modifiedAt: 0)
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Signature(exists: true, size: size, modifiedAt: modifiedAt)
    }
}
