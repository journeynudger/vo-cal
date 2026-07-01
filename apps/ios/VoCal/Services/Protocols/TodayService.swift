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
    /// Manual water quick-add from the Today water tile (hydration tally, NOT a meal). The
    /// voice path logs water too (VoiceLogViewModel), but the dashboard needs its own entry
    /// point so a displayed water target isn't a metric with no way to fill it.
    func logWater(_ request: WaterLogRequest) async throws -> WaterLog
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
        // Cold-launch auth race (bug 3): on first open / app relaunch the Today screen can call
        // GET /meals/today BEFORE the persisted Supabase session is restored into the token store,
        // so the request goes out tokenless → 401 → a spurious "Couldn't load today." (Missing
        // first-run DATA is not an error — the API returns a valid stub dashboard for that.) Await
        // a ready session first: it's a cheap no-op once one exists, and for a returning user it
        // restores THEIR account session (not a stub), so Today shows their real day, not an error.
        await AuthCoordinator.shared.ensureSession()
        return try await api.todayDashboard(date: Self.dayString(date))
    }

    func logWater(_ request: WaterLogRequest) async throws -> WaterLog {
        // Same cold-launch auth guard as dashboard(): the tally POST needs the restored
        // account session or it goes out tokenless → 401. ensureSession is a cheap no-op
        // once a session exists.
        await AuthCoordinator.shared.ensureSession()
        return try await api.logWater(request)
    }

    func meal(id: String) async throws -> LoggedMeal { try await api.meal(id: id) }

    func updateMeal(id: String, _ request: UpdateMealRequest) async throws -> LoggedMeal {
        try await api.updateMeal(id: id, request)
    }

    func deleteMeal(id: String) async throws { try await api.deleteMeal(id: id) }
}
