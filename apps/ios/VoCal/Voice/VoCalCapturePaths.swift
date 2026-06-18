import Foundation

// Port provenance: Serein apps/ios/Shared/Sources/CaptureRelayPaths.swift.
// Renames: CaptureRelayPaths → VoCalCapturePaths; app-group layout
// serein/local/capture_relay/... → vocal/local/capture/...; VaultLayout dependency
// inlined (Vo-Cal has no iCloud vault — the app-group container is the only local root).
// Seam cut: the `inspection` folder and snapshot-path helpers are not ported.
// Requirement: Vo-Cal P0 carries no visual-inspection harness (foreground-only capture
// is the protected scope). Failure mode avoided: dead directories and helpers that imply
// a screenshot pipeline which does not exist, misleading future agents into wiring one
// onto the capture path. Evidence: Vo-Cal AGENTS.md MUST NOT rules / capture-path
// isolation; Serein's inspection harness lived in InspectionModel, which is not ported.

struct VoCalCaptureDirectoryLayout: Sendable {
    let root: URL
    let blobsRoot: URL
    let requestsRoot: URL
    let voiceSessionsRoot: URL
    let voiceSessionsActiveRoot: URL
    let voiceSessionsQuarantineRoot: URL
    let debugLogURL: URL
    let observabilityLogURL: URL
    let observabilityArchiveLogURL: URL
}

enum VoCalCapturePaths {
    static let appFolder = "vocal"
    static let localFolder = "local"
    static let rootFolder = "capture"
    static let blobsFolder = "blobs"
    static let requestsFolder = "requests"
    static let voiceSessionsFolder = "voice_sessions"
    static let activeFolder = "active"
    static let quarantineFolder = "quarantine"
    static let debugLogFilename = "debug-events.jsonl"
    static let observabilityLogFilename = "observability.jsonl"
    static let observabilityArchiveLogFilename = "observability.1.jsonl"

    static func appRoot(appGroupRoot: URL) -> URL {
        appGroupRoot.appendingPathComponent(appFolder, isDirectory: true)
    }

    static func localRoot(appGroupRoot: URL) -> URL {
        appRoot(appGroupRoot: appGroupRoot).appendingPathComponent(localFolder, isDirectory: true)
    }

    static func root(appGroupRoot: URL) -> URL {
        localRoot(appGroupRoot: appGroupRoot)
            .appendingPathComponent(rootFolder, isDirectory: true)
    }

    static func blobsRoot(appGroupRoot: URL) -> URL {
        root(appGroupRoot: appGroupRoot).appendingPathComponent(blobsFolder, isDirectory: true)
    }

    static func requestsRoot(appGroupRoot: URL) -> URL {
        root(appGroupRoot: appGroupRoot).appendingPathComponent(requestsFolder, isDirectory: true)
    }

    static func voiceSessionsRoot(appGroupRoot: URL) -> URL {
        root(appGroupRoot: appGroupRoot).appendingPathComponent(voiceSessionsFolder, isDirectory: true)
    }

    static func voiceSessionsActiveRoot(appGroupRoot: URL) -> URL {
        voiceSessionsRoot(appGroupRoot: appGroupRoot).appendingPathComponent(activeFolder, isDirectory: true)
    }

    static func voiceSessionsQuarantineRoot(appGroupRoot: URL) -> URL {
        voiceSessionsRoot(appGroupRoot: appGroupRoot).appendingPathComponent(quarantineFolder, isDirectory: true)
    }

    static func debugLogURL(appGroupRoot: URL) -> URL {
        root(appGroupRoot: appGroupRoot).appendingPathComponent(debugLogFilename, isDirectory: false)
    }

    static func observabilityLogURL(appGroupRoot: URL) -> URL {
        root(appGroupRoot: appGroupRoot).appendingPathComponent(observabilityLogFilename, isDirectory: false)
    }

    static func observabilityArchiveLogURL(appGroupRoot: URL) -> URL {
        root(appGroupRoot: appGroupRoot).appendingPathComponent(observabilityArchiveLogFilename, isDirectory: false)
    }

    static func ensureInitialized(
        appGroupRoot: URL,
        fileManager: FileManager = .default
    ) throws -> VoCalCaptureDirectoryLayout {
        let rootURL = root(appGroupRoot: appGroupRoot)
        let blobsURL = blobsRoot(appGroupRoot: appGroupRoot)
        let requestsURL = requestsRoot(appGroupRoot: appGroupRoot)
        let voiceSessionsURL = voiceSessionsRoot(appGroupRoot: appGroupRoot)
        let voiceSessionsActiveURL = voiceSessionsActiveRoot(appGroupRoot: appGroupRoot)
        let voiceSessionsQuarantineURL = voiceSessionsQuarantineRoot(appGroupRoot: appGroupRoot)
        let debugLogURL = debugLogURL(appGroupRoot: appGroupRoot)
        let observabilityLogURL = observabilityLogURL(appGroupRoot: appGroupRoot)
        let observabilityArchiveLogURL = observabilityArchiveLogURL(appGroupRoot: appGroupRoot)
        let directories = [
            appRoot(appGroupRoot: appGroupRoot),
            localRoot(appGroupRoot: appGroupRoot),
            rootURL,
            blobsURL,
            requestsURL,
            voiceSessionsURL,
            voiceSessionsActiveURL,
            voiceSessionsQuarantineURL,
        ]
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return VoCalCaptureDirectoryLayout(
            root: rootURL,
            blobsRoot: blobsURL,
            requestsRoot: requestsURL,
            voiceSessionsRoot: voiceSessionsURL,
            voiceSessionsActiveRoot: voiceSessionsActiveURL,
            voiceSessionsQuarantineRoot: voiceSessionsQuarantineURL,
            debugLogURL: debugLogURL,
            observabilityLogURL: observabilityLogURL,
            observabilityArchiveLogURL: observabilityArchiveLogURL
        )
    }
}
