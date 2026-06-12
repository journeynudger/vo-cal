import Foundation

public enum CaptureLocalState: String, Sendable, Codable, CaseIterable {
    case declared
    case uploading
    case uploaded
    case enrichmentPending = "enrichment_pending"
    case enriched
    case enrichmentFailed = "enrichment_failed"
    case enrichmentExhausted = "enrichment_exhausted"
    case uploadFailed = "upload_failed"
}

public struct CaptureServerArtifact: Codable, Sendable, Equatable {
    public let artifactKind: String
    public let provider: String
    public let status: String
    public let textContent: String?
    public let payload: CaptureJSONValue?
    public let lastError: String?
    public let retryCount: Int
    public let nextAttemptAt: Date?

    enum CodingKeys: String, CodingKey {
        case artifactKind = "artifact_kind"
        case provider
        case status
        case textContent = "text_content"
        case payload
        case lastError = "last_error"
        case retryCount = "retry_count"
        case nextAttemptAt = "next_attempt_at"
    }

    public init(
        artifactKind: String,
        provider: String,
        status: String,
        textContent: String? = nil,
        payload: CaptureJSONValue? = nil,
        lastError: String? = nil,
        retryCount: Int = 0,
        nextAttemptAt: Date? = nil
    ) {
        self.artifactKind = artifactKind
        self.provider = provider
        self.status = status
        self.textContent = textContent
        self.payload = payload
        self.lastError = lastError
        self.retryCount = retryCount
        self.nextAttemptAt = nextAttemptAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artifactKind = try container.decodeIfPresent(String.self, forKey: .artifactKind) ?? ""
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        textContent = try container.decodeIfPresent(String.self, forKey: .textContent)
        payload = try container.decodeIfPresent(CaptureJSONValue.self, forKey: .payload)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        nextAttemptAt = try? container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
    }
}

public struct CaptureServerRecord: Codable, Sendable, Equatable, Identifiable {
    public let seq: Int64
    public let captureID: String
    public let kind: String
    public let source: String
    public let title: String?
    public let textContent: String?
    public let foundURL: String?
    public let capturedAt: Date
    public let effectiveDay: String
    public let state: String
    public let lastError: String?
    public let blobFilename: String?
    public let blobContentType: String?
    public let createdAt: Date
    public let enrichedAt: Date?
    public let artifacts: [CaptureServerArtifact]

    public var id: String { captureID }

    enum CodingKeys: String, CodingKey {
        case seq
        case captureID = "capture_id"
        case kind
        case source
        case title
        case textContent = "text_content"
        case foundURL = "found_url"
        case capturedAt = "captured_at"
        case effectiveDay = "effective_day"
        case state
        case lastError = "last_error"
        case blobFilename = "blob_filename"
        case blobContentType = "blob_content_type"
        case createdAt = "created_at"
        case enrichedAt = "enriched_at"
        case artifacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decodeIfPresent(Int64.self, forKey: .seq) ?? 0
        captureID = try container.decode(String.self, forKey: .captureID)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "capture"
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title)
        textContent = try container.decodeIfPresent(String.self, forKey: .textContent)
        foundURL = try container.decodeIfPresent(String.self, forKey: .foundURL)
        capturedAt = (try? container.decode(Date.self, forKey: .capturedAt)) ?? Date()
        effectiveDay = try container.decodeIfPresent(String.self, forKey: .effectiveDay) ?? CaptureDateCodec.dayString(capturedAt)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? CaptureLocalState.declared.rawValue
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        blobFilename = try container.decodeIfPresent(String.self, forKey: .blobFilename)
        blobContentType = try container.decodeIfPresent(String.self, forKey: .blobContentType)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? capturedAt
        enrichedAt = try? container.decodeIfPresent(Date.self, forKey: .enrichedAt)
        artifacts = try container.decodeIfPresent([CaptureServerArtifact].self, forKey: .artifacts) ?? []
    }
}

public struct CaptureListResponse: Codable, Sendable {
    public let captures: [CaptureServerRecord]
    public let nextAfter: Int64?

    enum CodingKeys: String, CodingKey {
        case captures
        case nextAfter = "next_after"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captures = try container.decodeIfPresent([CaptureServerRecord].self, forKey: .captures) ?? []
        nextAfter = try container.decodeIfPresent(Int64.self, forKey: .nextAfter)
    }
}

