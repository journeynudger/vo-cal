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
        return MealTranscription(
            text: MealCaptureFixtures.transcript(for: scenario),
            serverCaptureID: nil,
            transcriptID: nil
        )
    }

    func parse(transcript: String, captureID: String?, transcriptID: String?) async throws -> ParseResult {
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
            current.items[index] = Self.applyGenericEdit(
                field: answer.field,
                option: option,
                to: MealCaptureFixtures.resolvedItem(
                    field: answer.field,
                    option: option,
                    base: current.items[index]
                )
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

    func appendToMeal(mealID: String, _ request: AppendToMealRequest) async throws -> MealLogConfirmation {
        try? await Task.sleep(for: latency)
        // Sim-only synthesis: echoes the appended items' totals under the target meal's id
        // (the mock has no stored meal to merge into; the live server owns the real merge).
        let totals = request.items.map(\.macros).reduce(.zero, +)
        return MealLogConfirmation(
            id: mealID,
            name: nil,
            mealType: .unspecified,
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

    /// The edit sheet's own answers (name, amount + unit, state, fat ratio), applied the way
    /// the live server does so the sheet round-trips on the mock path too: the fixtures only
    /// know the scripted chip answers. Macros stay the fixture's (the mock never prices).
    func parseText(_ text: String) async throws -> ParseResult {
        // The sim's typed log: the burger when the text mentions one, else the beef and rice,
        // so both result shapes (checks, none) are reachable from the keyboard.
        try? await Task.sleep(for: latency)
        let result = text.lowercased().contains("burger")
            ? MealCaptureFixtures.burger(mealType: .lunch, parseID: "mock-typed-\(nextSerial())")
            : MealCaptureFixtures.beefAndRice(mealType: .lunch, parseID: "mock-typed-\(nextSerial())")
        resultsByParseID[result.parseId] = result
        return result
    }

    func parsePhoto(_ photo: Data, contentType: String, clientCaptureID: String, note: String?) async throws -> ParseResult {
        // A photo on the sim is the burger plate: the checks are the blind spots a photo has.
        try? await Task.sleep(for: latency + .milliseconds(400))
        let result = MealCaptureFixtures.burger(mealType: .lunch, parseID: "mock-photo-\(nextSerial())")
        resultsByParseID[result.parseId] = result
        return result
    }

    func searchLogged(query: String) async throws -> [SearchHit] {
        try? await Task.sleep(for: .milliseconds(120))
        let needle = query.lowercased()
        return Self.searchCorpus.filter { $0.name.lowercased().contains(needle) }
    }

    private func nextSerial() -> Int {
        nextParseSerial += 1
        return nextParseSerial
    }

    private static let searchCorpus: [SearchHit] = [
        SearchHit(kind: "usual", id: "mock-usual-smoothie", name: "Metal detox smoothie", kcal: 310, lastLoggedAt: .now, times: 12, items: []),
        SearchHit(kind: "meal", id: "mock-meal-yogurt", name: "Greek yogurt, berries & granola", kcal: 420, lastLoggedAt: .now, times: 6, items: []),
        SearchHit(kind: "meal", id: "mock-meal-chicken", name: "Chicken, rice & broccoli", kcal: 640, lastLoggedAt: .now, times: 9, items: []),
        SearchHit(kind: "usual", id: "mock-usual-shake", name: "Protein shake", kcal: 120, lastLoggedAt: .now, times: 20, items: []),
        SearchHit(kind: "personal_food", id: "mock-food-chili", name: "My chili recipe", kcal: 410, lastLoggedAt: nil, times: 1, items: []),
        SearchHit(kind: "meal", id: "mock-meal-oats", name: "Overnight oats", kcal: 380, lastLoggedAt: .now, times: 3, items: []),
    ]

    private static func applyGenericEdit(field: String, option: String, to base: ParseResultItem) -> ParseResultItem {
        var item = base
        let axis = field.split(separator: ".").last.map(String.init) ?? ""
        switch axis {
        case "name":
            let name = option.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { item.name = name }
        case "amount":
            let parts = option.split(separator: " ", maxSplits: 1).map(String.init)
            if let first = parts.first, let amount = Double(first) {
                item.amount = amount
                item.unit = parts.count > 1 ? FoodUnit(rawValue: parts[1]) : nil
            }
        case "state":
            if let state = FoodState(rawValue: option) { item.state = state }
        case "fat_ratio":
            item.fatRatio = option
        default:
            break
        }
        return item
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
