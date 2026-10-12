import Foundation
import VoCalCore

/// The engine's answer to an intake: the whole protocol (every target, for every mode;
/// AGENTS.md #6) and the keys the person's mode reveals, in order (services/api
/// tracking/projection.py). An empty `reveal` comes from a server that predates modes; the
/// screens then show the five.
struct GeneratedProtocol: Sendable, Equatable {
    var targets: ProtocolTargets
    var reveal: [String]
}

/// Generates the personalized protocol from intake answers. Mock on the sim path (returns a
/// deterministic persona protocol with a brief "building…" delay), live via
/// `POST /protocols/generate` otherwise. The engine math lives server-side (AGENTS.md #6);
/// the client only renders what it returns.
protocol ProtocolService: Sendable {
    func generate(from intake: IntakeProfile, mode: TrackingMode?) async throws -> GeneratedProtocol
}

struct MockProtocolService: ProtocolService {
    var latency: Duration = .milliseconds(900)

    func generate(from intake: IntakeProfile, mode: TrackingMode?) async throws -> GeneratedProtocol {
        try? await Task.sleep(for: latency)
        return GeneratedProtocol(targets: .personaFixture, reveal: Self.reveal(for: mode ?? .five))
    }

    /// The server's reveal table (tracking/projection.py), for the sim only: the live path
    /// reads `reveal` from the response.
    static func reveal(for mode: TrackingMode) -> [String] {
        switch mode {
        case .habits: ["water", "produce"]
        case .calories: ["kcal"]
        case .five, .mealPlan: ["kcal", "protein", "water", "fiber", "produce"]
        case .macros: ["kcal", "protein", "carbs", "fat", "fiber"]
        }
    }
}

struct LiveProtocolService: ProtocolService {
    let api: APIClient
    init(api: APIClient = APIClient()) { self.api = api }

    func generate(from intake: IntakeProfile, mode: TrackingMode?) async throws -> GeneratedProtocol {
        let response = try await api.generateProtocol(intake: intake, mode: mode)
        return GeneratedProtocol(targets: ProtocolTargets(response), reveal: response.reveal ?? [])
    }
}

extension ProtocolTargets {
    /// The protocol as the API returns it, in the app's one shape. Three screens once mapped
    /// the fields by hand and could drift on the band's default; now there is one mapping.
    init(_ response: GenerateProtocolResponse) {
        self.init(targets: response.targets, protocolId: response.protocolId)
    }

    init(targets t: GenerateProtocolResponse.APITargets, protocolId: String) {
        self.init(
            protocolId: protocolId,
            version: t.version,
            kcal: t.kcal,
            protein: t.protein,
            proteinMin: t.proteinMin ?? 0,
            proteinMax: t.proteinMax ?? 0,
            carbs: t.carbs,
            fat: t.fat,
            fiber: t.fiber,
            produceServings: t.produceServings,
            waterOz: t.waterOz,
            mealsPerDay: t.mealsPerDay,
            whys: t.whys
        )
    }

    /// Illustrative protocol for the sim/onboarding demo — the night-shift-nurse persona
    /// used across the prototype. Numbers are placeholders, not a recommendation.
    static let personaFixture = ProtocolTargets(
        protocolId: "mock-protocol",
        version: 1,
        kcal: 2040,
        protein: 150,
        proteinMin: 135,
        proteinMax: 165,
        carbs: 200,
        fat: 60,
        fiber: 30,
        produceServings: 5,
        waterOz: 96,
        mealsPerDay: 4,
        whys: [
            "kcal": "A lighter deficit on purpose - night shifts, two kids, and high stress need a plan that holds, not one that breaks by Wednesday.",
            "protein": "Scaled to your body weight to protect muscle while you lose fat. Anywhere in the range counts.",
            "carbs": "What is left of your calories once protein and fat are placed: the fuel for your training days.",
            "fat": "A steady share of your calories, enough for hormones and for meals that satisfy.",
            "water": "Roughly half your body weight in ounces - more on training days. Helps with the late-night grazing too.",
            "fiber": "Scaled to your calories. Keeps you full on a deficit - most of the battle when appetite spikes at night.",
            "produce": "Five servings of fruit and veg - the simplest lever for fullness, fiber, and micronutrients at once.",
        ]
    )
}
