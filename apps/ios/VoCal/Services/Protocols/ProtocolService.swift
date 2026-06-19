import Foundation
import VoCalCore

/// Generates the personalized protocol from intake answers. Mock on the sim path (returns a
/// deterministic persona protocol with a brief "building…" delay), live via
/// `POST /protocols/generate` otherwise. The engine math lives server-side (AGENTS.md #6);
/// the client only renders what it returns.
protocol ProtocolService: Sendable {
    func generate(from intake: IntakeProfile) async throws -> ProtocolTargets
}

struct MockProtocolService: ProtocolService {
    var latency: Duration = .milliseconds(900)

    func generate(from intake: IntakeProfile) async throws -> ProtocolTargets {
        try? await Task.sleep(for: latency)
        return .personaFixture
    }
}

struct LiveProtocolService: ProtocolService {
    let api: APIClient
    init(api: APIClient = APIClient()) { self.api = api }

    func generate(from intake: IntakeProfile) async throws -> ProtocolTargets {
        let response = try await api.generateProtocol(intake: intake)
        let t = response.targets
        return ProtocolTargets(
            protocolId: response.protocolId,
            version: t.version,
            kcal: t.kcal,
            protein: t.protein,
            carbs: t.carbs,
            fat: t.fat,
            fiber: t.fiber,
            produceServings: t.produceServings,
            waterOz: t.waterOz,
            mealsPerDay: t.mealsPerDay,
            whys: t.whys
        )
    }
}

extension ProtocolTargets {
    /// Illustrative protocol for the sim/onboarding demo — the night-shift-nurse persona
    /// used across the prototype. Numbers are placeholders, not a recommendation.
    static let personaFixture = ProtocolTargets(
        protocolId: "mock-protocol",
        version: 1,
        kcal: 2040,
        protein: 150,
        carbs: 200,
        fat: 60,
        fiber: 30,
        produceServings: 5,
        waterOz: 96,
        mealsPerDay: 4,
        whys: [
            "kcal": "A lighter deficit on purpose — night shifts, two kids, and high stress need a plan that holds, not one that breaks by Wednesday.",
            "protein": "Scaled to your body weight to protect muscle while you lose fat. Anywhere in the range counts.",
            "water": "Roughly half your body weight in ounces — more on training days. Helps with the late-night grazing too.",
            "fiber": "Scaled to your calories. Keeps you full on a deficit — most of the battle when appetite spikes at night.",
            "produce": "Five servings of fruit and veg — the simplest lever for fullness, fiber, and micronutrients at once.",
        ]
    )
}
