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
    var selectedDate: Date

    private let service: any TodayService

    init(service: (any TodayService)? = nil, date: Date = .now) {
        self.selectedDate = date
        if let service {
            self.service = service
        } else if RuntimeMode.usesMockServices {
            self.service = MockTodayService()
        } else {
            self.service = LiveTodayService()
        }
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
    }

    func select(_ date: Date) async {
        guard !Calendar.current.isDate(date, inSameDayAs: selectedDate) else { return }
        selectedDate = date
        state = .loading
        await load()
    }
}
