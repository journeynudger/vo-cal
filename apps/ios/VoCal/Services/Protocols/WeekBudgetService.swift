import Foundation

/// Reads the carry-adjusted week and saves replans. A protocol so the weekly view
/// renders on the simulator from a deterministic mock with zero network (RuntimeMode
/// pattern, same as TodayService); the live path hits `/week/budget` + `/week/plan`.
protocol WeekBudgetService: Sendable {
    func budget(containing date: Date) async throws -> WeekBudget
    /// Replan today+future days. `allocations` maps ISO date → whole kcal and must
    /// preserve the weekly total (server-validated). Returns the recomputed week.
    func savePlan(weekStart: String, allocations: [String: Int]) async throws -> WeekBudget
}

/// Live path via the shared REST client. The device tz rides along so the server
/// buckets the week in the USER's days (same reasoning as /meals/today).
struct LiveWeekBudgetService: WeekBudgetService {
    let api: APIClient
    init(api: APIClient = APIClient()) { self.api = api }

    func budget(containing date: Date) async throws -> WeekBudget {
        // Same cold-launch auth guard as LiveTodayService: the request needs the
        // restored session or it goes out tokenless → 401.
        await AuthCoordinator.shared.ensureSession()
        return try await api.weekBudget(date: LiveTodayService.dayString(date))
    }

    func savePlan(weekStart: String, allocations: [String: Int]) async throws -> WeekBudget {
        await AuthCoordinator.shared.ensureSession()
        return try await api.saveWeekPlan(
            WeekPlanRequest(
                weekStart: weekStart,
                tz: TimeZone.current.identifier,
                allocations: allocations
            )
        )
    }
}

/// Deterministic representative week for the sim path: two logged past days (one
/// over, one under), today partially eaten, future days carrying the rebalance.
/// Mirrors the ENGINE's semantics closely enough for UI work (equal spread of the
/// carry across remaining days, no clamp edge cases) — numbers here are display
/// fixtures, never product math.
struct MockWeekBudgetService: WeekBudgetService {
    var baseline: Double = 2000

    func budget(containing date: Date) async throws -> WeekBudget {
        buildWeek(containing: date, planned: nil)
    }

    func savePlan(weekStart: String, allocations: [String: Int]) async throws -> WeekBudget {
        try? await Task.sleep(for: .milliseconds(300))
        return buildWeek(containing: Date(), planned: allocations)
    }

    private func buildWeek(containing date: Date, planned: [String: Int]?) -> WeekBudget {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // Monday
        let todayStart = calendar.startOfDay(for: date)
        let weekday = (calendar.component(.weekday, from: todayStart) + 5) % 7 // 0 = Mon
        let monday = calendar.date(byAdding: .day, value: -weekday, to: todayStart)!

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let dates: [String] = (0..<7).map {
            formatter.string(from: calendar.date(byAdding: .day, value: $0, to: monday)!)
        }
        let plans: [Double] = dates.map { Double(planned?[$0] ?? Int(baseline)) }

        // Past-day story: alternating over/under so the carry is visibly non-zero.
        // Day k consumed = plan + wiggle; only logged days contribute to carry.
        var consumed = [Double](repeating: 0, count: 7)
        var logged = [Bool](repeating: false, count: 7)
        var carry = 0.0
        for k in 0..<weekday {
            let wiggle: Double = (k % 2 == 0) ? 240 : -120
            consumed[k] = plans[k] + wiggle
            logged[k] = true
            carry += plans[k] - consumed[k]
        }
        consumed[weekday] = plans[weekday] * 0.45 // today, mid-afternoon
        logged[weekday] = true

        let remainingDays = 7 - weekday
        let share = carry / Double(remainingDays)
        var days: [WeekBudgetDay] = []
        var remainingSum = 0
        for k in 0..<7 {
            let state = k < weekday ? "past" : (k == weekday ? "today" : "future")
            let adjusted = k < weekday ? Int(plans[k].rounded()) : Int((plans[k] + share).rounded())
            if k >= weekday { remainingSum += adjusted }
            days.append(
                WeekBudgetDay(
                    date: dates[k],
                    weekday: k,
                    plannedKcal: plans[k],
                    adjustedTargetKcal: adjusted,
                    consumedKcal: (consumed[k] * 10).rounded() / 10,
                    logged: logged[k],
                    state: state
                )
            )
        }
        return WeekBudget(
            weekStart: dates[0],
            weekEnd: dates[6],
            baselineDailyKcal: baseline,
            weeklyTargetKcal: plans.reduce(0, +),
            carryKcal: (carry * 10).rounded() / 10,
            remainingKcal: Double(remainingSum) - consumed[weekday],
            fullyRebalanced: true,
            leftoverKcal: 0,
            targetsAreStub: false,
            days: days
        )
    }
}
