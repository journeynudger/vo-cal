import Foundation

/// Canonical JSON coding for everything crossing the API boundary.
/// Server speaks snake_case + ISO8601; Swift speaks camelCase. Configure once
/// here so no callsite invents its own strategy.
public enum VoCalJSON {
    // The server's datetimes are Python `datetime.isoformat()` → FRACTIONAL seconds
    // (microseconds, e.g. "2026-06-29T23:30:48.105922+00:00"). Foundation's plain
    // `.iso8601` strategy rejects fractional seconds outright, so every Date-bearing
    // response (Today's `logged_at`, the meal-edit screen) silently failed to decode —
    // a 200 that the app turned into an error, the same class as the is_estimate bug.
    // This strategy accepts BOTH fractional and non-fractional ISO8601 so a shipped
    // client can't break on the server's timestamp precision.
    // nonisolated(unsafe): ISO8601DateFormatter predates Sendable but is documented
    // thread-safe for parsing/formatting (unlike DateFormatter it holds no mutable state
    // after configuration, and these are configured once at init and never mutated).
    // Same pattern as CaptureDateCodec in VoCalCapture.
    private nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse an ISO8601 string with or without fractional seconds (and, as a last resort,
    /// after trimming sub-millisecond digits — ISO8601DateFormatter is only reliable to
    /// milliseconds, but Python emits microseconds).
    public static func parseDate(_ raw: String) -> Date? {
        if let date = iso8601Fractional.date(from: raw) ?? iso8601Plain.date(from: raw) {
            return date
        }
        // Trim 6-digit microseconds to 3-digit milliseconds and retry (…48.105922Z → …48.105Z).
        if let dot = raw.firstIndex(of: ".") {
            let afterDot = raw.index(after: dot)
            let tzStart = raw[afterDot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
                ?? raw.endIndex
            let fraction = raw[afterDot..<tzStart]
            if fraction.count > 3 {
                let trimmed = raw[..<afterDot] + fraction.prefix(3) + raw[tzStart...]
                return iso8601Fractional.date(from: String(trimmed))
            }
        }
        return nil
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected an ISO8601 date string, got \(raw)"
                    )
                )
            }
            return date
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
