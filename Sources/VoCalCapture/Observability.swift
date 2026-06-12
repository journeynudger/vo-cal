import Foundation

public enum ObservabilityLevel: String, Codable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
}

public enum ObservabilityUnit: String, Codable, Sendable {
    case milliseconds
    case count
    case bytes
}

public enum ObservabilityExecutionMode: String, Codable, Sendable {
    case backgroundVoiceIntent = "background_voice_intent"
    case foregroundApp = "foreground_app"
    case selfTest = "self_test"
    case inspection = "inspection"
    case unknown = "unknown"
}

public enum ObservabilityScalar: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported observability scalar")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        }
    }
}

public struct ObservabilityRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case diagnostic
        case measurement
        case milestone
    }

    public let schemaVersion: Int
    public let kind: Kind
    public let timestamp: String
    public let name: String
    public let operationID: String?
    public let milestone: String?
    public let elapsedMS: Int?
    public let level: ObservabilityLevel?
    public let message: String?
    public let unit: ObservabilityUnit?
    public let value: ObservabilityScalar?
    public let attributes: [String: ObservabilityScalar]

    public init(
        kind: Kind,
        timestamp: String,
        name: String,
        operationID: String? = nil,
        milestone: String? = nil,
        elapsedMS: Int? = nil,
        level: ObservabilityLevel? = nil,
        message: String? = nil,
        unit: ObservabilityUnit? = nil,
        value: ObservabilityScalar? = nil,
        attributes: [String: ObservabilityScalar] = [:]
    ) {
        self.schemaVersion = 1
        self.kind = kind
        self.timestamp = timestamp
        self.name = name
        self.operationID = operationID
        self.milestone = milestone
        self.elapsedMS = elapsedMS
        self.level = level
        self.message = message
        self.unit = unit
        self.value = value
        self.attributes = attributes
    }
}

public protocol ObservabilitySink: Sendable {
    func record(_ record: ObservabilityRecord) async throws
}

public struct ObservabilityOperationHandle: Sendable {
    public let name: String
    public let operationID: String

    private let client: ObservabilityClient
    private let startedAt: Date
    private let startedInstant: ContinuousClock.Instant
    private let clock: ContinuousClock
    private let baseAttributes: [String: ObservabilityScalar]

    init(
        client: ObservabilityClient,
        name: String,
        operationID: String,
        startedAt: Date,
        startedInstant: ContinuousClock.Instant,
        clock: ContinuousClock,
        baseAttributes: [String: ObservabilityScalar]
    ) {
        self.client = client
        self.name = name
        self.operationID = operationID
        self.startedAt = startedAt
        self.startedInstant = startedInstant
        self.clock = clock
        self.baseAttributes = baseAttributes
    }

    public func milestone(
        _ milestone: String,
        attributes: [String: ObservabilityScalar] = [:]
    ) {
        let elapsed = elapsedMilliseconds(since: startedInstant, now: clock.now)
        client.recordMilestone(
            name: name,
            operationID: operationID,
            milestone: milestone,
            startedAt: startedAt,
            elapsedMS: elapsed,
            attributes: baseAttributes.merging(attributes) { _, new in new }
        )
    }
}

public actor ObservabilityClient {
    private let clock = ContinuousClock()
    private var sinks: [any ObservabilitySink] = []

    public init(sinks: [any ObservabilitySink] = []) {
        self.sinks = sinks
    }

    public func replaceSinks(_ sinks: [any ObservabilitySink]) {
        self.sinks = sinks
    }

    public func appendSink(_ sink: any ObservabilitySink) {
        sinks.append(sink)
    }

    nonisolated public func diagnostic(
        _ level: ObservabilityLevel,
        name: String,
        message: String,
        attributes: [String: ObservabilityScalar] = [:]
    ) {
        let record = ObservabilityRecord(
            kind: .diagnostic,
            timestamp: CaptureDateCodec.internetString(Date()),
            name: name,
            level: level,
            message: message,
            attributes: attributes
        )
        Task {
            await self.record(record)
        }
    }

    nonisolated public func measurement(
        name: String,
        value: Int,
        unit: ObservabilityUnit,
        attributes: [String: ObservabilityScalar] = [:]
    ) {
        let record = ObservabilityRecord(
            kind: .measurement,
            timestamp: CaptureDateCodec.internetString(Date()),
            name: name,
            unit: unit,
            value: .integer(Int64(value)),
            attributes: attributes
        )
        Task {
            await self.record(record)
        }
    }

    nonisolated public func measurement(
        name: String,
        value: Double,
        unit: ObservabilityUnit,
        attributes: [String: ObservabilityScalar] = [:]
    ) {
        let record = ObservabilityRecord(
            kind: .measurement,
            timestamp: CaptureDateCodec.internetString(Date()),
            name: name,
            unit: unit,
            value: .double(value),
            attributes: attributes
        )
        Task {
            await self.record(record)
        }
    }

    nonisolated public func recordMilestone(
        name: String,
        operationID: String,
        milestone: String,
        startedAt: Date,
        elapsedMS: Int,
        attributes: [String: ObservabilityScalar] = [:]
    ) {
        var metadata = attributes
        metadata["operation_started_at"] = .string(CaptureDateCodec.internetString(startedAt))
        let record = ObservabilityRecord(
            kind: .milestone,
            timestamp: CaptureDateCodec.internetString(Date()),
            name: name,
            operationID: operationID,
            milestone: milestone,
            elapsedMS: elapsedMS,
            attributes: metadata
        )
        Task {
            await self.record(record)
        }
    }

    public func beginOperation(
        name: String,
        operationID: String = UUID().uuidString.lowercased(),
        attributes: [String: ObservabilityScalar] = [:]
    ) -> ObservabilityOperationHandle {
        ObservabilityOperationHandle(
            client: self,
            name: name,
            operationID: operationID,
            startedAt: Date(),
            startedInstant: clock.now,
            clock: clock,
            baseAttributes: attributes
        )
    }

    private func record(_ record: ObservabilityRecord) async {
        for sink in sinks {
            do {
                try await sink.record(record)
            } catch {
                continue
            }
        }
    }
}

public func elapsedMilliseconds(
    since start: ContinuousClock.Instant,
    now: ContinuousClock.Instant = ContinuousClock().now
) -> Int {
    durationMilliseconds(start.duration(to: now))
}

public func durationMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    let secondsMS = components.seconds * 1_000
    let attosecondsMS = components.attoseconds / 1_000_000_000_000_000
    return max(0, Int(secondsMS + attosecondsMS))
}

public extension ObservabilityScalar {
    init(_ value: String) {
        self = .string(value)
    }

    init(_ value: Int) {
        self = .integer(Int64(value))
    }

    init(_ value: Int64) {
        self = .integer(value)
    }

    init(_ value: Double) {
        self = .double(value)
    }

    init(_ value: Bool) {
        self = .bool(value)
    }
}
