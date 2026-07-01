import Foundation
import SQLite3
import Synchronization
import VoCalCapture

// Port provenance: Serein apps/ios/Shared/Sources/CaptureOutbox.swift, near-verbatim
// with Serein → VoCal renames (module, paths, schema string vocal.capture.v1). The
// outbox records durable capture facts and relay queue state; it owns storage, not
// transport policy — the C4 planner/worker consume it, they do not live in it
// (same storage ≠ same authority, Vo-Cal AGENTS.md). The outbox is touched exactly
// once per voice capture, at finalization: in-progress recording state lives on the
// filesystem session ledger only (INVARIANTS §3).
// Seam cuts: the share-extension inbox watch in observe() (Vo-Cal P0 has no share
// extension / second process — INVARIANTS §5 tombstone) and Serein's
// shortcut_app_intent fallback source label (no intent surface is ported).

// "Saved" requires this receipt. enqueue() returns the durably committed outbox row;
// UI and callers may only project "Saved" from a value of this type, never from
// phase checks or optimistic flags (proofs-not-booleans, Vo-Cal AGENTS.md).
typealias LocalCommitReceipt = LocalCaptureRecord

typealias CaptureLocalState = VoCalCapture.CaptureLocalState
typealias RelayFailureClass = VoCalCapture.RelayFailureClass
typealias RelayJobPriority = VoCalCapture.RelayJobPriority
typealias RelayJobRecord = VoCalCapture.RelayJobRecord
typealias RelayJobState = VoCalCapture.RelayJobState
typealias RelayQueueHealth = VoCalCapture.RelayQueueHealth
typealias RelayWorkerState = VoCalCapture.RelayWorkerState
typealias RemoteSyncState = VoCalCapture.RemoteSyncState
typealias PendingRemoteSyncState = VoCalCapture.PendingRemoteSyncState
typealias ActiveRemoteSyncState = VoCalCapture.ActiveRemoteSyncState
typealias QuarantinedRemoteSyncState = VoCalCapture.QuarantinedRemoteSyncState
typealias UploadLease = VoCalCapture.UploadLease
typealias OutboxSnapshot = VoCalCapture.OutboxSnapshot
typealias OutboxSnapshotCapture = VoCalCapture.OutboxSnapshotCapture
typealias OutboxHint = VoCalCapture.OutboxHint
typealias OutboxMutation = VoCalCapture.OutboxMutation
typealias MutationResult = VoCalCapture.MutationResult
typealias CaptureServerArtifact = VoCalCapture.CaptureServerArtifact
typealias CaptureServerRecord = VoCalCapture.CaptureServerRecord
typealias CaptureListResponse = VoCalCapture.CaptureListResponse
typealias LocalCaptureRecord = VoCalCapture.LocalCaptureRecord

struct CaptureOutboxSummary: Equatable, Sendable {
    let declaredCount: Int
    let uploadingCount: Int
    let pendingCloudCount: Int
    let enrichedCount: Int
    let failedCount: Int
    let recentCaptures: [LocalCaptureRecord]
}

struct PreparedCapture {
    let captureID: String
    let kind: String
    let source: String
    let title: String
    let textContent: String
    let foundURL: String
    let capturedAt: Date
    let effectiveDay: String
    let blobFilename: String
    let blobContentType: String
    let manifestJSON: Data

    init(
        captureID: String,
        kind: String,
        source: String,
        title: String,
        textContent: String,
        foundURL: String = "",
        capturedAt: Date,
        effectiveDay: String,
        blobFilename: String,
        blobContentType: String,
        manifestJSON: Data
    ) {
        self.captureID = captureID
        self.kind = kind
        self.source = source
        self.title = title
        self.textContent = textContent
        self.foundURL = foundURL
        self.capturedAt = capturedAt
        self.effectiveDay = effectiveDay
        self.blobFilename = blobFilename
        self.blobContentType = blobContentType
        self.manifestJSON = manifestJSON
    }
}

struct CaptureBlobPayload {
    let data: Data?
    let fileURL: URL?
    let filename: String
    let contentType: String
    let byteCount: Int64

    init(data: Data, filename: String, contentType: String) {
        self.data = data
        self.fileURL = nil
        self.filename = filename
        self.contentType = contentType
        byteCount = Int64(data.count)
    }

    init(fileURL: URL, filename: String, contentType: String, byteCount: Int64) {
        data = nil
        self.fileURL = fileURL
        self.filename = filename
        self.contentType = contentType
        self.byteCount = byteCount
    }
}

enum CaptureOutboxError: LocalizedError {
    case invalidManifest
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return "capture_manifest_invalid"
        case let .sqlite(message):
            return message
        }
    }
}

final class CaptureOutbox: Sendable {
    private static let uploadLeaseInterval: TimeInterval = 5 * 60

    private struct State {
        var database: OpaquePointer?
    }

    private let appGroupRoot: URL
    private let databaseURL: URL
    private let rootDirectory: URL
    private let storage: Mutex<State>

    private static func makeStorage() -> Mutex<State> {
        Mutex(State(database: nil))
    }

    init(appGroupRoot: URL, fileManager: FileManager = .default) throws {
        self.appGroupRoot = appGroupRoot
        let layout = try VoCalCapturePaths.ensureInitialized(appGroupRoot: appGroupRoot, fileManager: fileManager)
        rootDirectory = layout.root
        databaseURL = layout.root.appendingPathComponent("capture-outbox.sqlite", isDirectory: false)
        storage = Self.makeStorage()
        try openDatabase()
        try migrate()
    }

    deinit {
        withStateLock { state in
            if let db = state.database {
                sqlite3_close(db)
                state.database = nil
            }
        }
    }

    var path: String {
        databaseURL.path
    }

    var blobsRoot: URL {
        rootDirectory.appendingPathComponent(VoCalCapturePaths.blobsFolder, isDirectory: true)
    }

    var requestBodiesRoot: URL {
        rootDirectory.appendingPathComponent(VoCalCapturePaths.requestsFolder, isDirectory: true)
    }

    func requestBodyURL(captureID: String) -> URL {
        requestBodiesRoot.appendingPathComponent("\(captureID).multipart", isDirectory: false)
    }

    func observe() -> AsyncStream<OutboxHint> {
        let databaseURL = URL(fileURLWithPath: path, isDirectory: false)
        // Seam cut (share extension): Serein additionally monitored the cross-process
        // share-inbox staging directory here. Requirement: Vo-Cal P0 has no share
        // extension and no second process writing captures (INVARIANTS §5 is an explicit
        // tombstone). Failure mode avoided: watching a directory nothing writes to —
        // dead plumbing that implies a cross-process contract which does not exist.
        // Evidence: docs/INVARIANTS.md §5; phase plan C1 seam list.
        return AsyncStream { continuation in
            let monitor = CaptureOutboxMonitor(
                databaseURL: databaseURL,
                extraMonitoredURLs: []
            ) { _ in
                continuation.yield(.maybeChanged)
            }
            Task {
                await monitor.start()
            }
            continuation.onTermination = { _ in
                Task {
                    await monitor.stop()
                }
            }
            continuation.yield(.maybeChanged)
        }
    }

    @discardableResult
    func enqueue(prepared: PreparedCapture, blob: CaptureBlobPayload?) throws -> LocalCommitReceipt {
        let result = try storage.withLock { state -> (record: LocalCaptureRecord, wasDuplicate: Bool, blobPresent: Bool) in
            let db = state.database
            let fileManager = FileManager()
            if let existing = try fetchCapture(captureID: prepared.captureID, db: db) {
                return (existing, true, existing.blobPath != nil)
            }

            let blobPath: String?
            let blobSize: Int64
            var stagedBlobURL: URL?
            do {
                if let blob {
                    let targetDirectory = blobsRoot.appendingPathComponent(prepared.captureID, isDirectory: true)
                    try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                    let targetURL = targetDirectory.appendingPathComponent(blob.filename, isDirectory: false)
                    if let data = blob.data {
                        try data.write(to: targetURL, options: .atomic)
                    } else if let fileURL = blob.fileURL {
                        if fileManager.fileExists(atPath: targetURL.path) {
                            try fileManager.removeItem(at: targetURL)
                        }
                        try fileManager.copyItem(at: fileURL, to: targetURL)
                    } else {
                        throw CaptureOutboxError.sqlite("capture_blob_missing_storage")
                    }
                    stagedBlobURL = targetURL
                    blobPath = targetURL.path
                    blobSize = blob.byteCount
                } else {
                    blobPath = nil
                    blobSize = 0
                }

                let now = CaptureDateCodec.internetString(Date())
                let sql = """
                INSERT INTO capture_outbox (
                    capture_id, kind, source, title, text_content, found_url, captured_at, effective_day, state, last_error,
                    retry_count, manifest_json, blob_path, blob_filename, blob_content_type, blob_size, artifact_count, artifacts_json,
                    created_at, updated_at, uploaded_at, enriched_at, upload_claimed_at, upload_deadline_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, ?, ?, ?, ?, ?, 0, ?, ?, ?, NULL, NULL, NULL, NULL)
                """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw sqliteError(db, context: "prepare enqueue capture")
                }
                defer { sqlite3_finalize(statement) }
                bindText(prepared.captureID, index: 1, statement: statement)
                bindText(prepared.kind, index: 2, statement: statement)
                bindText(prepared.source, index: 3, statement: statement)
                bindText(prepared.title, index: 4, statement: statement)
                bindText(prepared.textContent, index: 5, statement: statement)
                bindText(prepared.foundURL, index: 6, statement: statement)
                bindText(CaptureDateCodec.internetString(prepared.capturedAt), index: 7, statement: statement)
                bindText(prepared.effectiveDay, index: 8, statement: statement)
                bindText(CaptureLocalState.declared.rawValue, index: 9, statement: statement)
                bindBlob(prepared.manifestJSON, index: 10, statement: statement)
                bindOptionalText(blobPath, index: 11, statement: statement)
                bindText(prepared.blobFilename, index: 12, statement: statement)
                bindText(prepared.blobContentType, index: 13, statement: statement)
                bindInt64(blobSize, index: 14, statement: statement)
                bindBlob(Data("[]".utf8), index: 15, statement: statement)
                bindText(now, index: 16, statement: statement)
                bindText(now, index: 17, statement: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError(db, context: "enqueue capture")
                }
                guard let record = try fetchCapture(captureID: prepared.captureID, db: db) else {
                    throw CaptureOutboxError.sqlite("capture_insert_missing")
                }
                return (record, false, blobPath != nil)
            } catch {
                if let stagedBlobURL {
                    try? fileManager.removeItem(at: stagedBlobURL)
                }
                throw error
            }
        }

