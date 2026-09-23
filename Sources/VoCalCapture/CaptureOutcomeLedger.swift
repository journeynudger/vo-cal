import Foundation

/// What happened to a capture after it was saved: logged into a meal, or dismissed.
public struct CaptureOutcome: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case logged
        case dismissed
    }

    public let captureID: String
    public let kind: Kind
    public let at: Date
    /// The meal the capture was logged into (`logged` only).
    public let mealID: String?
    /// Why it was dismissed (`dismissed` only): "user", "empty_transcript".
    public let reason: String?

    public init(captureID: String, kind: Kind, at: Date, mealID: String? = nil, reason: String? = nil) {
        self.captureID = captureID
        self.kind = kind
        self.at = at
        self.mealID = mealID
        self.reason = reason
    }
}

/// An append-only ledger of capture outcomes, one JSON record per line, the last record for
/// a capture winning. The outbox answers "what was recorded"; this answers "what happened
/// next", so a recording that never reached "logged" can be found again (restructure R8).
///
/// Append-only because a discard is a mark, never a deletion (INVARIANTS section 1), and
/// because a one-line append survives a crash mid-write as a torn last line that is skipped
/// on read, not a corrupt file. Bounded (section 8): past `compactAboveBytes` the file is
/// rewritten with the newest `keepNewest` records, which is more than the outbox scan that
/// reads it back ever covers.
public struct CaptureOutcomeLedger: Sendable {
    public static let filename = "outcomes.jsonl"

    public let fileURL: URL
    public let compactAboveBytes: Int
    public let keepNewest: Int

    public init(directory: URL, compactAboveBytes: Int = 512 * 1024, keepNewest: Int = 2_000) {
        self.fileURL = directory.appendingPathComponent(Self.filename, isDirectory: false)
        self.compactAboveBytes = max(1, compactAboveBytes)
        self.keepNewest = max(1, keepNewest)
    }

    public func append(_ outcome: CaptureOutcome, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try Self.encoder.encode(outcome)
        line.append(0x0A)
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forUpdating: fileURL)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            // A torn tail (a crash mid-append) has no newline: close it first, or the next
            // record would be glued onto it and lost with it.
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let last = try handle.read(upToCount: 1) ?? Data()
                if last.first != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
            }
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
        try compactIfNeeded(fileManager: fileManager)
    }

    /// Every readable record in file order. A line that does not decode (a torn tail after
    /// a crash) is skipped.
    public func records(fileManager: FileManager = .default) throws -> [CaptureOutcome] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { line in
            try? Self.decoder.decode(CaptureOutcome.self, from: line)
        }
    }

    /// The latest outcome per capture.
    public func outcomes(fileManager: FileManager = .default) throws -> [String: CaptureOutcome] {
        var latest: [String: CaptureOutcome] = [:]
        for record in try records(fileManager: fileManager) {
            latest[record.captureID] = record
        }
        return latest
    }

    private func compactIfNeeded(fileManager: FileManager) throws {
        let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard size > compactAboveBytes else { return }
        var data = Data()
        for record in try records(fileManager: fileManager).suffix(keepNewest) {
            data.append(try Self.encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
