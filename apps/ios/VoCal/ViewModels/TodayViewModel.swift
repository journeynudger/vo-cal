import Foundation
import Observation

/// Drives the Today dashboard. Loads the day's dashboard through `TodayService` (mock on the
/// sim path, live REST otherwise) and projects it into a small view state. Keeps the last
/// loaded dashboard visible across a refresh so the screen never flashes empty (the reward
/// beat after a log just updates the numbers in place).
@MainActor
@Observable
final class TodayViewModel {
    enum ViewState: Equatable {
        case loading
        case loaded(TodayDashboard)
        case failed(String)
    }

    private(set) var state: ViewState = .loading
    /// True when a weekly check-in is due (drives the Today banner, G1).
    private(set) var checkinDue = false
    var selectedDate: Date

    private let service: any TodayService
    private let checkin: any CheckinService

    init(
        service: (any TodayService)? = nil,
        checkin: (any CheckinService)? = nil,
        date: Date = .now
    ) {
        self.selectedDate = date
        let mock = RuntimeMode.usesMockServices
        self.service = service ?? (mock ? MockTodayService() : LiveTodayService())
        self.checkin = checkin ?? (mock ? MockCheckinService() : LiveCheckinService())
    }

    /// The dashboard currently on screen, if any (kept visible during a refresh).
    var dashboard: TodayDashboard? {
        if case let .loaded(dashboard) = state { return dashboard }
        return nil
    }

    /// Monotonic ticket for in-flight loads: a completion only writes state if it is still
    /// the NEWEST request. Without it, switching days fast lets a slow older response land
    /// after a newer one and show the wrong day's numbers.
    private var loadGeneration = 0

    func load() async {
        // Don't blank an already-loaded screen on refresh — only show the spinner cold.
        if dashboard == nil { state = .loading }
        loadGeneration += 1
        let ticket = loadGeneration
        do {
            let dashboard = try await service.dashboard(date: selectedDate)
            guard ticket == loadGeneration else { return }
            state = .loaded(dashboard)
        } catch {
            // A cancelled task (view disappeared, refreshToken bumped) is not a failure —
            // writing .failed here flashed "Couldn't load today." during normal navigation.
            if error is CancellationError || Task.isCancelled { return }
            guard ticket == loadGeneration else { return }
            if dashboard == nil {
                state = .failed("Couldn't load today.")
            }
            // If we already have a dashboard, keep showing it; a transient refresh failure
            // shouldn't wipe the day.
        }
        // Only the current day surfaces the check-in banner.
        checkinDue = Calendar.current.isDateInToday(selectedDate) ? await checkin.isDue() : false
    }

    /// Hide the banner for the rest of the week once the user has handled the check-in.
    func dismissCheckin() {
        checkinDue = false
    }

    func select(_ date: Date) async {
        guard !Calendar.current.isDate(date, inSameDayAs: selectedDate) else { return }
        selectedDate = date
        state = .loading
        await load()
    }

    // MARK: - Edit / delete a logged meal

    /// Fetch a logged meal's full items for the edit screen.
    func loadMeal(_ id: String) async throws -> LoggedMeal {
        try await service.meal(id: id)
    }

    /// Persist edits, then refresh the day so totals reflect the change.
    func saveMeal(_ id: String, name: String?, items: [ConfirmedItem]) async throws {
        _ = try await service.updateMeal(id: id, UpdateMealRequest(name: name, mealType: nil, items: items))
        await load()
    }

    /// Delete a logged meal, then refresh the day's totals. Throws on failure — the edit
    /// sheet keeps itself open and says so; dismissing on a swallowed error read as success
    /// while the meal was still there (a false claim, MUST-NOT #6).
    func deleteMeal(_ id: String) async throws {
        try await service.deleteMeal(id: id)
        await load()
    }

    // MARK: - Water quick-add

    /// Log a manual water amount (Today's water tile → add-water sheet), then refresh so the
    /// water card reflects the new server total. Returns whether the server accepted it —
    /// the sheet dismisses optimistically, so the tile view shows a brief "didn't log" notice
    /// on false. Swallowing the failure entirely was a field bug (2026-07: "water logging
    /// isn't working" — adds were failing with zero feedback, indistinguishable from broken).
    @discardableResult
    func addWater(oz: Double) async -> Bool {
        guard oz > 0 else { return false }
        do {
            _ = try await service.logWater(WaterLogRequest(amountOz: oz))
            await load()
            return true
        } catch {
            // The tile only ever shows reloaded server truth, so no false "added" claim —
            // but the caller must still TELL the user the add didn't land.
            return false
        }
    }
}
