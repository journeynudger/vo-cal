import Foundation
import VoCalCore

/// Networking configuration. Base URL comes from the `VOCAL_API_BASE_URL` Info.plist key
/// (set in project.yml), defaulting to the local backend. The Bearer token is the real
/// Sign-in-with-Apple JWT in production (Phase F); until then, DEBUG/UITestMode sends the
/// `X-Test-User` header instead, hitting the local backend's test-auth seam.
struct APIConfig: Sendable {
    var baseURL: URL

    /// Source of the live Supabase access token (Sign in with Apple / anonymous, Phase F).
    /// Read per request so a token refreshed by the SDK is picked up without rebuilding the
    /// client. Nil in the mock path, which authenticates with `X-Test-User` instead.
    var tokenStore: AuthTokenStore?

    /// DEBUG/UITestMode: send `X-Test-User` so the loop works against `make api-dev`
    /// without real auth. Off in real builds (the live Supabase JWT is sent instead).
    var sendsTestUserHeader: Bool

    static func resolved() -> APIConfig {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "VOCAL_API_BASE_URL") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "http://localhost:8000"
        let url = URL(string: raw) ?? URL(string: "http://localhost:8000")!
        let mock = RuntimeMode.usesMockServices
        return APIConfig(
            baseURL: url,
            // Live builds carry the shared token store; the mock path uses X-Test-User only.
            tokenStore: mock ? nil : AuthTokenStore.shared,
            sendsTestUserHeader: mock
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

    /// `POST /captures` (multipart) — durably store the capture audio as ground truth and get
    /// back the server capture id. Idempotent by `client_capture_id`, so an offline/outbox
    /// replay returns the same row. Runs off the capture hot path (derived pipeline only).
    func uploadCapture(
        audio: Data,
        filename: String,
        contentType: String,
        clientCaptureID: String,
        durationMs: Int?,
        device: String?
    ) async throws -> CaptureUploadResult {
        var fields = ["client_capture_id": clientCaptureID]
        if let durationMs { fields["duration_ms"] = String(durationMs) }
        if let device { fields["device"] = device }
        return try await postMultipart(
            "/captures",
            fields: fields,
            fileField: "audio",
            filename: filename,
            contentType: contentType,
            fileData: audio
        )
    }

    /// `POST /transcribe` — server-side ElevenLabs Scribe over the stored capture audio.
    /// `capture_id` is a form field (matches the FastAPI route). Returns the transcript text
    /// plus its immutable id for `/parse` provenance.
    func transcribe(captureID: String) async throws -> TranscriptResult {
        try await postForm("/transcribe", fields: ["capture_id": captureID])
    }

    /// `DELETE /account` — irreversible: purges the caller's data + auth identity. 204, no body.
    func deleteAccount() async throws {
        var request = try makeRequest(path: "/account", query: [:])
        request.httpMethod = "DELETE"
        try await sendNoContent(request)
    }

    func today(date: String) async throws -> TodayResult {
        try await get("/meals/today", query: ["date": date])
    }

    /// `GET /meals/today` — the full dashboard payload (targets/consumed/remaining/meals).
    /// Same endpoint as `today(date:)` but decoded into the richer `TodayDashboard` the
    /// Today screen needs; `today(date:)` stays the loop's lightweight refresh.
    func todayDashboard(date: String) async throws -> TodayDashboard {
        try await get("/meals/today", query: ["date": date])
    }

    /// `POST /protocols/generate` — intake answers -> computed + persisted active protocol.
    func generateProtocol(intake: IntakeProfile) async throws -> GenerateProtocolResponse {
        struct Body: Encodable { let intake: IntakeProfile }
        return try await post("/protocols/generate", body: Body(intake: intake))
    }

    /// `GET /checkins/due` — is a weekly check-in due?
    func checkinDue() async throws -> CheckinDueResponse {
        try await get("/checkins/due", query: [:])
    }

    /// `POST /checkins` — store the user's self-report.
    func submitCheckin(_ inputs: CheckinInputs) async throws -> CheckinSubmitResponse {
        try await post("/checkins", body: inputs)
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

    private func postMultipart<Response: Decodable>(
        _ path: String,
        fields: [String: String],
        fileField: String,
        filename: String,
        contentType: String,
        fileData: Data
    ) async throws -> Response {
        var request = try makeRequest(path: path, query: [:])
        request.httpMethod = "POST"
        let boundary = "vocal.\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        let dashes = "--\(boundary)\r\n"
        for (name, value) in fields {
            body.appendString(dashes)
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        body.appendString(dashes)
        body.appendString(
            "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n"
        )
        body.appendString("Content-Type: \(contentType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return try await send(request)
    }

    private func postForm<Response: Decodable>(
        _ path: String,
        fields: [String: String]
    ) async throws -> Response {
        var request = try makeRequest(path: path, query: [:])
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
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
        if let token = config.tokenStore?.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if config.sendsTestUserHeader {
            request.setValue(RuntimeMode.testUserID, forHTTPHeaderField: "X-Test-User")
        }
        return request
    }

    private func sendNoContent(_ request: URLRequest) async throws {
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

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
