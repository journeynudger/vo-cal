import Foundation
import VoCalCore

/// Reads and writes the person's meal plan (`GET /meals/plan`, `PUT /meals/plan`) and parses
/// the typed meal a slot is filled with (the same `/parse` a typed log takes; no capture is
/// involved). A protocol so the builder runs on the simulator with zero network. Off the
/// capture path: delete this type and voice logging still works (AGENTS.md capture-path
/// isolation).
protocol MealPlanService: Sendable {
    /// The latest plan, or nil when the person never built one (the server's 404).
    func plan() async throws -> MealPlan?
    /// Append the next version. The echo, with the engine's check, is the only proof it landed.
    func save(_ update: MealPlanUpdate) async throws -> MealPlan
    /// A typed meal for a slot: the text is a transcript with no audio
    /// (docs/CAPTURE_LIFECYCLE.md §9); the items come back priced, the plan sends them on.
    func parseTyped(_ text: String) async throws -> ParseResult
    /// Francesco's three steps, drafted by the server (decision 73); nothing is stored.
    func generate(_ request: GeneratePlanRequest) async throws -> GeneratedPlan
    /// Step two's suggestions: what the person logs most, then their own foods.
    func foodSuggestions() async throws -> [String]
    /// A grocery receipt photo read into food names (JPEG bytes).
    func readReceipt(_ jpeg: Data) async throws -> [String]
}

struct LiveMealPlanService: MealPlanService {
    let api: APIClient
    init(api: APIClient = APIClient()) { self.api = api }

    func plan() async throws -> MealPlan? {
        // Cold-launch auth guard, as LiveTodayService: a tokenless GET 401s, which here would
        // read as "no plan yet" and offer a person their own plan to build again.
        await AuthCoordinator.shared.ensureSession()
        do {
            return try await api.mealPlan()
        } catch APIError.status(code: 404, body: _) {
            return nil
        }
    }

    func save(_ update: MealPlanUpdate) async throws -> MealPlan {
        await AuthCoordinator.shared.ensureSession()
        return try await api.saveMealPlan(update)
    }

    func parseTyped(_ text: String) async throws -> ParseResult {
        await AuthCoordinator.shared.ensureSession()
        return try await api.parse(transcript: text, captureID: nil, transcriptID: nil)
    }

    func generate(_ request: GeneratePlanRequest) async throws -> GeneratedPlan {
        await AuthCoordinator.shared.ensureSession()
        return try await api.generateMealPlan(request)
    }

    func foodSuggestions() async throws -> [String] {
        await AuthCoordinator.shared.ensureSession()
        return try await api.planFoodSuggestions()
    }

    func readReceipt(_ jpeg: Data) async throws -> [String] {
        await AuthCoordinator.shared.ensureSession()
        return try await api.readReceipt(jpeg, contentType: "image/jpeg").foods
    }
}

/// Sim path: the plan lives in UserDefaults so a plan built on the simulator survives a relaunch
/// and the canned Today ticks it; until one is saved, a canned plan sized to the populated day
/// (three of its four meals, one usual the day did not log) so the card is reachable with no
/// taps. The check is the engine's twin in `PlanComposer`, against the persona's targets.
struct MockMealPlanService: MealPlanService {
    private static let planKey = "vocal.mock.mealplan"

    /// The sim's plan right now, readable without an await by the other mocks.
    static var current: MealPlan? {
        if let data = UserDefaults.standard.data(forKey: planKey),
           let stored = try? VoCalJSON.decoder().decode(MealPlan.self, from: data) {
            return stored
        }
        return canned
    }

    /// The canned plan: the populated day's breakfast, lunch and dinner by name, and the
    /// protein shake usual, which that day logged with a banana (so it stays open and the
    /// shake-and-banana shows as "also today").
    static let canned: MealPlan = {
        let slots = [
            PlanSlot(
                index: 0, name: "Greek yogurt, berries & granola", usualId: nil,
                items: [ConfirmedItem(name: "greek yogurt, berries and granola", grams: 330, macros: NutrientProfile(kcal: 420, protein: 28, carbs: 52, fat: 10, fiber: 5), confidence: 0.9)],
                totals: NutrientProfile(kcal: 420, protein: 28, carbs: 52, fat: 10, fiber: 5)
            ),
            PlanSlot(
                index: 1, name: "Chicken, rice & broccoli", usualId: nil,
                items: [ConfirmedItem(name: "chicken, rice and broccoli", grams: 450, macros: NutrientProfile(kcal: 640, protein: 52, carbs: 70, fat: 16, fiber: 6), confidence: 0.9)],
                totals: NutrientProfile(kcal: 640, protein: 52, carbs: 70, fat: 16, fiber: 6)
            ),
            PlanSlot(
                index: 2, name: "Protein shake", usualId: "mock-usual-shake",
                items: [ConfirmedItem(name: "whey protein", amount: 1, unit: .scoop, grams: 31, macros: NutrientProfile(kcal: 120, protein: 25, carbs: 3, fat: 1, fiber: 0), confidence: 0.97)],
                totals: NutrientProfile(kcal: 120, protein: 25, carbs: 3, fat: 1, fiber: 0)
            ),
            PlanSlot(
                index: 3, name: "Salmon, potatoes & salad", usualId: nil,
                items: [ConfirmedItem(name: "salmon, potatoes and salad", grams: 420, macros: NutrientProfile(kcal: 620, protein: 40, carbs: 28, fat: 34, fiber: 6), confidence: 0.9)],
                totals: NutrientProfile(kcal: 620, protein: 40, carbs: 28, fat: 34, fiber: 6)
            ),
        ]
        return MealPlan(version: 1, author: "person", slots: slots, check: PlanComposer.check(slots))
    }()

