import Foundation
import VoCalCore

/// Canned Today dashboards for the sim/UITestMode/DEBUG path — the screen renders fully
/// with zero network. Two scenarios cover the states E1 must show: a populated day and a
/// fresh (empty) day. Numbers are illustrative and align with the protocol persona used
/// across the prototype (a ~2,040 kcal plan).
struct MockTodayService: TodayService {
    enum Scenario: Sendable {
        case populated
        case empty
    }

    var scenario: Scenario = .populated
    /// Small delay so the loading state is briefly visible (and the UI proves it handles it).
    var latency: Duration = .milliseconds(280)

    func dashboard(date: Date) async throws -> TodayDashboard {
        try? await Task.sleep(for: latency)
        switch scenario {
        case .populated: return Self.populated(date: date)
        case .empty: return Self.empty(date: date)
        }
    }

    func meal(id: String) async throws -> LoggedMeal {
        try? await Task.sleep(for: latency)
        // A normal item + an UNRESOLVED 0-cal one, so the edit screen's flag-and-correct path
        // is exercisable on the sim without a backend.
        let items = [
            ConfirmedItem(
                name: "chicken breast", amount: 6, unit: .oz, grams: 170,
                macros: NutrientProfile(kcal: 280, protein: 52, carbs: 0, fat: 6, fiber: 0),
                confidence: 0.95, source: .dictionary
            ),
            ConfirmedItem(
                name: "sausage link", grams: 0,
                macros: NutrientProfile(kcal: 0, protein: 0, carbs: 0, fat: 0, fiber: 0),
                confidence: 0, source: .unresolved
            ),
        ]
        return LoggedMeal(
            id: id, name: "Chicken & a sausage link", mealType: .lunch, items: items,
            totals: items.reduce(NutrientProfile(kcal: 0, protein: 0, carbs: 0, fat: 0, fiber: 0)) {
                $0 + $1.macros
            },
            confidence: 0.6, loggedAt: .now, correctionsCount: 0
        )
    }

    func updateMeal(id: String, _ request: UpdateMealRequest) async throws -> LoggedMeal {
        try? await Task.sleep(for: latency)
        let totals = request.items.reduce(
            NutrientProfile(kcal: 0, protein: 0, carbs: 0, fat: 0, fiber: 0)
        ) { $0 + $1.macros }
        return LoggedMeal(
            id: id, name: request.name, mealType: request.mealType ?? .unspecified,
            items: request.items, totals: totals, confidence: 1.0, loggedAt: .now, correctionsCount: 0
        )
    }

    func deleteMeal(id: String) async throws { try? await Task.sleep(for: latency) }

    func logWater(_ request: WaterLogRequest) async throws -> WaterLog {
        // Sim path: acknowledge the add (the canned dashboard totals don't move, same as a
        // mock meal log). The live path persists the tally and the reload reflects it.
        try? await Task.sleep(for: latency)
        return WaterLog(id: "mock-water", amountOz: request.amountOz)
    }

    private static let targets = DayTotals(
        kcal: 2040, protein: 150, carbs: 200, fat: 60, fiber: 30, produce: 5, water: 96
    )

    static func empty(date: Date) -> TodayDashboard {
        TodayDashboard(
            date: dayString(date),
            targets: targets,
            consumed: DayTotals(),
            remaining: targets,
            meals: [],
            avgConfidence: 0,
            targetsAreStub: false,
            proteinMin: 135,
            proteinMax: 165
        )
    }

    static func populated(date: Date) -> TodayDashboard {
        // A mostly-complete late-day: calories on target, protein in-band, produce + water hit —
        // four "rings" closed (green), fiber still short for contrast. Shows off the goal-met win.
        let consumed = DayTotals(
            kcal: 1980, protein: 152, carbs: 188, fat: 64, fiber: 24, produce: 5, water: 96
        )
        let remaining = DayTotals(
            kcal: targets.kcal - consumed.kcal,
            protein: targets.protein - consumed.protein,
            carbs: targets.carbs - consumed.carbs,
            fat: targets.fat - consumed.fat,
            fiber: targets.fiber - consumed.fiber,
            produce: targets.produce - consumed.produce,
            water: targets.water - consumed.water
        )
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: date) ?? date }
        return TodayDashboard(
            date: dayString(date),
            targets: targets,
            consumed: consumed,
            remaining: remaining,
            meals: [
                TodayMealRow(
                    id: "mock-breakfast", name: "Greek yogurt, berries & granola",
                    mealType: "breakfast", loggedAt: at(8, 12),
                    totals: ["kcal": 420, "protein": 28, "carbs": 52, "fat": 10]
                ),
                TodayMealRow(
                    id: "mock-lunch", name: "Chicken, rice & broccoli",
                    mealType: "lunch", loggedAt: at(12, 40),
                    totals: ["kcal": 640, "protein": 52, "carbs": 70, "fat": 16]
                ),
                TodayMealRow(
                    id: "mock-snack", name: "Protein shake & a banana",
                    mealType: "snack", loggedAt: at(15, 30),
                    totals: ["kcal": 300, "protein": 32, "carbs": 38, "fat": 4]
                ),
                TodayMealRow(
                    id: "mock-dinner", name: "Salmon, potatoes & salad",
                    mealType: "dinner", loggedAt: at(19, 15),
                    totals: ["kcal": 620, "protein": 40, "carbs": 28, "fat": 34]
                ),
            ],
            avgConfidence: 0.95,
            targetsAreStub: false,
            proteinMin: 135,
            proteinMax: 165
        )
    }
}
