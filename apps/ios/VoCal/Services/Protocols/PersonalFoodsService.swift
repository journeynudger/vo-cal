import Foundation
import VoCalCore

/// The person's own foods: a label they typed once, a batch they cooked and portioned. The
/// server prices them by name on every later parse (foods/index.py); the app only declares
/// and lists them. A protocol so the sheets run on the simulator with no backend.
protocol PersonalFoodsService: Sendable {
    func list() async throws -> [PersonalFood]
    func saveLabel(_ request: SaveLabelFoodRequest) async throws -> PersonalFood
    func saveBatch(_ request: SaveBatchFoodRequest) async throws -> PersonalFood
    func retire(id: String) async throws
}

struct LivePersonalFoodsService: PersonalFoodsService {
    let api: any APIClientProtocol

    func list() async throws -> [PersonalFood] { try await api.personalFoods() }
    func saveLabel(_ request: SaveLabelFoodRequest) async throws -> PersonalFood { try await api.saveLabelFood(request) }
    func saveBatch(_ request: SaveBatchFoodRequest) async throws -> PersonalFood { try await api.saveBatchFood(request) }
    func retire(id: String) async throws { try await api.retirePersonalFood(id: id) }
}

/// No backend on the mock path: two seeded foods, saves that append, retires that remove, so
/// every sheet and the Settings page are exercisable on the simulator.
actor MockPersonalFoodsService: PersonalFoodsService {
    static let shared = MockPersonalFoodsService()

    private var foods: [PersonalFood] = [
        PersonalFood(
            id: "mock-food-1", name: "Street taco chicken", aliases: ["taco chicken"],
            perServing: NutrientProfile(kcal: 153, protein: 24, carbs: 3, fat: 5, fiber: 0),
            servingGrams: 113, servingsPerPackage: 2, source: "label",
            createdAt: Date().addingTimeInterval(-86_400 * 3)
        ),
        PersonalFood(
            id: "mock-food-2", name: "Chili", aliases: [],
            perServing: NutrientProfile(kcal: 410, protein: 32, carbs: 38, fat: 14, fiber: 9),
            servingGrams: 320, servingsPerPackage: 8, source: "batch",
            createdAt: Date().addingTimeInterval(-86_400 * 9)
        ),
    ]

    func list() async throws -> [PersonalFood] { foods }

    func saveLabel(_ request: SaveLabelFoodRequest) async throws -> PersonalFood {
        let serving = request.perServing
        let kcal = serving.kcal ?? (serving.protein * 4 + serving.carbs * 4 + serving.fat * 9)
        let food = PersonalFood(
            id: "mock-food-\(UUID().uuidString.prefix(6))", name: request.name, aliases: request.aliases,
            perServing: NutrientProfile(kcal: kcal, protein: serving.protein, carbs: serving.carbs, fat: serving.fat, fiber: serving.fiber),
            servingGrams: request.servingGrams, servingsPerPackage: request.servingsPerPackage,
            source: "label", createdAt: Date()
        )
        foods.removeAll { $0.name.lowercased() == food.name.lowercased() }
        foods.insert(food, at: 0)
        return food
    }

    func saveBatch(_ request: SaveBatchFoodRequest) async throws -> PersonalFood {
        let totals = request.items.reduce(NutrientProfile(kcal: 0, protein: 0, carbs: 0, fat: 0, fiber: 0)) { sum, item in
            NutrientProfile(
                kcal: sum.kcal + item.macros.kcal, protein: sum.protein + item.macros.protein,
                carbs: sum.carbs + item.macros.carbs, fat: sum.fat + item.macros.fat, fiber: sum.fiber + item.macros.fiber
            )
        }
        let n = max(request.servings, 1)
        let food = PersonalFood(
            id: "mock-food-\(UUID().uuidString.prefix(6))", name: request.name, aliases: request.aliases,
            perServing: NutrientProfile(
                kcal: (totals.kcal / n).rounded(), protein: (totals.protein / n).rounded(),
                carbs: (totals.carbs / n).rounded(), fat: (totals.fat / n).rounded(), fiber: (totals.fiber / n).rounded()
            ),
            servingGrams: nil, servingsPerPackage: n, source: "batch", createdAt: Date()
        )
        foods.removeAll { $0.name.lowercased() == food.name.lowercased() }
        foods.insert(food, at: 0)
        return food
    }

    func retire(id: String) async throws {
        foods.removeAll { $0.id == id }
    }
}
