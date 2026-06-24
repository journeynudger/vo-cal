import Foundation

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
        let consumed = DayTotals(
            kcal: 340, protein: 22, carbs: 34, fat: 13, fiber: 4, produce: 1, water: 16
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
        let breakfast = cal.date(bySettingHour: 8, minute: 12, second: 0, of: date) ?? date
        let snack = cal.date(bySettingHour: 6, minute: 40, second: 0, of: date) ?? date
        return TodayDashboard(
            date: dayString(date),
            targets: targets,
            consumed: consumed,
            remaining: remaining,
            meals: [
                TodayMealRow(
                    id: "mock-breakfast",
                    name: "Two eggs & sourdough",
                    mealType: "breakfast",
                    loggedAt: breakfast,
                    totals: ["kcal": 300, "protein": 20, "carbs": 28, "fat": 12]
                ),
                TodayMealRow(
                    id: "mock-snack",
                    name: "Coffee, splash of oat milk",
                    mealType: "snack",
                    loggedAt: snack,
                    totals: ["kcal": 40, "protein": 2, "carbs": 6, "fat": 1]
                ),
            ],
            avgConfidence: 0.95,
            targetsAreStub: false,
            proteinMin: 135,
            proteinMax: 165
        )
    }
}
