import Foundation
import VoCalCore

/// Networking configuration. Base URL comes from the `VOCAL_API_BASE_URL` Info.plist key
/// (set in project.yml), defaulting to the local backend. The Bearer token is the real
/// Sign-in-with-Apple JWT in production (Phase F); until then, DEBUG/UITestMode sends the
/// `X-Test-User` header instead, hitting the local backend's test-auth seam.
struct APIConfig: Sendable {
    var baseURL: URL
    var bearerToken: String?

    /// DEBUG/UITestMode: send `X-Test-User` so the loop works against `make api-dev`
    /// without real auth. Off in release (real JWT lands in Phase F).
    var sendsTestUserHeader: Bool

    static func resolved() -> APIConfig {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "VOCAL_API_BASE_URL") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "http://localhost:8000"
        let url = URL(string: raw) ?? URL(string: "http://localhost:8000")!
        return APIConfig(
            baseURL: url,
            bearerToken: nil,
            sendsTestUserHeader: RuntimeMode.usesMockServices
        )
    }
}

enum APIError: LocalizedError {
    case badURL
    case transport(any Error)
    case status(code: Int, body: String)
    case decoding(any Error)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "api_bad_url"
        case let .transport(error):
            return "api_transport:\(error.localizedDescription)"
        case let .status(code, _):
            return "api_status:\(code)"
        case let .decoding(error):
            return "api_decoding:\(error.localizedDescription)"
        }
    }
}

/// Async REST client. JSON via VoCalCore.VoCalJSON codecs. Bodies and responses match the
/// FastAPI contract exactly (snake_case + ISO8601). The whole type is value-typed and
/// `Sendable`; it holds no mutable state beyond the immutable config + session.
struct APIClient: APIClientProtocol {
    let config: APIConfig
    private let session: URLSession

    init(config: APIConfig = .resolved(), session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func parse(transcript: String, captureID: String?) async throws -> ParseResult {
        struct Body: Encodable {
            let transcript: String
            let captureId: String?
        }
        return try await post("/parse", body: Body(transcript: transcript, captureId: captureID))
    }

    func refine(parseID: String, answers: [RefineAnswer]) async throws -> ParseResult {
        struct Body: Encodable {
            let parseId: String
            let answers: [RefineAnswer]
        }
        return try await post("/parse/refine", body: Body(parseId: parseID, answers: answers))
    }

    func logMeal(_ request: LogMealRequest) async throws -> MealLogConfirmation {
        try await post("/meals", body: request)
    }

    func today(date: String) async throws -> TodayResult {
        try await get("/meals/today", query: ["date": date])
    }

    // MARK: - Transport

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        var request = try makeRequest(path: path, query: [:])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try VoCalJSON.encoder().encode(body)
        } catch {
            throw APIError.decoding(error)
        }
        return try await send(request)
    }

    private func get<Response: Decodable>(
        _ path: String,
        query: [String: String]
    ) async throws -> Response {
        var request = try makeRequest(path: path, query: query)
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func makeRequest(path: String, query: [String: String]) throws -> URLRequest {
        guard var components = URLComponents(
            url: config.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.badURL
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw APIError.badURL
        }
        var request = URLRequest(url: url)
        if let token = config.bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if config.sendsTestUserHeader {
            request.setValue(RuntimeMode.testUserID, forHTTPHeaderField: "X-Test-User")
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.status(code: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        do {
            return try VoCalJSON.decoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