    var latency: Duration = .milliseconds(200)

    func plan() async throws -> MealPlan? {
        try? await Task.sleep(for: latency)
        return Self.current
    }

    func save(_ update: MealPlanUpdate) async throws -> MealPlan {
        try? await Task.sleep(for: latency)
        let usuals = try await MockTodayService().usuals()
        var slots: [PlanSlot] = []
        for input in update.slots {
            if let usualId = input.usualId {
                guard let usual = usuals.first(where: { $0.id == usualId }) else {
                    throw APIError.status(code: 404, body: "usual \(usualId) not found")
                }
                slots.append(PlanSlot(index: slots.count, name: input.name ?? usual.name, usualId: usualId, items: usual.items, totals: usual.totals))
            } else if let items = input.items, !items.isEmpty {
                let totals = items.reduce(NutrientProfile.zero) { $0 + $1.macros }
                slots.append(PlanSlot(index: slots.count, name: input.name ?? PlanComposer.autoName(items), usualId: nil, items: items, totals: totals))
            } else {
                throw APIError.status(code: 422, body: "a slot names a usual or carries items")
            }
        }
        let version = (Self.current?.version ?? 0) + 1
        let plan = MealPlan(version: version, author: update.author, slots: slots, check: PlanComposer.check(slots))
        if let data = try? VoCalJSON.encoder().encode(plan) {
            UserDefaults.standard.set(data, forKey: Self.planKey)
        }
        return plan
    }

    func parseTyped(_ text: String) async throws -> ParseResult {
        try await MockMealCaptureService(latency: latency).parseText(text)
    }

    /// The sim's draft: the server's day shapes (meals/generator.py) with canned meals, so the
    /// three steps are walkable offline. Additions are named only when allowed.
    func generate(_ request: GeneratePlanRequest) async throws -> GeneratedPlan {
        try? await Task.sleep(for: latency)
        return Self.draft(for: request)
    }

    /// The canned draft for a request, synchronously (renders cannot await).
    static func draft(for request: GeneratePlanRequest) -> GeneratedPlan {
        var slots: [GeneratedSlot] = []
        for label in Self.labels(meals: request.meals, snacks: request.snacks, dessert: request.dessert) {
            let (name, kcal, protein) = Self.cannedMeals[label] ?? ("Chicken breast, white rice & broccoli", 560, 48)
            let totals = NutrientProfile(kcal: kcal, protein: protein, carbs: kcal * 0.45 / 4, fat: kcal * 0.27 / 9, fiber: 6)
            let items = [ConfirmedItem(name: name.lowercased(), grams: kcal, macros: totals, confidence: 0.9)]
            let slot = PlanSlot(index: slots.count + 1, name: name, usualId: nil, items: items, totals: totals)
            slots.append(GeneratedSlot(slot: slot, label: label))
        }
        return GeneratedPlan(
            slots: slots,
            check: PlanComposer.check(slots.map(\.slot)),
            added: request.mayAdd ? ["oatmeal"] : [],
            unused: []
        )
    }

    func foodSuggestions() async throws -> [String] {
        try? await Task.sleep(for: latency)
        return ["Greek yogurt", "Chicken breast", "White rice", "Broccoli", "Blueberries", "Banana", "Salmon", "Olive oil", "Almonds", "Dark chocolate"]
    }

    func readReceipt(_ jpeg: Data) async throws -> [String] {
        try? await Task.sleep(for: latency)
        return ["Chicken breast", "Plain Greek yogurt", "Brown rice", "Broccoli", "Blueberries", "Bananas", "Olive oil"]
    }

    /// The day's slots in the server's order (meals/generator.py `_layout`).
    static func labels(meals: Int, snacks: Int, dessert: Bool) -> [String] {
        let names: [Int: [String]] = [
            2: ["Lunch", "Dinner"],
            3: ["Breakfast", "Lunch", "Dinner"],
            4: ["Breakfast", "Lunch", "Afternoon meal", "Dinner"],
            5: ["Breakfast", "Late morning meal", "Lunch", "Afternoon meal", "Dinner"],
        ]
        let meals = names[min(max(meals, 2), 5)] ?? names[3]!
        let gaps = Array(0..<(meals.count - 1)).prefix(snacks)
        var out: [String] = Array(repeating: "Morning snack", count: max(0, snacks - gaps.count))
        for (index, meal) in meals.enumerated() {
            out.append(meal)
            if gaps.contains(index) { out.append(meal == "Breakfast" ? "Morning snack" : "Afternoon snack") }
        }
        if snacks == 1 { out = out.map { $0.hasSuffix("snack") ? "Snack" : $0 } }
        if dessert { out.append("Dessert") }
        return out
    }

    private static let cannedMeals: [String: (String, Double, Double)] = [
        "Breakfast": ("Greek yogurt, blueberries & oatmeal", 430, 32),
        "Late morning meal": ("Eggs & whole wheat bread", 330, 22),
        "Lunch": ("Chicken breast, white rice & broccoli", 560, 52),
        "Afternoon meal": ("Salmon, potato & green beans", 520, 38),
        "Dinner": ("Salmon, white rice & green beans", 610, 44),
        "Snack": ("Banana", 105, 1),
        "Morning snack": ("Banana", 105, 1),
        "Afternoon snack": ("Almonds", 165, 6),
        "Dessert": ("Dark chocolate", 140, 2),
    ]

    /// Back to the canned plan (a render or a scenario that needs the known state).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: planKey)
    }
}
