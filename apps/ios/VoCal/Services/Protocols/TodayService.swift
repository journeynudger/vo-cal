import Foundation

/// Reads the day's dashboard (targets / consumed / remaining / meals). A protocol so the
/// Today screen renders on the simulator from a fixture with zero network — the mock path
/// is the sim-verifiable default (RuntimeMode), the live path hits `GET /meals/today`.
protocol TodayService: Sendable {
    func dashboard(date: Date) async throws -> TodayDashboard
    /// Fetch / edit / delete an already-logged meal (backs the meal-edit screen).
    func meal(id: String) async throws -> LoggedMeal
    func updateMeal(id: String, _ request: UpdateMealRequest) async throws -> LoggedMeal
    func deleteMeal(id: String) async throws
}

extension TodayService {
    /// The `YYYY-MM-DD` day string the API expects. UTC-stable formatting; the server owns
    /// the tz-aware day window (decision: the client never does day math), so this is only
    /// the date label, not a boundary computation.
    static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}

/// Live path: `GET /meals/today?date=` via the shared REST client.
struct LiveTodayService: TodayService {
    let api: APIClient
    init(api: APIClient = APIClient()) { self.api = api }

    func dashboard(date: Date) async throws -> TodayDashboard {
        try await api.todayDashboard(date: Self.dayString(date))
    }

    func meal(id: String) async throws -> LoggedMeal { try await api.meal(id: id) }

    func updateMeal(id: String, _ request: UpdateMealRequest) async throws -> LoggedMeal {
        try await api.updateMeal(id: id, request)
    }

    func deleteMeal(id: String) async throws { try await api.deleteMeal(id: id) }
}
