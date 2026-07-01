import Foundation
import VoCalCore

/// Sim-verifiable orchestrator. Returns canned ParseResults from MealCaptureFixtures so the
/// full loop — transcript, parse, per-ingredient checks, refine round-trip, confirm — runs
/// on the simulator with zero network and no microphone. It is an actor so refine can mutate
/// the in-flight parse (drop the answered question, supersede the item) deterministically.
actor MockMealCaptureService: MealCaptureService {
    private let scenario: MockCaptureScenario
    /// Simulated network latency so the Transcribing/Enhancing states are visible.
    private let latency: Duration
    /// The last result handed out, keyed by parseId, so refine resolves against it.
    private var resultsByParseID: [String: ParseResult] = [:]
    private var nextParseSerial = 0

    init(scenario: MockCaptureScenario = .beefAndRice, latency: Duration = .milliseconds(600)) {
        self.scenario = scenario
        self.latency = latency
    }

    func transcribe(captureID: String, audioURL: URL?) async throws -> MealTranscription {
        try? await Task.sleep(for: latency)
        // No server upload on the mock path, so no server capture id — parse carries no link.
        return MealTranscription(text: MealCaptureFixtures.transcript(for: scenario), serverCaptureID: nil)
    }

    func parse(transcript: String, captureID: String?) async throws -> ParseResult {
        try? await Task.sleep(for: latency)
        let result: ParseResult
        switch scenario {
        case .beefAndRice:
            result = MealCaptureFixtures.beefAndRice(mealType: .lunch)
        case .burger:
            result = MealCaptureFixtures.burger(mealType: .lunch)
        }
        resultsByParseID[result.parseId] = result
        return result
    }

    func refine(parseID: String, answers: [RefineAnswer]) async throws -> ParseResult {
        try? await Task.sleep(for: latency)
        guard var current = resultsByParseID[parseID] else {
            throw APIError.status(code: 404, body: "mock parse not found")
        }

        for answer in answers {
            guard let index = Self.itemIndex(forField: answer.field),
                  index < current.items.count
            else { continue }
            let option: String
            switch answer.value {
            case let .string(value): option = value
            case let .number(value): option = String(value)
            }
            current.items[index] = MealCaptureFixtures.resolvedItem(
                field: answer.field,
                option: option,
                base: current.items[index]
            )
            current.questions.removeAll { $0.field == answer.field }
            current.missingDetails.removeAll { $0.field == answer.field }
        }

        nextParseSerial += 1
        let superseded = ParseResult(
            parseId: "\(parseID)-r\(nextParseSerial)",
            supersedes: parseID,
            mealType: current.mealType,
            items: current.items,
            totals: current.items.map(\.macros).reduce(.zero, +),
            mealConfidence: Self.weightedConfidence(current.items),
            questions: current.questions,
            missingDetails: current.missingDetails,
            model: MealCaptureFixtures.model,
            promptVersion: MealCaptureFixtures.promptVersion
        )
        resultsByParseID[superseded.parseId] = superseded
        return superseded
    }

    func logMeal(_ request: LogMealRequest) async throws -> MealLogConfirmation {
        try? await Task.sleep(for: latency)
        let totals = request.items.map(\.macros).reduce(.zero, +)
        return MealLogConfirmation(
            id: "mock-meal-\(UUID().uuidString.prefix(8))",
            name: request.name,
            mealType: request.mealType,
            totals: totals,
            confidence: Self.weightedConfidence(
                request.items.map {
                    ParseResultItem(
                        name: $0.name, grams: $0.grams, macros: $0.macros,
                        confidence: $0.confidence, source: .dictionary, matchScore: 1
                    )
                }
            ),
            correctionsCount: 0
        )
    }

    func logWater(_ request: WaterLogRequest) async throws -> WaterLog {
        try? await Task.sleep(for: latency)
        return WaterLog(id: "mock-water-\(UUID().uuidString.prefix(8))", amountOz: request.amountOz)
    }

    /// Parse the item index out of a JSON-path field like "items[0].fat_ratio".
    private static func itemIndex(forField field: String) -> Int? {
        guard let open = field.firstIndex(of: "["),
              let close = field.firstIndex(of: "]"),
              open < close
        else { return nil }
        return Int(field[field.index(after: open)..<close])
    }

    private static func weightedConfidence(_ items: [ParseResultItem]) -> Double {
        let weights = items.map { max($0.macros.kcal, 0) }
        let total = weights.reduce(0, +)
        guard total > 0 else {
            guard !items.isEmpty else { return 0 }
            return items.map(\.confidence).reduce(0, +) / Double(items.count)
        }
        return zip(items, weights).map { $0.confidence * $1 }.reduce(0, +) / total
    }
}