        if result.wasDuplicate {
            emit(
                .debug,
                name: "outbox.enqueue_duplicate",
                message: "Skipped enqueue because capture already exists in local outbox",
                metadata: captureMetadata(
                    for: result.record,
                    extra: ["result": "existing"]
                )
            )
            return result.record
        }
        emit(
            .notice,
            name: "outbox.capture_enqueued",
            message: "Committed capture to local outbox",
            metadata: captureMetadata(
                for: result.record,
                extra: [
                    "blob_present": result.blobPresent ? "true" : "false",
                    "mutation": "enqueue",
                ]
            )
        )
        return result.record
    }

    func pendingUploads(limit: Int) throws -> [LocalCaptureRecord] {
        try storage.withLock { state in
            let db = state.database
            let sql = """
            SELECT capture_id, kind, source, title, text_content, found_url, captured_at, effective_day, state, last_error,
                   retry_count, manifest_json, blob_path, blob_filename, blob_content_type, blob_size, artifact_count, artifacts_json,
                   created_at, updated_at, uploaded_at, enriched_at, upload_claimed_at, upload_deadline_at,
                   sync_attempt_count, sync_next_eligible_at, sync_failure_class, sync_failure_message, sync_failure_domain,
                   sync_failure_code, sync_http_status, sync_quarantined_at
            FROM capture_outbox
            WHERE state IN (?, ?)
            ORDER BY created_at ASC
            LIMIT ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare pending uploads")
            }
            defer { sqlite3_finalize(statement) }
            bindText(CaptureLocalState.declared.rawValue, index: 1, statement: statement)
            bindText(CaptureLocalState.uploadFailed.rawValue, index: 2, statement: statement)
            sqlite3_bind_int(statement, 3, Int32(max(1, limit)))
            return try fetchCaptures(statement: statement, db: db)
        }
    }

    func markUploading(captureID: String, claimedAt: Date = Date()) throws {
        try updateState(
            captureID: captureID,
            state: .uploading,
            lastError: nil,
            uploadedAt: nil,
            enrichedAt: nil,
            retryCount: nil,
            incrementRetryCount: false,
            claimedAt: claimedAt,
            mutation: "mark_uploading"
        )
    }

    func markUploadFailed(captureID: String, error: String) throws {
        try updateState(
            captureID: captureID,
            state: .uploadFailed,
            lastError: error,
            uploadedAt: nil,
            enrichedAt: nil,
            retryCount: nil,
            incrementRetryCount: true,
            claimedAt: nil,
            mutation: "mark_upload_failed"
        )
    }

    @discardableResult
    func reapExpiredUploading(now: Date = Date(), lastError: String = "upload_lease_expired") throws -> [String] {
        let expiredCaptureIDs = try captureIDsMatchingUploadingLeaseExpiry(before: now)
        guard !expiredCaptureIDs.isEmpty else {
            return []
        }
        return try resetUploadingToDeclared(
            captureIDs: expiredCaptureIDs,
            lastError: lastError,
            mutation: "reap_expired_uploading"
        )
    }

    @discardableResult
    func resetUploadingToDeclaredExcluding(
        captureIDsToKeep: Set<String>,
        lastError: String = "upload_session_recovered"
    ) throws -> [String] {
        let captureIDs = try uploadingCaptureIDs(excluding: captureIDsToKeep)
        guard !captureIDs.isEmpty else {
            return []
        }
        return try resetUploadingToDeclared(
            captureIDs: captureIDs,
            lastError: lastError,
            mutation: "reset_uploading_without_task"
        )
    }

    @discardableResult
    func resetUploadingToDeclared(
        captureID: String,
        lastError: String = "upload_session_recovered"
    ) throws -> Bool {
        let resetCaptureIDs = try resetUploadingToDeclared(
            captureIDs: [captureID],
            lastError: lastError,
            mutation: "reset_uploading_capture"
        )
        return !resetCaptureIDs.isEmpty
    }

    func pruneUnreadableURLGhosts() throws -> Int {
        let ghosts = try storage.withLock { state in
            let db = state.database
            let sql = """
            SELECT capture_id, kind, source, title, text_content, found_url, captured_at, effective_day, state, last_error,
                   retry_count, manifest_json, blob_path, blob_filename, blob_content_type, blob_size, artifact_count, artifacts_json,
                   created_at, updated_at, uploaded_at, enriched_at, upload_claimed_at, upload_deadline_at,
                   sync_attempt_count, sync_next_eligible_at, sync_failure_class, sync_failure_message, sync_failure_domain,
                   sync_failure_code, sync_http_status, sync_quarantined_at
            FROM capture_outbox
            WHERE kind = 'url'
              AND found_url = ''
              AND blob_content_type = 'application/macbinary'
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare prune unreadable url ghosts")
            }
            defer { sqlite3_finalize(statement) }
            return try fetchCaptures(statement: statement, db: db)
        }

        guard !ghosts.isEmpty else {
            return 0
        }

        try storage.withLock { state in
            let db = state.database
            let sql = "DELETE FROM capture_outbox WHERE capture_id = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare delete unreadable url ghost")
            }
            defer { sqlite3_finalize(statement) }

            for ghost in ghosts {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindText(ghost.captureID, index: 1, statement: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError(db, context: "delete unreadable url ghost")
                }
            }
        }

        for ghost in ghosts {
            if let blobPath = ghost.blobPath, !blobPath.isEmpty {
                try? FileManager().removeItem(atPath: blobPath)
            }
        }

        emit(
            .notice,
            name: "outbox.unreadable_url_ghosts_pruned",
            message: "Pruned unreadable URL transport ghosts from local outbox",
            metadata: [
                "mutation": "prune_unreadable_url_ghosts",
                "pruned_count": "\(ghosts.count)",
                "capture_ids": ghosts.map(\.captureID).joined(separator: ","),
            ]
        )
        return ghosts.count
    }

    func applyServerRecord(_ record: CaptureServerRecord) throws {
        if Self.isUnreadableURLGhost(record) {
            emit(
                .warning,
                name: "outbox.server_record_skipped",
                message: "Skipped unreadable URL transport ghost from relay",
                metadata: [
                    "capture_id": record.captureID,
                    "kind": record.kind,
                    "blob_content_type": record.blobContentType ?? "",
                    "mutation": "skip_unreadable_url_ghost",
                ]
            )
            return
        }
        let previous = try fetchCapture(captureID: record.captureID)
        let previousText = previous?.textContent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentText = (record.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = previous == nil ||
            previous?.state != record.state ||
            previous?.artifactCount != record.artifacts.count ||
            previous?.artifacts != record.artifacts ||
            previous?.lastError != record.lastError ||
            previous?.foundURL != (record.foundURL ?? "") ||
            previousText != currentText
        guard changed else {
            return
        }
        let artifactsJSON = try encodeArtifacts(record.artifacts)
        try storage.withLock { state in
            let db = state.database
            let sql = """
            INSERT INTO capture_outbox (
                capture_id, kind, source, title, text_content, found_url, captured_at, effective_day, state, last_error,
                retry_count, manifest_json, blob_path, blob_filename, blob_content_type, blob_size, artifact_count, artifacts_json,
                created_at, updated_at, uploaded_at, enriched_at, upload_claimed_at, upload_deadline_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, 0, ?, ?, ?, ?, ?, ?, NULL, NULL)
            ON CONFLICT(capture_id) DO UPDATE SET
                kind = excluded.kind,
                source = excluded.source,
                title = CASE WHEN excluded.title = '' THEN capture_outbox.title ELSE excluded.title END,
                text_content = CASE WHEN excluded.text_content = '' THEN capture_outbox.text_content ELSE excluded.text_content END,
                found_url = CASE WHEN excluded.found_url = '' THEN capture_outbox.found_url ELSE excluded.found_url END,
                captured_at = excluded.captured_at,
                effective_day = excluded.effective_day,
                state = excluded.state,
                last_error = excluded.last_error,
                retry_count = excluded.retry_count,
                blob_filename = CASE WHEN excluded.blob_filename = '' THEN capture_outbox.blob_filename ELSE excluded.blob_filename END,
                blob_content_type = CASE WHEN excluded.blob_content_type = '' THEN capture_outbox.blob_content_type ELSE excluded.blob_content_type END,
                artifact_count = excluded.artifact_count,
                artifacts_json = excluded.artifacts_json,
                updated_at = excluded.updated_at,
                uploaded_at = COALESCE(excluded.uploaded_at, capture_outbox.uploaded_at),
                enriched_at = COALESCE(excluded.enriched_at, capture_outbox.enriched_at),
                upload_claimed_at = NULL,
                upload_deadline_at = NULL,
                sync_attempt_count = 0,
                sync_next_eligible_at = NULL,
                sync_failure_class = NULL,
                sync_failure_message = NULL,
                sync_failure_domain = NULL,
                sync_failure_code = NULL,
                sync_http_status = NULL,
                sync_quarantined_at = NULL
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare apply server capture")
            }
            defer { sqlite3_finalize(statement) }
            let now = CaptureDateCodec.internetString(Date())
            let uploadedAt = record.state == CaptureLocalState.declared.rawValue
                ? nil
                : CaptureDateCodec.internetString(record.createdAt)
            bindText(record.captureID, index: 1, statement: statement)
            bindText(record.kind, index: 2, statement: statement)
            bindText(record.source, index: 3, statement: statement)
            bindText(record.title ?? "", index: 4, statement: statement)
            bindText(record.textContent ?? "", index: 5, statement: statement)
            bindText(record.foundURL ?? "", index: 6, statement: statement)
            bindText(CaptureDateCodec.internetString(record.capturedAt), index: 7, statement: statement)
            bindText(record.effectiveDay, index: 8, statement: statement)
            bindText(record.state, index: 9, statement: statement)
            bindOptionalText(record.lastError, index: 10, statement: statement)
            sqlite3_bind_int(statement, 11, Int32(previous?.retryCount ?? 0))
            bindBlob(Data("{}".utf8), index: 12, statement: statement)
            bindText(record.blobFilename ?? "", index: 13, statement: statement)
            bindText(record.blobContentType ?? "", index: 14, statement: statement)
            bindInt64(Int64(record.artifacts.count), index: 15, statement: statement)
            bindBlob(artifactsJSON, index: 16, statement: statement)
            bindText(now, index: 17, statement: statement)
            bindText(now, index: 18, statement: statement)
            bindOptionalText(uploadedAt, index: 19, statement: statement)
            bindOptionalText(record.enrichedAt.map(CaptureDateCodec.internetString), index: 20, statement: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(db, context: "apply server capture")
            }
        }
        emit(
            .info,
            name: "outbox.server_record_applied",
            message: "Applied relay capture record to local outbox",
            metadata: [
                "capture_id": record.captureID,
                "from_state": previous?.state ?? "missing",
                "to_state": record.state,
                "artifact_count": "\(record.artifacts.count)",
                "previous_artifact_count": "\(previous?.artifactCount ?? 0)",
                "has_text_content": currentText.isEmpty ? "false" : "true",
                "remote_seq": "\(record.seq)",
                "mutation": "apply_server_record",
            ]
        )
    }

    func applyServerRecords(_ records: [CaptureServerRecord]) throws {
        for record in records {
            try applyServerRecord(record)
        }
    }

    func summary(limit: Int) throws -> CaptureOutboxSummary {
        let counts = try storage.withLock { state in
            let db = state.database
            let sql = """
            SELECT
                SUM(CASE WHEN state = 'declared' THEN 1 ELSE 0 END),
                SUM(CASE WHEN state = 'uploading' THEN 1 ELSE 0 END),
                SUM(CASE WHEN state IN ('uploaded', 'enrichment_pending') THEN 1 ELSE 0 END),
                SUM(CASE WHEN state = 'enriched' THEN 1 ELSE 0 END),
                SUM(CASE WHEN state = 'upload_failed' THEN 1 ELSE 0 END)
            FROM capture_outbox
            WHERE capture_id NOT LIKE 'self_test_%'
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare outbox counts")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(db, context: "outbox counts")
            }
            return (
                Int(sqlite3_column_int(statement, 0)),
                Int(sqlite3_column_int(statement, 1)),
                Int(sqlite3_column_int(statement, 2)),
                Int(sqlite3_column_int(statement, 3)),
                Int(sqlite3_column_int(statement, 4))
            )
        }
        return CaptureOutboxSummary(
            declaredCount: counts.0,
            uploadingCount: counts.1,
            pendingCloudCount: counts.2,
            enrichedCount: counts.3,
            failedCount: counts.4,
            recentCaptures: try recentCaptures(limit: limit)
        )
    }

    func operationalSummary() throws -> CaptureOperationalSummary {
        let queueHealth = try relayQueueHealth()
        let counts = try storage.withLock { state in
            let db = state.database
            let sql = """
            SELECT
                SUM(CASE WHEN state = 'declared' THEN 1 ELSE 0 END),
                SUM(CASE WHEN state = 'uploading' THEN 1 ELSE 0 END),
                SUM(CASE WHEN state = 'upload_failed' THEN 1 ELSE 0 END)
            FROM capture_outbox
            WHERE capture_id NOT LIKE 'self_test_%'
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare operational counts")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(db, context: "operational counts")
            }
            return (
                Int(sqlite3_column_int(statement, 0)),
                Int(sqlite3_column_int(statement, 1)),
                Int(sqlite3_column_int(statement, 2))
            )
        }

        let latestCapture: (String?, String?, Date?) = try storage.withLock { state in
            let db = state.database
            let sql = """
            SELECT capture_id, state, created_at
            FROM capture_outbox
            WHERE capture_id NOT LIKE 'self_test_%'
            ORDER BY created_at DESC
            LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare latest operational capture")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return (nil, nil, nil)
            }
            let captureID = columnOptionalString(statement, index: 0)
            let state = columnOptionalString(statement, index: 1)
            let createdAt = try columnOptionalString(statement, index: 2).flatMap(CaptureDateCodec.parseInternetDate)
            return (captureID, state, createdAt)
        }

        return CaptureOperationalSummary(
            declaredCount: counts.0,
            uploadingCount: counts.1,
            failedCount: counts.2,
            pendingJobCount: queueHealth.pendingJobCount,
            quarantinedCount: queueHealth.quarantinedCount,
            authPaused: queueHealth.authPaused,
            pausedReason: queueHealth.pausedReason,
            oldestPendingCreatedAt: queueHealth.oldestPendingCreatedAt,
            lastSuccessfulUploadAt: queueHealth.lastSuccessfulUploadAt,
            latestCaptureID: latestCapture.0,
            latestCaptureState: latestCapture.1,
            latestCaptureCreatedAt: latestCapture.2
        )
    }

    func recentCaptures(limit: Int) throws -> [LocalCaptureRecord] {
        try storage.withLock { state in
            let db = state.database
            let sql = """
            SELECT capture_id, kind, source, title, text_content, found_url, captured_at, effective_day, state, last_error,
                   retry_count, manifest_json, blob_path, blob_filename, blob_content_type, blob_size, artifact_count, artifacts_json,
                   created_at, updated_at, uploaded_at, enriched_at, upload_claimed_at, upload_deadline_at,
                   sync_attempt_count, sync_next_eligible_at, sync_failure_class, sync_failure_message, sync_failure_domain,
                   sync_failure_code, sync_http_status, sync_quarantined_at
            FROM capture_outbox
            WHERE capture_id NOT LIKE 'self_test_%'
            ORDER BY captured_at DESC, created_at DESC, updated_at DESC
            LIMIT ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare recent captures")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            return try fetchCaptures(statement: statement, db: db)
        }
    }

    func capture(captureID: String) throws -> LocalCaptureRecord? {
        try fetchCapture(captureID: captureID)
    }

    func snapshot() throws -> OutboxSnapshot {
        let captures: [LocalCaptureRecord] = try storage.withLock { state in
            let db = state.database
            let sql = """
            SELECT capture_id, kind, source, title, text_content, found_url, captured_at, effective_day, state, last_error,
                   retry_count, manifest_json, blob_path, blob_filename, blob_content_type, blob_size, artifact_count, artifacts_json,
                   created_at, updated_at, uploaded_at, enriched_at, upload_claimed_at, upload_deadline_at,
                   sync_attempt_count, sync_next_eligible_at, sync_failure_class, sync_failure_message, sync_failure_domain,
                   sync_failure_code, sync_http_status, sync_quarantined_at
            FROM capture_outbox
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare outbox snapshot")
            }
            defer { sqlite3_finalize(statement) }
            return try fetchCaptures(statement: statement, db: db)
        }
        return OutboxSnapshot(
            captures: captures.map(makeSnapshotCapture),
            workerState: try relayWorkerState()
        )
    }

    @discardableResult
    func apply(_ mutation: OutboxMutation) throws -> MutationResult {
        switch mutation {
        case let .claimUpload(captureID, expectedUpdatedAt, attemptCount, claimedAt, deadline):
            return MutationResult(
                applied: try applyClaimUpload(
                    captureID: captureID,
                    expectedUpdatedAt: expectedUpdatedAt,
                    attemptCount: attemptCount,
                    claimedAt: claimedAt,
                    deadline: deadline
                )
            )
        case let .requeue(captureID, expectedClaimedAt, lifecycleState, nextEligibleAt, failureClass, failureMessage, failureDomain, failureCode, httpStatus):
            return MutationResult(
                applied: try applyRequeue(
                    captureID: captureID,
                    expectedClaimedAt: expectedClaimedAt,
                    lifecycleState: lifecycleState,
                    nextEligibleAt: nextEligibleAt,
                    failureClass: failureClass,
                    failureMessage: failureMessage,
                    failureDomain: failureDomain,
                    failureCode: failureCode,
                    httpStatus: httpStatus
                )
            )
        case let .quarantine(captureID, expectedClaimedAt, quarantinedAt, failureClass, failureMessage, failureDomain, failureCode, httpStatus):
            return MutationResult(
                applied: try applyQuarantine(
                    captureID: captureID,
                    expectedClaimedAt: expectedClaimedAt,
                    quarantinedAt: quarantinedAt,
                    failureClass: failureClass,
                    failureMessage: failureMessage,
                    failureDomain: failureDomain,
                    failureCode: failureCode,
                    httpStatus: httpStatus
                )
            )
        case let .applyServerRecord(record, completedAt):
            try applyServerRecord(record)
            try storage.withLock { state in
                try upsertRelayWorkerState(
                    db: state.database,
                    authPaused: nil,
                    authPauseMessage: nil,
                    lastSuccessfulUploadAt: completedAt,
                    lastSuccessfulCaptureID: record.captureID,
                    lastPollAt: completedAt,
                    lastPollReason: "upload_succeeded"
                )
            }
            return MutationResult(applied: true)
        case let .pauseAuth(message, at, reason):
            try pauseRelayAuth(message: message, at: at)
            try storage.withLock { state in
                try upsertRelayWorkerState(
                    db: state.database,
                    authPaused: true,
                    authPauseMessage: message,
                    lastSuccessfulUploadAt: nil,
                    lastSuccessfulCaptureID: nil,
                    lastPollAt: at,
                    lastPollReason: reason
                )
            }
            return MutationResult(applied: true)
        case let .resumeAuth(at, reason):
            try resumeRelayAuth(at: at, reason: reason)
            return MutationResult(applied: true)
        case let .recordPoll(at, reason):
            try recordRelayPoll(reason: reason, at: at)
            return MutationResult(applied: true)
        }
    }

    func relayJob(captureID: String) throws -> RelayJobRecord? {
        guard let record = try capture(captureID: captureID) else {
            return nil
        }
        return makeRelayJobRecord(for: record)
    }

    func relayWorkerState() throws -> RelayWorkerState {
        try storage.withLock { state in
            try fetchRelayWorkerState(db: state.database)
        }
    }

    func relayQueueHealth() throws -> RelayQueueHealth {
        let snapshot = try snapshot()
        let captures = snapshot.captures.filter { !$0.captureID.hasPrefix("self_test_") }
        var pendingJobCount = 0
        var leasedCount = 0
        var quarantinedCount = 0
        var oldestPendingCreatedAt: Date?

        for capture in captures {
            switch capture.remoteSyncState {
            case .pending:
                pendingJobCount += 1
                oldestPendingCreatedAt = minDate(oldestPendingCreatedAt, capture.createdAt)
            case .uploading:
                pendingJobCount += 1
                leasedCount += 1
                oldestPendingCreatedAt = minDate(oldestPendingCreatedAt, capture.createdAt)
            case .quarantined:
                quarantinedCount += 1
            case .none:
                continue
            }
        }

        return RelayQueueHealth(
            pendingJobCount: pendingJobCount,
            leasedCount: leasedCount,
            quarantinedCount: quarantinedCount,
            authPaused: snapshot.workerState.authPaused,
            pausedReason: snapshot.workerState.authPauseMessage,
            oldestPendingCreatedAt: oldestPendingCreatedAt,
            lastSuccessfulUploadAt: snapshot.workerState.lastSuccessfulUploadAt,
            lastSuccessfulCaptureID: snapshot.workerState.lastSuccessfulCaptureID
        )
    }

    func recordRelayPoll(reason: String, at: Date = Date()) throws {
        try storage.withLock { state in
            try upsertRelayWorkerState(
                db: state.database,
                authPaused: nil,
                authPauseMessage: nil,
                lastSuccessfulUploadAt: nil,
                lastSuccessfulCaptureID: nil,
                lastPollAt: at,
                lastPollReason: reason
            )
        }
    }

    func pauseRelayAuth(message: String?, at: Date = Date()) throws {
        try storage.withLock { state in
            try upsertRelayWorkerState(
                db: state.database,
                authPaused: true,
                authPauseMessage: message,
                lastSuccessfulUploadAt: nil,
                lastSuccessfulCaptureID: nil,
                lastPollAt: at,
                lastPollReason: "auth_paused"
            )
        }
    }

    func resumeRelayAuth(at: Date = Date(), reason: String = "credential_changed") throws {
        try storage.withLock { state in
            try upsertRelayWorkerState(
                db: state.database,
                authPaused: false,
                authPauseMessage: nil,
                lastSuccessfulUploadAt: nil,
                lastSuccessfulCaptureID: nil,
                lastPollAt: at,
                lastPollReason: reason
            )
        }
    }

    func claimEligibleRelayJobs(limit: Int, now: Date = Date()) throws -> [RelayJobRecord] {
        guard limit > 0 else {
            return []
        }
        let snapshot = try snapshot()
        let activeCaptureIDs = Set(
            snapshot.captures.compactMap { capture in
                if case .uploading = capture.remoteSyncState {
                    return capture.captureID
                }
                return nil
            }
        )
        let planner = RelayPlanner()
        let plan = planner.plan(
            snapshot: snapshot,
            now: now,
            activeCaptureIDs: activeCaptureIDs,
            concurrencyLimit: activeCaptureIDs.count + limit
        )

        var claimedJobs: [RelayJobRecord] = []
        for mutation in plan.mutations {
            switch mutation {
            case let .claimUpload(captureID, _, _, _, _):
                let result = try apply(mutation)
                guard result.applied,
                      let job = try relayJob(captureID: captureID)
                else {
                    continue
                }
                claimedJobs.append(job)
            default:
                _ = try apply(mutation)
            }
        }
        return claimedJobs
    }

    @discardableResult
    func renewRelayJobLease(captureID: String, leaseToken: String, now: Date = Date()) throws -> Bool {
        let _ = (captureID, leaseToken, now)
        // Lease renewal is intentionally retired. Fixed deadlines remove the stale-success race where
        // successful uploads were discarded after a silent renewal failure reclaimed the row.
        return false
    }

    @discardableResult
    func releaseRelayJobAsSuccess(captureID: String, leaseToken: String, at: Date = Date()) throws -> Bool {
        let _ = leaseToken
        guard try capture(captureID: captureID) != nil else {
            return false
        }
        try storage.withLock { state in
            try upsertRelayWorkerState(
                db: state.database,
                authPaused: nil,
                authPauseMessage: nil,
                lastSuccessfulUploadAt: at,
                lastSuccessfulCaptureID: captureID,
                lastPollAt: at,
                lastPollReason: "upload_succeeded"
            )
        }
        return true
    }

    @discardableResult
    func requeueRelayJob(
        captureID: String,
        leaseToken: String?,
        nextEligibleAt: Date,
        failureClass: RelayFailureClass?,
        failureMessage: String?,
        failureDomain: String?,
        failureCode: Int?,
        httpStatus: Int?,
        at: Date = Date(),
        mutation: String = "relay_job_requeued"
    ) throws -> Bool {
        let expectedClaimedAt = try leaseToken.flatMap(CaptureDateCodec.parseInternetDate)
        // A requeue always lands the job in .uploadFailed (eligible for retry), whether or not it
        // held a lease — both arms of the prior ternary were identical, which read as if claimed
        // and unclaimed requeues diverged. They don't.
        let lifecycleState: CaptureLocalState = .uploadFailed
        let result = try apply(
            .requeue(
                captureID: captureID,
                expectedClaimedAt: expectedClaimedAt,
                lifecycleState: lifecycleState,
                nextEligibleAt: nextEligibleAt,
                failureClass: failureClass,
                failureMessage: failureMessage,
                failureDomain: failureDomain,
                failureCode: failureCode,
                httpStatus: httpStatus
            )
        )
        if result.applied, let updated = try capture(captureID: captureID) {
            emit(
                .warning,
                name: "outbox.relay_job_requeued",
                message: "Requeued capture in outbox sync ledger",
                metadata: captureMetadata(
                    for: updated,
                    extra: [
                        "mutation": mutation,
                        "next_eligible_at": CaptureDateCodec.internetString(nextEligibleAt),
                    ]
                )
            )
        }
        let _ = at
        return result.applied
    }

    @discardableResult
    func quarantineRelayJob(
        captureID: String,
        leaseToken: String?,
        failureClass: RelayFailureClass,
        failureMessage: String?,
        failureDomain: String?,
        failureCode: Int?,
        httpStatus: Int?,
        at: Date = Date()
    ) throws -> Bool {
        let expectedClaimedAt = try leaseToken.flatMap(CaptureDateCodec.parseInternetDate)
        let result = try apply(
            .quarantine(
                captureID: captureID,
                expectedClaimedAt: expectedClaimedAt,
                quarantinedAt: at,
                failureClass: failureClass,
                failureMessage: failureMessage,
                failureDomain: failureDomain,
                failureCode: failureCode,
                httpStatus: httpStatus
            )
        )
        if result.applied, let updated = try capture(captureID: captureID) {
            emit(
                .warning,
                name: "outbox.relay_job_quarantined",
                message: "Quarantined capture in outbox sync ledger",
                metadata: captureMetadata(
                    for: updated,
                    extra: ["mutation": "relay_job_quarantined"]
                )
            )
        }
        return result.applied
    }

    @discardableResult
    func reclaimExpiredRelayLeases(now: Date = Date(), retryDelay: TimeInterval = 30) throws -> [String] {
        let snapshot = try snapshot()
        var captureIDs: [String] = []
        for capture in snapshot.captures {
            guard case let .uploading(uploading) = capture.remoteSyncState,
                  uploading.lease.deadline < now
            else {
                continue
            }
            let result = try apply(
                .requeue(
                    captureID: capture.captureID,
                    expectedClaimedAt: uploading.lease.claimedAt,
                    lifecycleState: .declared,
                    nextEligibleAt: now.addingTimeInterval(retryDelay),
                    failureClass: .transient,
                    failureMessage: "lease_expired",
                    failureDomain: nil,
                    failureCode: nil,
                    httpStatus: nil
                )
            )
            if result.applied {
                captureIDs.append(capture.captureID)
            }
        }
        return captureIDs
    }

    @discardableResult
    func requeueLeasedRelayJobsExcluding(
        captureIDsToKeep: Set<String>,
        now: Date = Date(),
        lastError: String = "upload_session_recovered"
    ) throws -> [String] {
        let snapshot = try snapshot()
        var captureIDs: [String] = []
        for capture in snapshot.captures {
            guard case let .uploading(uploading) = capture.remoteSyncState,
                  !captureIDsToKeep.contains(capture.captureID)
            else {
                continue
            }
            let result = try apply(
                .requeue(
                    captureID: capture.captureID,
                    expectedClaimedAt: uploading.lease.claimedAt,
                    lifecycleState: .declared,
                    nextEligibleAt: now,
                    failureClass: .transient,
                    failureMessage: lastError,
                    failureDomain: nil,
                    failureCode: nil,
                    httpStatus: nil
                )
            )
            if result.applied {
                captureIDs.append(capture.captureID)
            }
        }
        return captureIDs
    }

    func leasedRelayCaptureIDs() throws -> Set<String> {
        let snapshot = try snapshot()
        return Set(
            snapshot.captures.compactMap { capture in
                switch capture.remoteSyncState {
                case .uploading:
                    return capture.captureID
                default:
                    return nil
                }
            }
        )
    }

    func hasPendingRelayJobs() throws -> Bool {
        let snapshot = try snapshot()
        return snapshot.captures.contains { capture in
            switch capture.remoteSyncState {
            case .pending, .uploading:
                return true
            case .none, .quarantined:
                return false
            }
        }
    }

    func nextEligibleRelayJobAt() throws -> Date? {
        let snapshot = try snapshot()
        return snapshot.captures.compactMap { capture -> Date? in
            switch capture.remoteSyncState {
            case let .pending(pending):
                return pending.nextEligibleAt
            default:
                return nil
            }
        }
        .min()
    }

    private func fetchCapture(captureID: String) throws -> LocalCaptureRecord? {
        try storage.withLock { state in
            let db = state.database
            return try fetchCapture(captureID: captureID, db: db)
        }
    }

    private func fetchCapture(captureID: String, db: OpaquePointer?) throws -> LocalCaptureRecord? {
            let sql = """
            SELECT capture_id, kind, source, title, text_content, found_url, captured_at, effective_day, state, last_error,
                   retry_count, manifest_json, blob_path, blob_filename, blob_content_type, blob_size, artifact_count, artifacts_json,
                   created_at, updated_at, uploaded_at, enriched_at, upload_claimed_at, upload_deadline_at,
                   sync_attempt_count, sync_next_eligible_at, sync_failure_class, sync_failure_message, sync_failure_domain,
                   sync_failure_code, sync_http_status, sync_quarantined_at
            FROM capture_outbox
            WHERE capture_id = ?
            LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare fetch capture")
            }
            defer { sqlite3_finalize(statement) }
            bindText(captureID, index: 1, statement: statement)
            let captures = try fetchCaptures(statement: statement, db: db)
            return captures.first
    }

    private func updateState(
        captureID: String,
        state: CaptureLocalState,
        lastError: String?,
        uploadedAt: String?,
        enrichedAt: String?,
        retryCount: Int?,
        incrementRetryCount: Bool,
        claimedAt: Date?,
        mutation: String
    ) throws {
        let previous = try fetchCapture(captureID: captureID)
        let nextRetryCount: Int
        if incrementRetryCount {
            nextRetryCount = (previous?.retryCount ?? 0) + 1
        } else {
            nextRetryCount = retryCount ?? previous?.retryCount ?? 0
        }
        let uploadClaimedAt = claimedAt.map(CaptureDateCodec.internetString)
        let uploadDeadlineAt = claimedAt.map { CaptureDateCodec.internetString($0.addingTimeInterval(Self.uploadLeaseInterval)) }
        try storage.withLock { storageState in
            let db = storageState.database
            let sql = """
            UPDATE capture_outbox
            SET state = ?, last_error = ?, retry_count = ?, updated_at = ?, uploaded_at = COALESCE(?, uploaded_at), enriched_at = COALESCE(?, enriched_at),
                upload_claimed_at = ?, upload_deadline_at = ?
            WHERE capture_id = ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare update state")
            }
            defer { sqlite3_finalize(statement) }
            bindText(state.rawValue, index: 1, statement: statement)
            bindOptionalText(lastError, index: 2, statement: statement)
            sqlite3_bind_int(statement, 3, Int32(nextRetryCount))
            bindText(CaptureDateCodec.internetString(Date()), index: 4, statement: statement)
            bindOptionalText(uploadedAt, index: 5, statement: statement)
            bindOptionalText(enrichedAt, index: 6, statement: statement)
            bindOptionalText(uploadClaimedAt, index: 7, statement: statement)
            bindOptionalText(uploadDeadlineAt, index: 8, statement: statement)
            bindText(captureID, index: 9, statement: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(db, context: "update state")
            }
        }
        if let updated = try fetchCapture(captureID: captureID) {
            emit(
                state == .uploadFailed || state == .enrichmentFailed || state == .enrichmentExhausted ? .warning : .info,
                name: "outbox.capture_state_changed",
                message: "Updated local capture state",
                metadata: captureMetadata(
                    for: updated,
                    extra: [
                        "from_state": previous?.state ?? "missing",
                        "to_state": state.rawValue,
                        "mutation": mutation,
                    ]
                )
            )
        } else {
            emit(
                .warning,
                name: "outbox.capture_state_missing_after_update",
                message: "Capture row was missing after state update",
                metadata: [
                    "capture_id": captureID,
                    "from_state": previous?.state ?? "missing",
                    "to_state": state.rawValue,
                    "mutation": mutation,
                ]
            )
        }
    }

    private func fetchCaptures(statement: OpaquePointer?, db: OpaquePointer?) throws -> [LocalCaptureRecord] {
        var captures: [LocalCaptureRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            captures.append(try readCapture(statement: statement))
        }
        let result = sqlite3_errcode(db)
        guard result == SQLITE_DONE else {
            throw sqliteError(db, context: "fetch captures")
        }
        return captures
    }

    private func readCapture(statement: OpaquePointer?) throws -> LocalCaptureRecord {
        let captureID = columnString(statement, index: 0)
        let kind = columnString(statement, index: 1)
        let source = columnString(statement, index: 2)
        let title = columnString(statement, index: 3)
        let textContent = columnString(statement, index: 4)
        let foundURL = columnString(statement, index: 5)
        let capturedAt = try CaptureDateCodec.parseInternetDate(columnString(statement, index: 6))
        let effectiveDay = columnString(statement, index: 7)
        let state = columnString(statement, index: 8)
        let lastError = columnOptionalString(statement, index: 9)
        let retryCount = Int(sqlite3_column_int(statement, 10))
        let manifestJSON = columnBlob(statement, index: 11)
        let blobPath = columnOptionalString(statement, index: 12)
        let blobFilename = columnString(statement, index: 13)
        let blobContentType = columnString(statement, index: 14)
        let blobSize = sqlite3_column_int64(statement, 15)
        let artifactCount = Int(sqlite3_column_int(statement, 16))
        let artifacts = decodeArtifacts(columnBlob(statement, index: 17))
        let createdAt = try CaptureDateCodec.parseInternetDate(columnString(statement, index: 18))
        let updatedAt = try CaptureDateCodec.parseInternetDate(columnString(statement, index: 19))
        let uploadedAt = try columnOptionalString(statement, index: 20).flatMap(CaptureDateCodec.parseInternetDate)
        let enrichedAt = try columnOptionalString(statement, index: 21).flatMap(CaptureDateCodec.parseInternetDate)
        let uploadClaimedAt = try columnOptionalString(statement, index: 22).flatMap(CaptureDateCodec.parseInternetDate)
        let uploadDeadlineAt = try columnOptionalString(statement, index: 23).flatMap(CaptureDateCodec.parseInternetDate)
        let columnCount = Int(sqlite3_column_count(statement))
        let syncAttemptCount = columnCount > 24 ? Int(sqlite3_column_int(statement, 24)) : 0
        let syncNextEligibleAt = try optionalDateColumn(statement: statement, index: 25, availableColumnCount: columnCount)
        let syncFailureClass = columnCount > 26
            ? columnOptionalString(statement, index: 26).flatMap(RelayFailureClass.init(rawValue:))
            : nil
        let syncFailureMessage = columnCount > 27 ? columnOptionalString(statement, index: 27) : nil
        let syncFailureDomain = columnCount > 28 ? columnOptionalString(statement, index: 28) : nil
        let syncFailureCode = columnCount > 29 ? columnOptionalInt(statement, index: 29) : nil
        let syncHTTPStatus = columnCount > 30 ? columnOptionalInt(statement, index: 30) : nil
        let syncQuarantinedAt = try optionalDateColumn(statement: statement, index: 31, availableColumnCount: columnCount)
        return LocalCaptureRecord(
            captureID: captureID,
            kind: kind,
            source: source,
            title: title,
            textContent: textContent,
            foundURL: foundURL,
            capturedAt: capturedAt,
            effectiveDay: effectiveDay,
            state: state,
            lastError: lastError,
            retryCount: retryCount,
            blobFilename: blobFilename,
            blobContentType: blobContentType,
            blobPath: blobPath,
            blobSize: blobSize,
            artifactCount: artifactCount,
            artifacts: artifacts,
            manifestJSON: manifestJSON,
            createdAt: createdAt,
            updatedAt: updatedAt,
            uploadedAt: uploadedAt,
            enrichedAt: enrichedAt,
            uploadClaimedAt: uploadClaimedAt,
            uploadDeadlineAt: uploadDeadlineAt,
            syncAttemptCount: syncAttemptCount,
            syncNextEligibleAt: syncNextEligibleAt,
            syncFailureClass: syncFailureClass,
            syncFailureMessage: syncFailureMessage,
            syncFailureDomain: syncFailureDomain,
            syncFailureCode: syncFailureCode,
            syncHTTPStatus: syncHTTPStatus,
            syncQuarantinedAt: syncQuarantinedAt
        )
    }

    private func optionalDateColumn(
        statement: OpaquePointer?,
        index: Int32,
        availableColumnCount: Int
    ) throws -> Date? {
        guard Int(index) < availableColumnCount else {
            return nil
        }
        return try columnOptionalString(statement, index: index).flatMap(CaptureDateCodec.parseInternetDate)
    }

    private func minDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return min(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private func makeSnapshotCapture(for record: LocalCaptureRecord) -> OutboxSnapshotCapture {
        OutboxSnapshotCapture(
            captureID: record.captureID,
            kind: record.kind,
            source: record.source,
            localState: CaptureLocalState(rawValue: record.state) ?? .declared,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            remoteSyncState: remoteSyncState(for: record)
        )
    }

    private func remoteSyncState(for record: LocalCaptureRecord) -> RemoteSyncState {
        let priority = RelayJobPriority.forCapture(kind: record.kind, source: record.source)

        if let quarantinedAt = record.syncQuarantinedAt {
            return .quarantined(
                QuarantinedRemoteSyncState(
                    priority: priority,
                    attemptCount: record.syncAttemptCount,
                    quarantinedAt: quarantinedAt,
                    failureClass: record.syncFailureClass ?? .permanent,
                    failureMessage: record.syncFailureMessage ?? record.lastError,
                    failureDomain: record.syncFailureDomain,
                    failureCode: record.syncFailureCode,
                    httpStatus: record.syncHTTPStatus
                )
            )
        }

        if let claimedAt = record.uploadClaimedAt,
           let deadline = record.uploadDeadlineAt
        {
            return .uploading(
                ActiveRemoteSyncState(
                    priority: priority,
                    attemptCount: record.syncAttemptCount,
                    lease: UploadLease(claimedAt: claimedAt, deadline: deadline)
                )
            )
        }

        let localState = CaptureLocalState(rawValue: record.state) ?? .declared
        switch localState {
        case .declared, .uploadFailed, .uploading:
            return .pending(
                PendingRemoteSyncState(
                    priority: priority,
                    attemptCount: record.syncAttemptCount,
                    nextEligibleAt: record.syncNextEligibleAt ?? record.updatedAt,
                    lastFailureClass: record.syncFailureClass,
                    lastFailureMessage: record.syncFailureMessage ?? record.lastError,
                    lastFailureDomain: record.syncFailureDomain,
                    lastFailureCode: record.syncFailureCode,
                    lastHTTPStatus: record.syncHTTPStatus
                )
            )
        case .uploaded, .enrichmentPending, .enriched, .enrichmentFailed, .enrichmentExhausted:
            return .none
        }
    }

    private func makeRelayJobRecord(for record: LocalCaptureRecord) -> RelayJobRecord? {
        let priority = RelayJobPriority.forCapture(kind: record.kind, source: record.source)
        switch remoteSyncState(for: record) {
        case .none:
            return nil
        case let .pending(pending):
            return RelayJobRecord(
                captureID: record.captureID,
                priority: priority,
                state: .queued,
                attemptCount: pending.attemptCount,
                nextEligibleAt: pending.nextEligibleAt,
                leaseToken: nil,
                leaseExpiresAt: nil,
                lastFailureClass: pending.lastFailureClass,
                lastFailureMessage: pending.lastFailureMessage,
                lastFailureDomain: pending.lastFailureDomain,
                lastFailureCode: pending.lastFailureCode,
                lastHTTPStatus: pending.lastHTTPStatus,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
        case let .uploading(uploading):
            return RelayJobRecord(
                captureID: record.captureID,
                priority: priority,
                state: .leased,
                attemptCount: uploading.attemptCount,
                nextEligibleAt: uploading.lease.claimedAt,
                leaseToken: CaptureDateCodec.internetString(uploading.lease.claimedAt),
                leaseExpiresAt: uploading.lease.deadline,
                lastFailureClass: nil,
                lastFailureMessage: nil,
                lastFailureDomain: nil,
                lastFailureCode: nil,
                lastHTTPStatus: nil,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
        case let .quarantined(quarantined):
            return RelayJobRecord(
                captureID: record.captureID,
                priority: priority,
                state: .quarantined,
                attemptCount: quarantined.attemptCount,
                nextEligibleAt: quarantined.quarantinedAt,
                leaseToken: nil,
                leaseExpiresAt: nil,
                lastFailureClass: quarantined.failureClass,
                lastFailureMessage: quarantined.failureMessage,
                lastFailureDomain: quarantined.failureDomain,
                lastFailureCode: quarantined.failureCode,
                lastHTTPStatus: quarantined.httpStatus,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
        }
    }

    private func applyClaimUpload(
        captureID: String,
        expectedUpdatedAt: Date,
        attemptCount: Int,
        claimedAt: Date,
        deadline: Date
    ) throws -> Bool {
        try storage.withLock { state in
            let db = state.database
            let sql = """
            UPDATE capture_outbox
            SET state = ?, last_error = NULL, updated_at = ?, upload_claimed_at = ?, upload_deadline_at = ?,
                sync_attempt_count = ?, sync_next_eligible_at = ?, sync_failure_class = NULL, sync_failure_message = NULL,
                sync_failure_domain = NULL, sync_failure_code = NULL, sync_http_status = NULL, sync_quarantined_at = NULL
            WHERE capture_id = ?
              AND state IN (?, ?)
              AND sync_quarantined_at IS NULL
              AND julianday(updated_at) = julianday(?)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare claim upload")
            }
            defer { sqlite3_finalize(statement) }
            bindText(CaptureLocalState.uploading.rawValue, index: 1, statement: statement)
            bindText(CaptureDateCodec.internetString(Date()), index: 2, statement: statement)
            bindText(CaptureDateCodec.internetString(claimedAt), index: 3, statement: statement)
            bindText(CaptureDateCodec.internetString(deadline), index: 4, statement: statement)
            sqlite3_bind_int(statement, 5, Int32(attemptCount))
            bindText(CaptureDateCodec.internetString(claimedAt), index: 6, statement: statement)
            bindText(captureID, index: 7, statement: statement)
            bindText(CaptureLocalState.declared.rawValue, index: 8, statement: statement)
            bindText(CaptureLocalState.uploadFailed.rawValue, index: 9, statement: statement)
            bindText(CaptureDateCodec.internetString(expectedUpdatedAt), index: 10, statement: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(db, context: "claim upload")
            }
            return sqlite3_changes(db) > 0
        }
    }

    private func applyRequeue(
        captureID: String,
        expectedClaimedAt: Date?,
        lifecycleState: CaptureLocalState,
        nextEligibleAt: Date,
        failureClass: RelayFailureClass?,
        failureMessage: String?,
        failureDomain: String?,
        failureCode: Int?,
        httpStatus: Int?
    ) throws -> Bool {
        try storage.withLock { state in
            let db = state.database
            let sql: String
            if expectedClaimedAt != nil {
                sql = """
                UPDATE capture_outbox
                SET state = ?, last_error = ?, updated_at = ?, upload_claimed_at = NULL, upload_deadline_at = NULL,
                    sync_next_eligible_at = ?, sync_failure_class = ?, sync_failure_message = ?, sync_failure_domain = ?,
                    sync_failure_code = ?, sync_http_status = ?, sync_quarantined_at = NULL
                WHERE capture_id = ?
                  AND state = ?
                  AND upload_claimed_at IS NOT NULL
                  AND julianday(upload_claimed_at) = julianday(?)
                """
            } else {
                sql = """
                UPDATE capture_outbox
                SET state = ?, last_error = ?, updated_at = ?, upload_claimed_at = NULL, upload_deadline_at = NULL,
                    sync_next_eligible_at = ?, sync_failure_class = ?, sync_failure_message = ?, sync_failure_domain = ?,
                    sync_failure_code = ?, sync_http_status = ?, sync_quarantined_at = NULL
                WHERE capture_id = ?
                  AND state IN (?, ?)
                  AND sync_quarantined_at IS NULL
                """
            }

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare apply requeue")
            }
            defer { sqlite3_finalize(statement) }

            bindText(lifecycleState.rawValue, index: 1, statement: statement)
            bindOptionalText(failureMessage, index: 2, statement: statement)
            bindText(CaptureDateCodec.internetString(Date()), index: 3, statement: statement)
            bindText(CaptureDateCodec.internetString(nextEligibleAt), index: 4, statement: statement)
            bindOptionalText(failureClass?.rawValue, index: 5, statement: statement)
            bindOptionalText(failureMessage, index: 6, statement: statement)
            bindOptionalText(failureDomain, index: 7, statement: statement)
            bindOptionalInt(failureCode, index: 8, statement: statement)
            bindOptionalInt(httpStatus, index: 9, statement: statement)
            bindText(captureID, index: 10, statement: statement)
            if let expectedClaimedAt {
                bindText(CaptureLocalState.uploading.rawValue, index: 11, statement: statement)
                bindText(CaptureDateCodec.internetString(expectedClaimedAt), index: 12, statement: statement)
            } else {
                bindText(CaptureLocalState.declared.rawValue, index: 11, statement: statement)
                bindText(CaptureLocalState.uploadFailed.rawValue, index: 12, statement: statement)
            }

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(db, context: "apply requeue")
            }
            return sqlite3_changes(db) > 0
        }
    }

    private func applyQuarantine(
        captureID: String,
        expectedClaimedAt: Date?,
        quarantinedAt: Date,
        failureClass: RelayFailureClass,
        failureMessage: String?,
        failureDomain: String?,
        failureCode: Int?,
        httpStatus: Int?
    ) throws -> Bool {
        try storage.withLock { state in
            let db = state.database
            let sql: String
            if expectedClaimedAt != nil {
                sql = """
                UPDATE capture_outbox
                SET state = ?, last_error = ?, updated_at = ?, upload_claimed_at = NULL, upload_deadline_at = NULL,
                    sync_next_eligible_at = NULL, sync_failure_class = ?, sync_failure_message = ?, sync_failure_domain = ?,
                    sync_failure_code = ?, sync_http_status = ?, sync_quarantined_at = ?
                WHERE capture_id = ?
                  AND state = ?
                  AND upload_claimed_at IS NOT NULL
                  AND julianday(upload_claimed_at) = julianday(?)
                """
            } else {
                sql = """
                UPDATE capture_outbox
                SET state = ?, last_error = ?, updated_at = ?, upload_claimed_at = NULL, upload_deadline_at = NULL,
                    sync_next_eligible_at = NULL, sync_failure_class = ?, sync_failure_message = ?, sync_failure_domain = ?,
                    sync_failure_code = ?, sync_http_status = ?, sync_quarantined_at = ?
                WHERE capture_id = ?
                  AND sync_quarantined_at IS NULL
                """
            }

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare apply quarantine")
            }
            defer { sqlite3_finalize(statement) }

            bindText(CaptureLocalState.uploadFailed.rawValue, index: 1, statement: statement)
            bindOptionalText(failureMessage, index: 2, statement: statement)
            bindText(CaptureDateCodec.internetString(Date()), index: 3, statement: statement)
            bindText(failureClass.rawValue, index: 4, statement: statement)
            bindOptionalText(failureMessage, index: 5, statement: statement)
            bindOptionalText(failureDomain, index: 6, statement: statement)
            bindOptionalInt(failureCode, index: 7, statement: statement)
            bindOptionalInt(httpStatus, index: 8, statement: statement)
            bindText(CaptureDateCodec.internetString(quarantinedAt), index: 9, statement: statement)
            bindText(captureID, index: 10, statement: statement)
            if let expectedClaimedAt {
                bindText(CaptureLocalState.uploading.rawValue, index: 11, statement: statement)
                bindText(CaptureDateCodec.internetString(expectedClaimedAt), index: 12, statement: statement)
            }

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(db, context: "apply quarantine")
            }
            return sqlite3_changes(db) > 0
        }
    }

    private func openDatabase() throws {
        try withStateLock { state in
            try FileManager().createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            // File protection must match the CAF + session ledger (.completeUntilFirstUserAuthentication,
            // VoiceCaptureSupport.swift): commitFinalArtifact deliberately commits while the screen is
            // locked (after first unlock), so the outbox DB and its -wal/-shm sidecars must be readable
            // then. Without an explicit class they can resolve to .complete and a locked-device commit
            // fails with SQLITE_IOERR — deferring a commit the design says should succeed. The open flag
            // applies the class atomically to the db file AND its journal/wal/shm (a post-hoc
            // setAttributes would race the sidecars into existence).
            let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
                | SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
            guard sqlite3_open_v2(databaseURL.path, &db, openFlags, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "open capture outbox")
            }
            do {
                guard sqlite3_exec(db, "PRAGMA busy_timeout=5000", nil, nil, nil) == SQLITE_OK else {
                    throw sqliteError(db, context: "set capture outbox busy timeout")
                }
                try enableWALMode(db)
                // Durability: enqueue() returns the LocalCommitReceipt that backs the "Saved" claim
                // (INVARIANTS §2 — claims derive from durable facts). Under WAL the default
                // synchronous=NORMAL can lose the last committed transaction on power loss / OS crash,
                // so a row the UI already called "Saved" could vanish. FULL fsyncs the WAL at commit,
                // making the receipt durable across power loss — the one thing this build must never break.
                guard sqlite3_exec(db, "PRAGMA synchronous=FULL", nil, nil, nil) == SQLITE_OK else {
                    throw sqliteError(db, context: "set capture outbox synchronous")
                }
            } catch {
                sqlite3_close(db)
                throw error
            }
            state.database = db
        }
    }

    private func enableWALMode(_ db: OpaquePointer?) throws {
        let maxAttempts = 12
        for attempt in 0 ..< maxAttempts {
            let result = sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            if result == SQLITE_OK {
                return
            }
            if result != SQLITE_BUSY && result != SQLITE_LOCKED {
                defer { sqlite3_close(db) }
                throw sqliteError(db, context: "enable capture outbox wal")
            }
            usleep(useconds_t(50_000 * (attempt + 1)))
        }
        defer { sqlite3_close(db) }
        throw sqliteError(db, context: "enable capture outbox wal")
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS capture_outbox (
            capture_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            source TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            text_content TEXT NOT NULL DEFAULT '',
            found_url TEXT NOT NULL DEFAULT '',
            captured_at TEXT NOT NULL,
            effective_day TEXT NOT NULL,
            state TEXT NOT NULL,
            last_error TEXT,
            retry_count INTEGER NOT NULL DEFAULT 0,
            manifest_json BLOB NOT NULL,
            blob_path TEXT,
            blob_filename TEXT NOT NULL DEFAULT '',
            blob_content_type TEXT NOT NULL DEFAULT '',
            blob_size INTEGER NOT NULL DEFAULT 0,
            artifact_count INTEGER NOT NULL DEFAULT 0,
            artifacts_json BLOB NOT NULL DEFAULT X'5B5D',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            uploaded_at TEXT,
            enriched_at TEXT,
            upload_claimed_at TEXT,
            upload_deadline_at TEXT,
            sync_attempt_count INTEGER NOT NULL DEFAULT 0,
            sync_next_eligible_at TEXT,
            sync_failure_class TEXT,
            sync_failure_message TEXT,
            sync_failure_domain TEXT,
            sync_failure_code INTEGER,
            sync_http_status INTEGER,
            sync_quarantined_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_capture_outbox_state_created ON capture_outbox(state, created_at);
        CREATE INDEX IF NOT EXISTS idx_capture_outbox_updated ON capture_outbox(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_capture_outbox_sync_pending ON capture_outbox(state, sync_quarantined_at, sync_next_eligible_at, created_at);
        CREATE INDEX IF NOT EXISTS idx_capture_outbox_sync_deadline ON capture_outbox(state, upload_deadline_at);
        CREATE TABLE IF NOT EXISTS relay_worker_state (
            singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
            auth_paused INTEGER NOT NULL DEFAULT 0,
            auth_pause_message TEXT,
            last_successful_upload_at TEXT,
            last_successful_capture_id TEXT,
            last_poll_at TEXT,
            last_poll_reason TEXT
        );
        """
        try storage.withLock { state in
            let db = state.database
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "migrate capture outbox")
            }
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN found_url TEXT NOT NULL DEFAULT ''",
                context: "migrate capture outbox add found_url",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN artifacts_json BLOB NOT NULL DEFAULT X'5B5D'",
                context: "migrate capture outbox add artifacts_json",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0",
                context: "migrate capture outbox add retry_count",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN upload_claimed_at TEXT",
                context: "migrate capture outbox add upload_claimed_at",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN upload_deadline_at TEXT",
                context: "migrate capture outbox add upload_deadline_at",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN sync_attempt_count INTEGER NOT NULL DEFAULT 0",
                context: "migrate capture outbox add sync_attempt_count",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN sync_next_eligible_at TEXT",
                context: "migrate capture outbox add sync_next_eligible_at",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN sync_failure_class TEXT",
                context: "migrate capture outbox add sync_failure_class",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN sync_failure_message TEXT",
                context: "migrate capture outbox add sync_failure_message",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN sync_failure_domain TEXT",
                context: "migrate capture outbox add sync_failure_domain",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN sync_failure_code INTEGER",
                context: "migrate capture outbox add sync_failure_code",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN sync_http_status INTEGER",
                context: "migrate capture outbox add sync_http_status",
                db: db
            )
            try addColumnIfNeeded(
                "ALTER TABLE capture_outbox ADD COLUMN sync_quarantined_at TEXT",
                context: "migrate capture outbox add sync_quarantined_at",
                db: db
            )
            try migrateLegacyRelayJobsIfNeeded(db: db)
            try normalizeRelaySyncState(db: db)
            try ensureRelayWorkerStateRow(db: db)
        }
    }

    private func withStateLock<T>(_ body: (inout sending State) throws -> sending T) rethrows -> sending T {
        try storage.withLock(body)
    }

    private func bindText(_ value: String, index: Int32, statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalText(_ value: String?, index: Int32, statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindText(value, index: index, statement: statement)
    }

    private func bindBlob(_ value: Data, index: Int32, statement: OpaquePointer?) {
        _ = value.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(statement, index, rawBuffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
        }
    }

    private func bindInt64(_ value: Int64, index: Int32, statement: OpaquePointer?) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func bindOptionalInt(_ value: Int?, index: Int32, statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    private func sqliteError(_ db: OpaquePointer?, context: String) -> CaptureOutboxError {
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
        return .sqlite("\(context): \(message)")
    }

    private static func isUnreadableURLGhost(_ record: CaptureServerRecord) -> Bool {
        record.kind == "url" &&
            (record.foundURL ?? "").isEmpty &&
            (record.blobContentType ?? "") == "application/macbinary"
    }

    private func addColumnIfNeeded(_ sql: String, context: String, db: OpaquePointer?) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            return
        }
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? ""
        if message.localizedCaseInsensitiveContains("duplicate column name") {
            return
        }
        throw sqliteError(db, context: context)
    }

    private func tableExists(_ name: String, db: OpaquePointer?) -> Bool {
        let sql = """
        SELECT 1
        FROM sqlite_master
        WHERE type = 'table'
          AND name = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        bindText(name, index: 1, statement: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func ensureRelayWorkerStateRow(db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO relay_worker_state (
            singleton_id,
            auth_paused,
            auth_pause_message,
            last_successful_upload_at,
            last_successful_capture_id,
            last_poll_at,
            last_poll_reason
        ) VALUES (1, 0, NULL, NULL, NULL, NULL, NULL)
        ON CONFLICT(singleton_id) DO NOTHING
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db, context: "ensure relay worker state row")
        }
    }

    private func migrateLegacyRelayJobsIfNeeded(db: OpaquePointer?) throws {
        guard tableExists("relay_jobs", db: db) else {
            return
        }

        struct LegacyRelayJobMigrationRow {
            let captureID: String
            let state: RelayJobState
            let attemptCount: Int
            let nextEligibleAt: Date?
            let leaseExpiresAt: Date?
            let lastFailureClass: RelayFailureClass?
            let lastFailureMessage: String?
            let lastFailureDomain: String?
            let lastFailureCode: Int?
            let lastHTTPStatus: Int?
            let updatedAt: Date
        }

        let rows: [LegacyRelayJobMigrationRow] = try {
            let sql = """
            SELECT capture_id, state, attempt_count, next_eligible_at, lease_expires_at, last_failure_class,
                   last_failure_message, last_failure_domain, last_failure_code, last_http_status, updated_at
            FROM relay_jobs
            ORDER BY created_at ASC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare legacy relay job migration scan")
            }
            defer { sqlite3_finalize(statement) }

            var rows: [LegacyRelayJobMigrationRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    LegacyRelayJobMigrationRow(
                        captureID: columnString(statement, index: 0),
                        state: RelayJobState(rawValue: columnString(statement, index: 1)) ?? .queued,
                        attemptCount: Int(sqlite3_column_int(statement, 2)),
                        nextEligibleAt: try columnOptionalString(statement, index: 3).flatMap(CaptureDateCodec.parseInternetDate),
                        leaseExpiresAt: try columnOptionalString(statement, index: 4).flatMap(CaptureDateCodec.parseInternetDate),
                        lastFailureClass: columnOptionalString(statement, index: 5).flatMap(RelayFailureClass.init(rawValue:)),
                        lastFailureMessage: columnOptionalString(statement, index: 6),
                        lastFailureDomain: columnOptionalString(statement, index: 7),
                        lastFailureCode: columnOptionalInt(statement, index: 8),
                        lastHTTPStatus: columnOptionalInt(statement, index: 9),
                        updatedAt: try CaptureDateCodec.parseInternetDate(columnString(statement, index: 10))
                    )
                )
            }
            let result = sqlite3_errcode(db)
            guard result == SQLITE_DONE else {
                throw sqliteError(db, context: "legacy relay job migration scan")
            }
            return rows
        }()

        try beginImmediateTransaction(db: db)
        do {
            let updateSQL = """
            UPDATE capture_outbox
            SET state = ?, last_error = ?, upload_claimed_at = ?, upload_deadline_at = ?, sync_attempt_count = ?,
                sync_next_eligible_at = ?, sync_failure_class = ?, sync_failure_message = ?, sync_failure_domain = ?,
                sync_failure_code = ?, sync_http_status = ?, sync_quarantined_at = ?
            WHERE capture_id = ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare legacy relay job migration update")
            }
            defer { sqlite3_finalize(statement) }

            var migratedCount = 0
            for row in rows {
                guard let existing = try fetchCapture(captureID: row.captureID, db: db) else {
                    throw CaptureOutboxError.sqlite("legacy relay job migration missing capture: \(row.captureID)")
                }

                let nextState: CaptureLocalState
                let claimedAt: Date?
                let deadlineAt: Date?
                let nextEligibleAt: Date?
                let quarantinedAt: Date?
                let lastError: String?

                switch row.state {
                case .queued:
                    nextState = existing.state == CaptureLocalState.uploadFailed.rawValue ? .uploadFailed : .declared
                    claimedAt = nil
                    deadlineAt = nil
                    nextEligibleAt = row.nextEligibleAt ?? existing.updatedAt
                    quarantinedAt = nil
                    lastError = row.lastFailureMessage ?? existing.lastError
                case .leased:
                    nextState = .uploading
                    deadlineAt = row.leaseExpiresAt
                    claimedAt = row.leaseExpiresAt?.addingTimeInterval(-Self.uploadLeaseInterval)
                    nextEligibleAt = claimedAt ?? row.nextEligibleAt ?? existing.updatedAt
                    quarantinedAt = nil
                    lastError = existing.lastError
                case .quarantined:
                    nextState = .uploadFailed
                    claimedAt = nil
                    deadlineAt = nil
                    nextEligibleAt = nil
                    quarantinedAt = row.updatedAt
                    lastError = row.lastFailureMessage ?? existing.lastError
                }

                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindText(nextState.rawValue, index: 1, statement: statement)
                bindOptionalText(lastError, index: 2, statement: statement)
                bindOptionalText(claimedAt.map(CaptureDateCodec.internetString), index: 3, statement: statement)
                bindOptionalText(deadlineAt.map(CaptureDateCodec.internetString), index: 4, statement: statement)
                sqlite3_bind_int(statement, 5, Int32(row.attemptCount))
                bindOptionalText(nextEligibleAt.map(CaptureDateCodec.internetString), index: 6, statement: statement)
                bindOptionalText(row.lastFailureClass?.rawValue, index: 7, statement: statement)
                bindOptionalText(row.lastFailureMessage, index: 8, statement: statement)
                bindOptionalText(row.lastFailureDomain, index: 9, statement: statement)
                bindOptionalInt(row.lastFailureCode, index: 10, statement: statement)
                bindOptionalInt(row.lastHTTPStatus, index: 11, statement: statement)
                bindOptionalText(quarantinedAt.map(CaptureDateCodec.internetString), index: 12, statement: statement)
                bindText(row.captureID, index: 13, statement: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError(db, context: "legacy relay job migration update")
                }
                migratedCount += 1
            }

            guard migratedCount == rows.count else {
                throw CaptureOutboxError.sqlite("legacy relay job migration row count mismatch")
            }
            try dropLegacyRelayJobsTable(db: db)
            try commitTransaction(db: db)
        } catch {
            try? rollbackTransaction(db: db)
            throw error
        }
    }

    private func normalizeRelaySyncState(db: OpaquePointer?) throws {
        let sql = """
        SELECT capture_id, kind, source, title, text_content, found_url, captured_at, effective_day, state, last_error,
               retry_count, manifest_json, blob_path, blob_filename, blob_content_type, blob_size, artifact_count, artifacts_json,
               created_at, updated_at, uploaded_at, enriched_at, upload_claimed_at, upload_deadline_at,
               sync_attempt_count, sync_next_eligible_at, sync_failure_class, sync_failure_message, sync_failure_domain,
               sync_failure_code, sync_http_status, sync_quarantined_at
        FROM capture_outbox
        WHERE state IN ('declared', 'uploading', 'upload_failed')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db, context: "prepare normalize relay sync state")
        }
        defer { sqlite3_finalize(statement) }
        let records = try fetchCaptures(statement: statement, db: db)

        try beginImmediateTransaction(db: db)
        do {
            let updateSQL = """
            UPDATE capture_outbox
            SET state = ?, upload_claimed_at = ?, upload_deadline_at = ?, sync_attempt_count = ?, sync_next_eligible_at = ?,
                sync_failure_class = ?, sync_failure_message = ?, sync_failure_domain = ?, sync_failure_code = ?,
                sync_http_status = ?, sync_quarantined_at = ?, last_error = ?
            WHERE capture_id = ?
            """
            var updateStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare normalize relay sync state update")
            }
            defer { sqlite3_finalize(updateStatement) }

            for record in records {
                let localState = CaptureLocalState(rawValue: record.state) ?? .declared
                let normalizedAttemptCount = max(record.syncAttemptCount, record.retryCount)
                let normalizedFailureClass: RelayFailureClass?
                let normalizedFailureMessage: String?
                let normalizedClaimedAt: Date?
                let normalizedDeadlineAt: Date?
                let normalizedNextEligibleAt: Date?
                let normalizedQuarantinedAt: Date?
                let normalizedState: CaptureLocalState

                if let syncQuarantinedAt = record.syncQuarantinedAt {
                    normalizedState = .uploadFailed
                    normalizedClaimedAt = nil
                    normalizedDeadlineAt = nil
                    normalizedNextEligibleAt = nil
                    normalizedQuarantinedAt = syncQuarantinedAt
                    normalizedFailureClass = record.syncFailureClass ?? .permanent
                    normalizedFailureMessage = record.syncFailureMessage ?? record.lastError
                } else if localState == .uploading,
                          let claimedAt = record.uploadClaimedAt,
                          let deadlineAt = record.uploadDeadlineAt
                {
                    normalizedState = .uploading
                    normalizedClaimedAt = claimedAt
                    normalizedDeadlineAt = deadlineAt
                    normalizedNextEligibleAt = record.syncNextEligibleAt ?? claimedAt
                    normalizedQuarantinedAt = nil
                    normalizedFailureClass = record.syncFailureClass
                    normalizedFailureMessage = record.syncFailureMessage
                } else {
                    normalizedState = localState == .uploadFailed ? .uploadFailed : .declared
                    normalizedClaimedAt = nil
                    normalizedDeadlineAt = nil
                    normalizedNextEligibleAt = record.syncNextEligibleAt ?? record.updatedAt
                    normalizedQuarantinedAt = nil
                    normalizedFailureClass = record.syncFailureClass ?? (normalizedState == .uploadFailed ? .transient : nil)
                    normalizedFailureMessage = record.syncFailureMessage ?? (normalizedState == .uploadFailed ? record.lastError : nil)
                }

                sqlite3_reset(updateStatement)
                sqlite3_clear_bindings(updateStatement)
                bindText(normalizedState.rawValue, index: 1, statement: updateStatement)
                bindOptionalText(normalizedClaimedAt.map(CaptureDateCodec.internetString), index: 2, statement: updateStatement)
                bindOptionalText(normalizedDeadlineAt.map(CaptureDateCodec.internetString), index: 3, statement: updateStatement)
                sqlite3_bind_int(updateStatement, 4, Int32(normalizedAttemptCount))
                bindOptionalText(normalizedNextEligibleAt.map(CaptureDateCodec.internetString), index: 5, statement: updateStatement)
                bindOptionalText(normalizedFailureClass?.rawValue, index: 6, statement: updateStatement)
                bindOptionalText(normalizedFailureMessage, index: 7, statement: updateStatement)
                bindOptionalText(record.syncFailureDomain, index: 8, statement: updateStatement)
                bindOptionalInt(record.syncFailureCode, index: 9, statement: updateStatement)
                bindOptionalInt(record.syncHTTPStatus, index: 10, statement: updateStatement)
                bindOptionalText(normalizedQuarantinedAt.map(CaptureDateCodec.internetString), index: 11, statement: updateStatement)
                bindOptionalText(normalizedFailureMessage ?? record.lastError, index: 12, statement: updateStatement)
                bindText(record.captureID, index: 13, statement: updateStatement)
                guard sqlite3_step(updateStatement) == SQLITE_DONE else {
                    throw sqliteError(db, context: "normalize relay sync state update")
                }
            }

            try commitTransaction(db: db)
        } catch {
            try? rollbackTransaction(db: db)
            throw error
        }
    }

    private func dropLegacyRelayJobsTable(db: OpaquePointer?) throws {
        let sql = """
        DROP INDEX IF EXISTS idx_relay_jobs_state_eligibility;
        DROP INDEX IF EXISTS idx_relay_jobs_lease_expires;
        DROP TABLE IF EXISTS relay_jobs;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db, context: "drop legacy relay_jobs")
        }
    }

    private func fetchRelayWorkerState(db: OpaquePointer?) throws -> RelayWorkerState {
        try ensureRelayWorkerStateRow(db: db)
        let sql = """
        SELECT auth_paused, auth_pause_message, last_successful_upload_at, last_successful_capture_id, last_poll_at, last_poll_reason
        FROM relay_worker_state
        WHERE singleton_id = 1
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db, context: "prepare fetch relay worker state")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return .initial
        }
        return RelayWorkerState(
            authPaused: sqlite3_column_int(statement, 0) != 0,
            authPauseMessage: columnOptionalString(statement, index: 1),
            lastSuccessfulUploadAt: try columnOptionalString(statement, index: 2).flatMap(CaptureDateCodec.parseInternetDate),
            lastSuccessfulCaptureID: columnOptionalString(statement, index: 3),
            lastPollAt: try columnOptionalString(statement, index: 4).flatMap(CaptureDateCodec.parseInternetDate),
            lastPollReason: columnOptionalString(statement, index: 5)
        )
    }

    private func upsertRelayWorkerState(
        db: OpaquePointer?,
        authPaused: Bool?,
        authPauseMessage: String?,
        lastSuccessfulUploadAt: Date?,
        lastSuccessfulCaptureID: String?,
        lastPollAt: Date?,
        lastPollReason: String?
    ) throws {
        try ensureRelayWorkerStateRow(db: db)
        let current = try fetchRelayWorkerState(db: db)
        let resolvedAuthPaused = authPaused ?? current.authPaused
        let resolvedAuthPauseMessage = authPaused == nil ? current.authPauseMessage : authPauseMessage
        let resolvedLastSuccessfulUploadAt = lastSuccessfulUploadAt ?? current.lastSuccessfulUploadAt
        let resolvedLastSuccessfulCaptureID = lastSuccessfulCaptureID ?? current.lastSuccessfulCaptureID
        let resolvedLastPollAt = lastPollAt ?? current.lastPollAt
        let resolvedLastPollReason = lastPollReason ?? current.lastPollReason
        let sql = """
        UPDATE relay_worker_state
        SET auth_paused = ?, auth_pause_message = ?, last_successful_upload_at = ?, last_successful_capture_id = ?, last_poll_at = ?, last_poll_reason = ?
        WHERE singleton_id = 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db, context: "prepare upsert relay worker state")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, resolvedAuthPaused ? 1 : 0)
        bindOptionalText(resolvedAuthPauseMessage, index: 2, statement: statement)
        bindOptionalText(resolvedLastSuccessfulUploadAt.map(CaptureDateCodec.internetString), index: 3, statement: statement)
        bindOptionalText(resolvedLastSuccessfulCaptureID, index: 4, statement: statement)
        bindOptionalText(resolvedLastPollAt.map(CaptureDateCodec.internetString), index: 5, statement: statement)
        bindOptionalText(resolvedLastPollReason, index: 6, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(db, context: "upsert relay worker state")
        }
    }

    private func beginImmediateTransaction(db: OpaquePointer?) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db, context: "begin immediate transaction")
        }
    }

    private func commitTransaction(db: OpaquePointer?) throws {
        guard sqlite3_exec(db, "COMMIT TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db, context: "commit transaction")
        }
    }

    private func rollbackTransaction(db: OpaquePointer?) throws {
        guard sqlite3_exec(db, "ROLLBACK TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db, context: "rollback transaction")
        }
    }

    private func countCaptures(in states: [CaptureLocalState]) throws -> Int {
        guard !states.isEmpty else {
            return 0
        }
        return try storage.withLock { state in
            let db = state.database
            let placeholders = Array(repeating: "?", count: states.count).joined(separator: ", ")
            let sql = """
            SELECT COUNT(*)
            FROM capture_outbox
            WHERE state IN (\(placeholders))
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare capture count")
            }
            defer { sqlite3_finalize(statement) }
            for (offset, state) in states.enumerated() {
                bindText(state.rawValue, index: Int32(offset + 1), statement: statement)
            }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(db, context: "capture count")
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func captureIDsMatchingUploadingLeaseExpiry(before now: Date) throws -> [String] {
        try storage.withLock { state in
            let db = state.database
            let sql = """
            SELECT capture_id
            FROM capture_outbox
            WHERE state = ?
              AND upload_deadline_at IS NOT NULL
              AND upload_deadline_at < ?
            ORDER BY created_at ASC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare expired uploading capture ids")
            }
            defer { sqlite3_finalize(statement) }
            bindText(CaptureLocalState.uploading.rawValue, index: 1, statement: statement)
            bindText(CaptureDateCodec.internetString(now), index: 2, statement: statement)

            var captureIDs: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                captureIDs.append(columnString(statement, index: 0))
            }
            let result = sqlite3_errcode(db)
            guard result == SQLITE_DONE else {
                throw sqliteError(db, context: "expired uploading capture ids")
            }
            return captureIDs
        }
    }

    private func uploadingCaptureIDs(excluding captureIDsToKeep: Set<String>) throws -> [String] {
        try storage.withLock { state in
            let db = state.database
            let sql = """
            SELECT capture_id
            FROM capture_outbox
            WHERE state = ?
            ORDER BY created_at ASC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare uploading capture ids")
            }
            defer { sqlite3_finalize(statement) }
            bindText(CaptureLocalState.uploading.rawValue, index: 1, statement: statement)

            var captureIDs: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let captureID = columnString(statement, index: 0)
                if !captureIDsToKeep.contains(captureID) {
                    captureIDs.append(captureID)
                }
            }
            let result = sqlite3_errcode(db)
            guard result == SQLITE_DONE else {
                throw sqliteError(db, context: "uploading capture ids")
            }
            return captureIDs
        }
    }

    @discardableResult
    private func resetUploadingToDeclared(
        captureIDs: [String],
        lastError: String,
        mutation: String
    ) throws -> [String] {
        guard !captureIDs.isEmpty else {
            return []
        }
        var updatedCaptureIDs: [String] = []
        try storage.withLock { state in
            let db = state.database
            let sql = """
            UPDATE capture_outbox
            SET state = ?, last_error = ?, updated_at = ?, upload_claimed_at = NULL, upload_deadline_at = NULL
            WHERE capture_id = ?
              AND state = ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, context: "prepare reset uploading to declared")
            }
            defer { sqlite3_finalize(statement) }

            let updatedAt = CaptureDateCodec.internetString(Date())
            for captureID in captureIDs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindText(CaptureLocalState.declared.rawValue, index: 1, statement: statement)
                bindText(lastError, index: 2, statement: statement)
                bindText(updatedAt, index: 3, statement: statement)
                bindText(captureID, index: 4, statement: statement)
                bindText(CaptureLocalState.uploading.rawValue, index: 5, statement: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError(db, context: "reset uploading to declared")
                }
                if sqlite3_changes(db) > 0 {
                    updatedCaptureIDs.append(captureID)
                }
            }
        }
        guard !updatedCaptureIDs.isEmpty else {
            return []
        }
        emit(
            .warning,
            name: "outbox.uploading_reset_to_declared",
            message: "Reset uploading captures back to declared",
            metadata: [
                "mutation": mutation,
                "updated_count": "\(updatedCaptureIDs.count)",
                "capture_ids": updatedCaptureIDs.joined(separator: ","),
                "last_error": lastError,
            ]
        )
        return updatedCaptureIDs
    }

    private func captureMetadata(for record: LocalCaptureRecord, extra: [String: String] = [:]) -> [String: String] {
        var metadata = extra
        metadata["capture_id"] = record.captureID
        metadata["kind"] = record.kind
        metadata["source"] = record.source
        metadata["state"] = record.state
        metadata["retry_count"] = "\(record.retryCount)"
        metadata["artifact_count"] = "\(record.artifactCount)"
        metadata["blob_filename"] = record.blobFilename
        metadata["blob_size"] = "\(record.blobSize)"
        metadata["text_length"] = "\(record.textContent.count)"
        if !record.foundURL.isEmpty {
            metadata["found_url"] = record.foundURL
        }
        if let lastError = record.lastError, !lastError.isEmpty {
            metadata["last_error"] = lastError
        }
        if let uploadClaimedAt = record.uploadClaimedAt {
            metadata["upload_claimed_at"] = CaptureDateCodec.internetString(uploadClaimedAt)
        }
        if let uploadDeadlineAt = record.uploadDeadlineAt {
            metadata["upload_deadline_at"] = CaptureDateCodec.internetString(uploadDeadlineAt)
        }
        return metadata
    }

    private func emit(
        _ level: CaptureDebugLevel,
        name: String,
        message: String,
        metadata: [String: String]
    ) {
        CaptureDebugRecorder.appendDirect(
            level,
            name: name,
            message: message,
            metadata: metadata,
            appGroupRoot: appGroupRoot
        )
    }

    private func columnString(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: text)
    }

    private func columnOptionalString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return columnString(statement, index: index)
    }

    private func columnOptionalInt(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
    }

    private func columnBlob(_ statement: OpaquePointer?, index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    private func encodeArtifacts(_ artifacts: [CaptureServerArtifact]) throws -> Data {
        try JSONEncoder().encode(artifacts)
    }

    private func decodeArtifacts(_ data: Data) -> [CaptureServerArtifact] {
        guard !data.isEmpty else {
            return []
        }
        return (try? JSONDecoder().decode([CaptureServerArtifact].self, from: data)) ?? []
    }
}

enum CaptureManifestPreparer {
    static func prepare(
        manifestJSON: String,
        deviceID: String,
        blob: CaptureBlobPayload?,
        sourceSurface: String? = nil,
        supplementalContext: [String: Any] = [:]
    ) throws -> PreparedCapture {
        let normalizedManifest = manifestJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : manifestJSON
        guard let data = normalizedManifest.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CaptureOutboxError.invalidManifest
        }
        return try prepare(
            manifestObject: object,
            deviceID: deviceID,
            blob: blob,
            sourceSurface: sourceSurface,
            supplementalContext: supplementalContext
        )
    }

    static func prepare(
        manifestObject: [String: Any],
        deviceID: String,
        blob: CaptureBlobPayload?,
        sourceSurface: String? = nil,
        supplementalContext: [String: Any] = [:]
    ) throws -> PreparedCapture {
        var source = manifestObject
        let capturedAt = parseTimestamp(source["captured_at"]) ?? parseTimestamp(source["timestamp"]) ?? Date()
        let captureID = firstString(in: source, keys: ["capture_id"]) ?? deriveCaptureID(source: source, blob: blob, capturedAt: capturedAt)
        let kind = firstString(in: source, keys: ["kind", "type"]) ?? "capture"
        // Seam cut (AppIntents): Serein fell back to "shortcut_app_intent" — its intent
        // surface. No intent surface is ported in foreground-only P0, so the fallback is
        // the native recorder surface (the only P0 producer). Evidence: Vo-Cal AGENTS.md
        // foreground-only master decision; phase plan C1 seam list.
        let sourceLabel = firstString(in: source, keys: ["source"]) ?? sourceSurface ?? CaptureSourceSurface.nativeRecorder.rawValue
        let effectiveDay = firstString(in: source, keys: ["effective_day"]) ?? CaptureDateCodec.dayString(capturedAt)
        let title = firstString(in: source, keys: ["title", "item_name"]) ?? ""
        let textContent = firstString(in: source, keys: ["text_content", "dictation"]) ?? ""
        let foundURL = firstString(in: source, keys: ["found_url"]) ?? ""
        var context = dictionary(in: source, key: "context") ?? [:]
        deepMergeMissing(into: &context, from: supplementalContext)
        source["schema"] = "vocal.capture.v1"
        source["capture_id"] = captureID
        source["kind"] = kind
        source["source"] = sourceLabel
        if let sourceSurface, firstString(in: source, keys: ["source_surface"]) == nil {
            source["source_surface"] = sourceSurface
        }
        source["captured_at"] = CaptureDateCodec.internetString(capturedAt)
        source["effective_day"] = effectiveDay
        source["device_id"] = firstString(in: source, keys: ["device_id"]) ?? deviceID
        if !foundURL.isEmpty {
            source["found_url"] = foundURL
        }
        if !context.isEmpty {
            source["context"] = context
        }
        if let blob {
            source["blob_filename"] = blob.filename
            source["blob_content_type"] = blob.contentType
        }
        let normalized = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])
        return PreparedCapture(
            captureID: captureID,
            kind: kind,
            source: sourceLabel,
            title: title,
            textContent: textContent,
            foundURL: foundURL,
            capturedAt: capturedAt,
            effectiveDay: effectiveDay,
            blobFilename: blob?.filename ?? "",
            blobContentType: blob?.contentType ?? "",
            manifestJSON: normalized
        )
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try? CaptureDateCodec.parseInternetDate(value)
    }

    private static func deriveCaptureID(source: [String: Any], blob: CaptureBlobPayload?, capturedAt: Date) -> String {
        let base = firstString(in: source, keys: ["blob", "blobs"]) ??
            blob
                .map { ($0.filename as NSString).deletingPathExtension }
                .flatMap { $0.isEmpty ? nil : $0 } ??
            "cap"
        let suffix = "\(CaptureDateCodec.captureIDTimestamp(capturedAt))_\(UUID().uuidString.lowercased().prefix(6))"
        return sanitizeCaptureID("\(base)_\(suffix)")
    }

    private static func sanitizeCaptureID(_ value: String) -> String {
        let lowered = value.lowercased()
        let allowed = lowered.map { character -> Character in
            switch character {
            case "a"..."z", "0"..."9", "_", "-":
                return character
            default:
                return "_"
            }
        }
        let sanitized = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitized.isEmpty ? "cap_\(CaptureDateCodec.captureIDTimestamp(Date()))" : sanitized
    }

    private static func dictionary(in source: [String: Any], key: String) -> [String: Any]? {
        source[key] as? [String: Any]
    }

    private static func deepMergeMissing(into target: inout [String: Any], from source: [String: Any]) {
        for (key, value) in source {
            if var existingNested = target[key] as? [String: Any],
               let nested = value as? [String: Any]
            {
                deepMergeMissing(into: &existingNested, from: nested)
                target[key] = existingNested
                continue
            }
            if target[key] == nil {
                target[key] = value
            }
        }
    }

    private static func firstString(in source: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = source[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

typealias CaptureDateCodec = VoCalCapture.CaptureDateCodec

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
