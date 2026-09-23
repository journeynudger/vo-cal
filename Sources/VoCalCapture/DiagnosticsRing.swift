import Foundation

/// A bounded ring of diagnostic files on disk: the newest `keep` entries survive, the rest
/// are removed as new ones arrive. Crash and hang diagnostics from MetricKit land here
/// (`vocal/local/diagnostics/` in the app group) so a field crash leaves a report the next
/// session can read (restructure Phase 3.1, F10: debugging blind). Foundation only: the
/// platform subscriber that feeds it lives in the app.
public struct DiagnosticsRing: Sendable {
    public let directory: URL
    /// Files kept, newest first. Twenty is a month of daily MetricKit deliveries with room
    /// for a bad week; the bound keeps the app group from growing on a device that crashes
    /// every launch.
    public let keep: Int

    public init(directory: URL, keep: Int = 20) {
        self.directory = directory
        self.keep = max(1, keep)
    }

    /// Writes `data` as `<timestamp>-<name>.json` (name reduced to a safe stem), drops the
    /// oldest entries beyond `keep`, and returns the new file's URL.
    @discardableResult
    public func write(_ data: Data, name: String, at date: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = CaptureDateCodec.captureIDTimestamp(date)
        let stem = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }
        let url = directory.appendingPathComponent("\(stamp)-\(String(stem)).json", isDirectory: false)
        try data.write(to: url, options: .atomic)
        for stale in try entries(fileManager: fileManager).dropFirst(keep) {
            try? fileManager.removeItem(at: stale)
        }
        return url
    }

    /// Every entry in the ring, newest first (by name: the timestamp leads the filename).
    public func entries(fileManager: FileManager = .default) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