public struct LocalCaptureRecord: Identifiable, Equatable, Sendable {
    public let captureID: String
    public let kind: String
    public let source: String
    public let title: String
    public let textContent: String
    public let foundURL: String
    public let capturedAt: Date
    public let effectiveDay: String
    public let state: String
    public let lastError: String?
    public let retryCount: Int
    public let blobFilename: String
    public let blobContentType: String
    public let blobPath: String?
    public let blobSize: Int64
    public let artifactCount: Int
    public let artifacts: [CaptureServerArtifact]
    public let manifestJSON: Data
    public let createdAt: Date
    public let updatedAt: Date
    public let uploadedAt: Date?
    public let enrichedAt: Date?
    public let uploadClaimedAt: Date?
    public let uploadDeadlineAt: Date?
    public let syncAttemptCount: Int
    public let syncNextEligibleAt: Date?
    public let syncFailureClass: RelayFailureClass?
    public let syncFailureMessage: String?
    public let syncFailureDomain: String?
    public let syncFailureCode: Int?
    public let syncHTTPStatus: Int?
    public let syncQuarantinedAt: Date?

    public var id: String { captureID }

    public func hasLiveUploadLease(at now: Date = Date()) -> Bool {
        guard state == CaptureLocalState.uploading.rawValue,
              let uploadClaimedAt,
              let uploadDeadlineAt
        else {
            return false
        }
        return uploadClaimedAt <= now && uploadDeadlineAt >= now
    }

    public init(
        captureID: String,
        kind: String,
        source: String,
        title: String,
        textContent: String,
        foundURL: String = "",
        capturedAt: Date,
        effectiveDay: String,
        state: String,
        lastError: String?,
        retryCount: Int = 0,
        blobFilename: String,
        blobContentType: String,
        blobPath: String?,
        blobSize: Int64,
        artifactCount: Int,
        artifacts: [CaptureServerArtifact] = [],
        manifestJSON: Data,
        createdAt: Date,
        updatedAt: Date,
        uploadedAt: Date?,
        enrichedAt: Date?,
        uploadClaimedAt: Date? = nil,
        uploadDeadlineAt: Date? = nil,
        syncAttemptCount: Int = 0,
        syncNextEligibleAt: Date? = nil,
        syncFailureClass: RelayFailureClass? = nil,
        syncFailureMessage: String? = nil,
        syncFailureDomain: String? = nil,
        syncFailureCode: Int? = nil,
        syncHTTPStatus: Int? = nil,
        syncQuarantinedAt: Date? = nil
    ) {
        self.captureID = captureID
        self.kind = kind
        self.source = source
        self.title = title
        self.textContent = textContent
        self.foundURL = foundURL
        self.capturedAt = capturedAt
        self.effectiveDay = effectiveDay
        self.state = state
        self.lastError = lastError
        self.retryCount = retryCount
        self.blobFilename = blobFilename
        self.blobContentType = blobContentType
        self.blobPath = blobPath
        self.blobSize = blobSize
        self.artifactCount = artifactCount
        self.artifacts = artifacts
        self.manifestJSON = manifestJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.uploadedAt = uploadedAt
        self.enrichedAt = enrichedAt
        self.uploadClaimedAt = uploadClaimedAt
        self.uploadDeadlineAt = uploadDeadlineAt
        self.syncAttemptCount = syncAttemptCount
        self.syncNextEligibleAt = syncNextEligibleAt
        self.syncFailureClass = syncFailureClass
        self.syncFailureMessage = syncFailureMessage
        self.syncFailureDomain = syncFailureDomain
        self.syncFailureCode = syncFailureCode
        self.syncHTTPStatus = syncHTTPStatus
        self.syncQuarantinedAt = syncQuarantinedAt
    }
}

public enum CaptureDateCodecError: LocalizedError {
    case invalidInternetDate(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInternetDate(raw):
            return "invalid_date:\(raw)"
        }
    }
}

public enum CaptureDateCodec {
    private static func formatterWithFractional() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func captureIDFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }

    public static func internetString(_ date: Date) -> String {
        formatterWithFractional().string(from: date)
    }

    public static func parseInternetDate(_ raw: String) throws -> Date {
        if let date = formatterWithFractional().date(from: raw) ?? formatter().date(from: raw) {
            return date
        }
        throw CaptureDateCodecError.invalidInternetDate(raw)
    }

    public static func dayString(_ date: Date) -> String {
        dayFormatter().string(from: date)
    }

    public static func captureIDTimestamp(_ date: Date) -> String {
        captureIDFormatter().string(from: date)
    }
}
