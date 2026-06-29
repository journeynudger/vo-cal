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

    func load() async {
        // Don't blank an already-loaded screen on refresh — only show the spinner cold.
        if dashboard == nil { state = .loading }
        do {
            let dashboard = try await service.dashboard(date: selectedDate)
            state = .loaded(dashboard)
        } catch {
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

    /// Delete a logged meal, then refresh the day's totals.
    func deleteMeal(_ id: String) async {
        try? await service.deleteMeal(id: id)
        await load()
    }
}
