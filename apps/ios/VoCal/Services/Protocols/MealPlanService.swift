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

    /// Back to the canned plan (a render or a scenario that needs the known state).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: planKey)
    }
}
